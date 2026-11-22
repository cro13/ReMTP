#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Direction {
    ToDevice,
    FromDevice,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ConflictPolicy {
    Ask,
    Replace,
    KeepBoth,
    Skip,
    SkipIfSame,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VerifyMode {
    None,
    Size,
    Checksum,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ConflictChoice {
    Replace,
    KeepBoth,
    Skip,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IssueKind {
    Conflict,
    InvalidName,
    NameTooLong,
    TooLargeForStorage,
    NoSpace,
    Failed,
}

#[derive(Clone, Debug)]
pub struct TransferJob {
    pub direction: Direction,
    pub storage_id: u32,
    pub sources: Vec<String>,
    pub destination: String,
    pub conflict: ConflictPolicy,
    pub verify: VerifyMode,
    pub card_safe_names: bool,
}

#[derive(Clone, Debug, Default)]
pub struct TransferProgress {
    pub files_done: u32,
    pub files_total: u32,
    pub bytes_done: u64,
    pub bytes_total: u64,
    pub current_name: String,
    pub current_bytes_done: u64,
    pub current_bytes_total: u64,
    pub speed_bytes_per_sec: u64,
    pub avg_ms_per_file: u32,
    pub device_wait_ms_avg: u32,
    pub idle_ms_avg: u32,
    pub read_ahead_files: u32,
    pub read_ahead_bytes: u64,
    pub paused: bool,
}

#[derive(Clone, Debug)]
pub struct TransferIssue {
    pub id: u64,
    pub path: String,
    pub destination_folder: String,
    pub kind: IssueKind,
    pub message: String,
    pub existing_size: Option<u64>,
    pub incoming_size: Option<u64>,
    pub existing_modified: Option<i64>,
    pub incoming_modified: Option<i64>,
    /// How the file can be copied again on its own, when that can work.
    pub retry: Option<IssueRetry>,
    pub conflict_source: Option<String>,
}

/// A failed file copied again as a job of its own: `source` into the destination folder `folder`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct IssueRetry {
    pub source: String,
    pub folder: String,
    /// The name to copy it under with `card_safe_names`, when its own name is what failed.
    pub card_safe_name: Option<String>,
    /// Copy it with `ConflictPolicy::KeepBoth`: the destination name is taken by something that can't be
    /// replaced.
    pub keep_both: bool,
}

#[derive(Clone, Debug)]
pub struct RenamedFile {
    pub from: String,
    pub to: String,
}

#[derive(Clone, Debug, Default)]
pub struct TransferSummary {
    pub files_copied: u32,
    pub files_skipped: u32,
    pub files_failed: u32,
    pub bytes: u64,
    pub elapsed_ms: u64,
    pub renamed: Vec<RenamedFile>,
    pub error: Option<String>,
}

mod copy;
mod journal;
mod metrics;
mod pipeline;
mod plan;
mod platform;
mod staging;

use std::collections::HashMap;
use std::panic::AssertUnwindSafe;
use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use futures::FutureExt;
use mtp_rs::CancelToken;
use tokio::sync::{mpsc, oneshot, watch};

use crate::{Device, RemtpError, Result, tree};
use copy::{pull_data, upload_file};
pub use metrics::FileMetrics;
use metrics::Reporter;
use pipeline::{ReadAhead, WriteBehind, WriteOutcome};
use plan::{Decision, Plan, PlannedFile};

pub enum TransferEvent {
    Planned {
        files_total: u32,
        bytes_total: u64,
    },
    PendingSources(Vec<String>),
    Progress(TransferProgress),
    FileDone {
        path: String,
        source: String,
        bytes: u64,
    },
    FileLeftOut {
        source: String,
    },
    Issue(TransferIssue),
    Finished(TransferSummary),
}

#[derive(Clone, Copy, Debug)]
pub struct TransferConfig {
    pub read_ahead_bytes: usize,
    pub read_ahead_files: usize,
    #[cfg(test)]
    disk_delay: Duration,
}

impl Default for TransferConfig {
    fn default() -> Self {
        Self {
            read_ahead_bytes: 256 << 20,
            read_ahead_files: 64,
            #[cfg(test)]
            disk_delay: Duration::ZERO,
        }
    }
}

pub struct Transfer {
    cancel: CancelToken,
    updates: watch::Sender<Control>,
    answers: Mutex<HashMap<u64, Option<ConflictChoice>>>,
    reporter: Arc<Reporter>,
}

#[derive(Default, Clone)]
struct Control {
    paused: bool,
    cancelled: bool,
    generation: u64,
}

impl Transfer {
    pub fn pause(&self) {
        self.updates.send_modify(|state| state.paused = true);
        self.reporter.paused(true);
    }
    pub fn resume(&self) {
        self.updates.send_modify(|state| state.paused = false);
        self.reporter.paused(false);
    }
    pub fn cancel(&self) {
        self.cancel.cancel();
        self.updates.send_modify(|state| state.cancelled = true);
    }
    fn answers(&self) -> MutexGuard<'_, HashMap<u64, Option<ConflictChoice>>> {
        self.answers
            .lock()
            .unwrap_or_else(|error| error.into_inner())
    }

    pub fn resolve(&self, issue_id: u64, choice: ConflictChoice) {
        if let Some(answer) = self.answers().get_mut(&issue_id) {
            *answer = Some(choice);
            self.updates
                .send_modify(|state| state.generation = state.generation.wrapping_add(1));
        }
    }
    pub fn metrics(&self) -> FileMetrics {
        self.reporter.metrics()
    }
}

impl Device {
    pub fn start_transfer(
        self: &Arc<Self>,
        job: TransferJob,
    ) -> Result<(Arc<Transfer>, mpsc::UnboundedReceiver<TransferEvent>)> {
        self.start_transfer_with(job, TransferConfig::default())
    }

    pub fn start_transfer_with(
        self: &Arc<Self>,
        job: TransferJob,
        config: TransferConfig,
    ) -> Result<(Arc<Transfer>, mpsc::UnboundedReceiver<TransferEvent>)> {
        self.start_transfer_filtered(job, None, config)
    }

    pub fn start_transfer_remaining(
        self: &Arc<Self>,
        job: TransferJob,
        pending_sources: Vec<String>,
    ) -> Result<(Arc<Transfer>, mpsc::UnboundedReceiver<TransferEvent>)> {
        self.start_transfer_filtered(job, Some(pending_sources), TransferConfig::default())
    }

    fn start_transfer_filtered(
        self: &Arc<Self>,
        mut job: TransferJob,
        pending_sources: Option<Vec<String>>,
        config: TransferConfig,
    ) -> Result<(Arc<Transfer>, mpsc::UnboundedReceiver<TransferEvent>)> {
        if job.sources.is_empty() {
            return Err(RemtpError::Io {
                message: "no transfer sources".into(),
            });
        }
        if config.read_ahead_files == 0
            || config.read_ahead_files > tokio::sync::Semaphore::MAX_PERMITS
            || config.read_ahead_bytes == 0
            || config.read_ahead_bytes > tokio::sync::Semaphore::MAX_PERMITS
        {
            return Err(RemtpError::Io {
                message: "invalid read-ahead limits".into(),
            });
        }
        let local = match job.direction {
            Direction::ToDevice => {
                job.destination = tree::normalize(&job.destination)?;
                job.sources
                    .iter()
                    .find(|path| !Path::new(path).is_absolute())
            }
            Direction::FromDevice => {
                for path in &mut job.sources {
                    *path = tree::normalize(path)?;
                }
                Some(&job.destination).filter(|path| !Path::new(path).is_absolute())
            }
        };
        if let Some(path) = local {
            return Err(RemtpError::Io {
                message: format!("local path must be absolute: {path}"),
            });
        }
        let (events, rx) = mpsc::unbounded_channel();
        let transfer = Arc::new(Transfer {
            cancel: CancelToken::new(),
            updates: watch::channel(Control::default()).0,
            answers: Mutex::new(HashMap::new()),
            reporter: Arc::new(Reporter::new(events)),
        });
        self.register_transfer(&transfer)?;
        let (completion, tail) = oneshot::channel();
        let mut prior = self.queue.lock().unwrap().replace(tail);
        let device = self.clone();
        let inner = transfer.clone();
        tokio::spawn(async move {
            let started = Instant::now();
            let mut summary = TransferSummary::default();
            let result = AssertUnwindSafe(async {
                let mut tick = tokio::time::interval(Duration::from_millis(100));
                tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
                let mut work = std::pin::pin!(run(
                    device,
                    job,
                    pending_sources,
                    config,
                    &inner,
                    &mut summary,
                    &mut prior
                ));
                loop {
                    tokio::select! {
                        result = &mut work => break result,
                        _ = tick.tick() => inner.reporter.tick(),
                    }
                }
            })
            .catch_unwind()
            .await;
            summary.error = match result {
                Ok(result) => result.err().map(|error| error.to_string()),
                Err(_) => Some("transfer task panicked".into()),
            };
            summary.elapsed_ms = started.elapsed().as_millis() as u64;
            inner.reporter.finish(summary);
            inner.answers().clear();
            if let Some(prior) = prior {
                tokio::spawn(async move {
                    let _ = prior.await;
                    drop(completion);
                });
            } else {
                drop(completion);
            }
        });
        Ok((transfer, rx))
    }
}

async fn run(
    device: Arc<Device>,
    job: TransferJob,
    pending_sources: Option<Vec<String>>,
    config: TransferConfig,
    transfer: &Transfer,
    summary: &mut TransferSummary,
    prior: &mut Option<oneshot::Receiver<()>>,
) -> Result<()> {
    let mut control = transfer.updates.subscribe();
    if let Some(previous) = prior.as_mut() {
        tokio::select! {
            _ = previous => {},
            _ = control.wait_for(|state| state.cancelled) => return Err(RemtpError::Cancelled),
            _ = device.disconnected() => return Err(RemtpError::Disconnected),
        }
        *prior = None;
    }
    wait_active(&device, &mut control).await?;
    device
        .call(|s| {
            Box::pin(async {
                s.last_file = None;
                Ok(())
            })
        })
        .await?;
    let Plan {
        files,
        folders,
        renamed,
        issues,
        subtree_skipped,
        mut planning,
    } = Plan::build(&device, &job, pending_sources, transfer.cancel.clone()).await?;
    summary.renamed = renamed;
    summary.files_skipped = subtree_skipped;
    let bytes = files
        .iter()
        .fold(0u64, |total, file| total.saturating_add(file.size));
    transfer.reporter.planned(
        ((files.len() + issues.len()).min(u32::MAX as usize) as u32)
            .saturating_add(subtree_skipped),
        bytes,
        subtree_skipped,
    );
    for issue in issues {
        summary.files_failed += 1;
        transfer.reporter.issue(issue);
        transfer.reporter.complete(false, 0);
    }
    transfer.reporter.pending_sources(
        files
            .iter()
            .filter(|file| !matches!(file.decision, Decision::Skip))
            .map(|file| file.source.clone())
            .collect(),
    );
    let mut ready = Vec::new();
    let mut pending = Vec::new();
    for file in files {
        match &file.decision {
            Decision::Ask(issue) => {
                transfer.answers().insert(issue.id, None);
                transfer.reporter.issue(issue.as_ref().clone());
                pending.push(file);
            }
            Decision::Skip => {
                summary.files_skipped = summary.files_skipped.saturating_add(1);
                transfer.reporter.complete(false, 0);
            }
            _ => ready.push(file),
        }
    }
    let mut unavailable = Vec::new();
    for folder in folders {
        wait_active(&device, &mut control).await?;
        match job.direction {
            Direction::ToDevice => device.create_folder(job.storage_id, &folder).await?,
            Direction::FromDevice => {
                let root = Path::new(&job.destination);
                let path = Path::new(&folder);
                if unavailable
                    .iter()
                    .any(|parent: &String| path.starts_with(parent))
                {
                    continue;
                }
                if let Err(error) = staging::local_folder(root, path, true).await {
                    if path == root {
                        return Err(error.into());
                    }
                    unavailable.push(folder.clone());
                    if !ready
                        .iter()
                        .chain(&pending)
                        .any(|file| Path::new(&file.target).starts_with(path))
                    {
                        summary.files_failed += 1;
                        transfer.reporter.issue(planning.issue(
                            (&folder, &target_folder(job.direction, &folder)),
                            IssueKind::Failed,
                            &error.to_string(),
                            None,
                            None,
                            None,
                        ));
                        transfer.reporter.complete(false, 0);
                    }
                }
            }
        }
    }
    let mut copy = CopyRun {
        device: &device,
        job: &job,
        transfer,
        summary,
        device_journal: planning.device_journal.clone(),
        config,
        control: &mut control,
    };
    copy.batch(ready).await?;
    while !pending.is_empty() {
        wait_active(copy.device, copy.control).await?;
        let mut ready = Vec::new();
        let mut unresolved = Vec::new();
        for mut file in pending {
            let Decision::Ask(issue) = &file.decision else {
                unreachable!()
            };
            let answer = {
                let mut answers = transfer.answers();
                let answer = answers.get(&issue.id).copied().flatten();
                if answer.is_some() {
                    answers.remove(&issue.id);
                }
                answer
            };
            match answer {
                Some(ConflictChoice::Skip) => {
                    copy.summary.files_skipped = copy.summary.files_skipped.saturating_add(1);
                    transfer.reporter.file_left_out(file.source);
                    transfer.reporter.complete(false, 0);
                }
                Some(ConflictChoice::Replace) if file.replaceable => {
                    file.decision = Decision::Copy { replace: true };
                    ready.push(file);
                }
                Some(ConflictChoice::Replace) => {
                    copy.summary.files_failed += 1;
                    let folder = target_folder(job.direction, &file.target);
                    transfer.reporter.issue(planning.issue(
                        (&file.target, &folder),
                        IssueKind::Failed,
                        "cannot replace a directory or special file with a file",
                        None,
                        Some(file.size),
                        Some(IssueRetry {
                            source: file.source.clone(),
                            folder: folder.clone(),
                            card_safe_name: None,
                            keep_both: true,
                        }),
                    ));
                    transfer.reporter.file_left_out(file.source);
                    transfer.reporter.complete(false, 0);
                }
                Some(ConflictChoice::KeepBoth) => {
                    let target = planning.keep_both(&file.target, false);
                    copy.summary.renamed.push(RenamedFile {
                        from: file.target,
                        to: target.clone(),
                    });
                    file.target = target;
                    file.decision = Decision::Copy { replace: false };
                    ready.push(file);
                }
                None => unresolved.push(file),
            }
        }
        pending = unresolved;
        if ready.is_empty() && !pending.is_empty() {
            tokio::select! {
                _ = copy.control.changed() => {},
                _ = copy.device.disconnected() => return Err(RemtpError::Disconnected),
            }
        } else {
            copy.batch(ready).await?;
        }
    }
    Ok(())
}

async fn wait_active(device: &Device, control: &mut watch::Receiver<Control>) -> Result<()> {
    tokio::select! {
        state = control.wait_for(|state| !state.paused || state.cancelled) => {
            if state.map_err(|_| RemtpError::Cancelled)?.cancelled { Err(RemtpError::Cancelled) } else { Ok(()) }
        }
        _ = device.disconnected() => Err(RemtpError::Disconnected),
    }
}

struct CopyRun<'a> {
    device: &'a Device,
    job: &'a TransferJob,
    transfer: &'a Transfer,
    summary: &'a mut TransferSummary,
    device_journal: Option<journal::DeviceJournal>,
    config: TransferConfig,
    control: &'a mut watch::Receiver<Control>,
}

impl CopyRun<'_> {
    async fn batch(&mut self, files: Vec<PlannedFile>) -> Result<()> {
        if files.is_empty() {
            return Ok(());
        }
        match self.job.direction {
            Direction::ToDevice => self.batch_upload(files).await,
            Direction::FromDevice => self.batch_download(files).await,
        }
    }

    async fn batch_upload(&mut self, files: Vec<PlannedFile>) -> Result<()> {
        let mut read_ahead = ReadAhead::start(
            files
                .iter()
                .map(|file| (file.source.clone(), file.size))
                .collect(),
            self.config,
            self.job.verify == VerifyMode::Checksum,
            self.transfer.reporter.clone(),
        );
        for file in files {
            wait_active(self.device, self.control).await?;
            let prepared = tokio::select! {
                file = read_ahead.next() => file.ok_or_else(|| RemtpError::Io { message: "read-ahead stopped".into() })?,
                _ = self.control.wait_for(|state| state.cancelled) => return Err(RemtpError::Cancelled),
                _ = self.device.disconnected() => return Err(RemtpError::Disconnected),
            };
            wait_active(self.device, self.control).await?;
            let target = file.target.clone();
            let source = file.source.clone();
            let size = file.size;
            let expected = file.existing_size;
            let issue_id = file.failure_id;
            match upload_file(
                self.device,
                self.job,
                file,
                prepared,
                self.transfer,
                self.device_journal.clone().unwrap(),
            )
            .await
            {
                Ok(true) => {
                    self.summary.files_copied += 1;
                    self.summary.bytes += size;
                    self.transfer.reporter.file_done(target, source, size);
                    self.transfer.reporter.complete(true, size);
                }
                Ok(false) => {
                    self.summary.files_skipped = self.summary.files_skipped.saturating_add(1);
                    self.transfer.reporter.file_left_out(source);
                    self.transfer.reporter.complete(false, 0);
                }
                Err(error) if error.stops_transfer() => {
                    return Err(error);
                }
                Err(error) => {
                    self.record_failure(target, source, size, expected, issue_id, error);
                    self.transfer.reporter.complete(false, 0);
                }
            }
        }
        read_ahead.finish().await
    }

    async fn batch_download(&mut self, files: Vec<PlannedFile>) -> Result<()> {
        let mut writer = WriteBehind::start(
            Path::new(&self.job.destination).to_path_buf(),
            self.job.verify,
            self.transfer.cancel.clone(),
            self.config,
        );
        for file in files {
            while let Some(outcome) = writer.try_recv_outcome() {
                if let Err(error) = self.record_download_outcome(outcome) {
                    self.abort_downloads(writer).await;
                    return Err(error);
                }
            }
            if let Err(error) = wait_active(self.device, self.control).await {
                self.abort_downloads(writer).await;
                return Err(error);
            }
            let target = file.target.clone();
            let source = file.source.clone();
            let size = file.size;
            let expected = file.existing_size;
            let issue_id = file.failure_id;
            for attempt in 0..2 {
                let begun = tokio::select! {
                    handle = writer.begin(file.clone()) => handle,
                    _ = self.control.wait_for(|state| state.cancelled) => Err(RemtpError::Cancelled),
                    _ = self.device.disconnected() => Err(RemtpError::Disconnected),
                };
                let handle = match begun {
                    Ok(handle) => handle,
                    Err(error) => {
                        self.abort_downloads(writer).await;
                        return Err(error);
                    }
                };
                let sink = handle.sink();
                let pulled = pull_data(
                    self.device,
                    self.job.storage_id,
                    source.clone(),
                    size,
                    sink,
                    self.transfer,
                )
                .await;
                match pulled {
                    Ok(()) => {
                        if handle.commit(size) {
                            self.transfer.reporter.handoff(size);
                        } else {
                            self.transfer.reporter.handoff(0);
                        }
                        break;
                    }
                    Err(RemtpError::StaleHandle) if attempt == 0 && !handle.sink_closed() => {
                        let _ = handle.abort();
                        self.transfer.reporter.handoff(0);
                        continue;
                    }
                    Err(error) => {
                        let sink_closed = handle.sink_closed();
                        let aborted = handle.abort();
                        if error.stops_transfer() {
                            self.abort_downloads(writer).await;
                            return Err(error);
                        }
                        if sink_closed || !aborted {
                            self.transfer.reporter.handoff(0);
                            break;
                        }
                        self.record_failure(target, source, size, expected, issue_id, error);
                        self.transfer.reporter.complete(false, 0);
                        break;
                    }
                }
            }
        }
        let mut fatal = None;
        let finish = writer
            .finish(|outcome| {
                if let Err(error) = self.record_download_outcome(outcome) {
                    fatal.get_or_insert(error);
                }
                Ok(())
            })
            .await;
        if let Some(error) = fatal {
            return Err(error);
        }
        finish
    }

    async fn abort_downloads(&mut self, writer: WriteBehind) {
        for outcome in writer.abort().await {
            let _ = self.record_download_outcome(outcome);
        }
    }

    fn record_download_outcome(&mut self, outcome: WriteOutcome) -> Result<()> {
        let WriteOutcome {
            target,
            source,
            size,
            existing_size,
            issue_id,
            pending_bytes,
            result,
        } = outcome;
        match result {
            Ok(true) => {
                self.summary.files_copied += 1;
                self.summary.bytes += size;
                self.transfer.reporter.file_done(target, source, size);
                self.transfer
                    .reporter
                    .complete_handed_off(true, size, pending_bytes);
                Ok(())
            }
            Ok(false) => {
                self.summary.files_skipped = self.summary.files_skipped.saturating_add(1);
                self.transfer.reporter.file_left_out(source);
                self.transfer
                    .reporter
                    .complete_handed_off(false, 0, pending_bytes);
                Ok(())
            }
            Err(error) if error.stops_transfer() => Err(error),
            Err(error) => {
                self.record_failure(target, source, size, existing_size, issue_id, error);
                self.transfer
                    .reporter
                    .complete_handed_off(false, 0, pending_bytes);
                Ok(())
            }
        }
    }

    fn record_failure(
        &mut self,
        target: String,
        source: String,
        size: u64,
        expected: Option<u64>,
        issue_id: u64,
        error: RemtpError,
    ) {
        self.summary.files_failed += 1;
        let kind = if matches!(error, RemtpError::NoSpace) {
            IssueKind::NoSpace
        } else {
            IssueKind::Failed
        };
        let folder = target_folder(self.job.direction, &target);
        self.transfer.reporter.issue(TransferIssue {
            id: issue_id,
            path: target,
            destination_folder: folder.clone(),
            kind,
            message: error.to_string(),
            existing_size: expected,
            incoming_size: Some(size),
            existing_modified: None,
            incoming_modified: None,
            retry: Some(IssueRetry {
                source: source.clone(),
                folder,
                card_safe_name: None,
                keep_both: false,
            }),
            conflict_source: None,
        });
        self.transfer.reporter.file_left_out(source);
    }
}

/// The folder of `target`: a device path for ToDevice, a local path for FromDevice.
fn target_folder(direction: Direction, target: &str) -> String {
    match direction {
        Direction::ToDevice => tree::parent(target).to_owned(),
        Direction::FromDevice => Path::new(target)
            .parent()
            .and_then(Path::to_str)
            .unwrap_or_default()
            .to_owned(),
    }
}

#[cfg(test)]
mod tests;
