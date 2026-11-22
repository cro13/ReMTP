use std::fs::{File, FileTimes, OpenOptions};
use std::io::{self, BufWriter, Read, Seek, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering::Relaxed};
use std::sync::{Arc, Mutex};
use std::time::{Duration, UNIX_EPOCH};

use bytes::Bytes;
use futures::{FutureExt, StreamExt, future::BoxFuture};
use mtp_rs::CancelToken;
use sha2::{Digest, Sha256};
use tokio::runtime::Handle;
use tokio::sync::{OwnedSemaphorePermit, Semaphore, mpsc, oneshot};
use tokio::task::JoinHandle;

use super::journal::Journal;
use super::plan::{Decision, PlannedFile};
use super::staging::{
    LOCAL_WORK, LocalTemp, WorkNames, check_local_folder, is_link, move_noclobber_sync,
};
use super::{Reporter, TransferConfig, VerifyMode, platform};
use crate::transport::{DownloadSink, UploadStream};
use crate::{RemtpError, Result};

const CHUNK: usize = 1024 * 1024;
const WRITE_BUF_CAPACITY: usize = 2 * 1024 * 1024;

struct BufferPool {
    buffers: Mutex<Vec<Vec<u8>>>,
    chunk_size: usize,
    max_pooled: usize,
}

impl BufferPool {
    fn new(chunk_size: usize, max_bytes: usize) -> Arc<Self> {
        let max_pooled = (max_bytes / chunk_size.max(1)).clamp(1, 256);
        Arc::new(Self {
            buffers: Mutex::new(Vec::new()),
            chunk_size,
            max_pooled,
        })
    }

    fn take(&self, count: usize) -> Vec<u8> {
        if count <= self.chunk_size
            && let Some(buf) = self.buffers.lock().unwrap().pop()
        {
            return buf;
        }
        vec![0; self.chunk_size.max(count)]
    }

    fn recycle(&self, buf: Vec<u8>) {
        if buf.len() != self.chunk_size {
            return;
        }
        let mut pool = self.buffers.lock().unwrap();
        if pool.len() < self.max_pooled {
            pool.push(buf);
        }
    }
}

pub(super) struct ReadAhead {
    ready: mpsc::Receiver<Prepared>,
    stop: Arc<AtomicBool>,
    slots: Arc<Semaphore>,
    budget: Arc<Semaphore>,
    task: JoinHandle<()>,
}

pub(super) struct Prepared {
    rx: mpsc::UnboundedReceiver<io::Result<Bytes>>,
    hash: Option<oneshot::Receiver<[u8; 32]>>,
    file: Slot,
}

struct Slot {
    _permit: OwnedSemaphorePermit,
    reporter: Arc<Reporter>,
}

impl Drop for Slot {
    fn drop(&mut self) {
        self.reporter.ahead_files.fetch_sub(1, Relaxed);
    }
}

struct Buffered {
    bytes: Vec<u8>,
    len: usize,
    pool: Arc<BufferPool>,
    _permit: OwnedSemaphorePermit,
    reporter: Arc<Reporter>,
}

impl AsRef<[u8]> for Buffered {
    fn as_ref(&self) -> &[u8] {
        &self.bytes[..self.len]
    }
}

impl Drop for Buffered {
    fn drop(&mut self) {
        self.reporter
            .ahead_bytes
            .fetch_sub(self.len as u64, Relaxed);
        self.pool.recycle(std::mem::take(&mut self.bytes));
    }
}

impl ReadAhead {
    pub fn start(
        files: Vec<(String, u64)>,
        config: TransferConfig,
        compute_hash: bool,
        reporter: Arc<Reporter>,
    ) -> Self {
        let (tx, ready) = mpsc::channel(config.read_ahead_files);
        let slots = Arc::new(Semaphore::new(config.read_ahead_files));
        let budget = Arc::new(Semaphore::new(config.read_ahead_bytes));
        let stop = Arc::new(AtomicBool::new(false));
        let handle = Handle::current();
        let task_slots = slots.clone();
        let task_budget = budget.clone();
        let task_stop = stop.clone();
        let task = tokio::task::spawn_blocking(move || {
            let block = CHUNK.min(config.read_ahead_bytes);
            let pool = BufferPool::new(block, config.read_ahead_bytes);
            for (path, size) in files {
                if task_stop.load(Relaxed) {
                    break;
                }
                let Ok(permit) = handle.block_on(task_slots.clone().acquire_owned()) else {
                    break;
                };
                let (chunks, rx) = mpsc::unbounded_channel();
                reporter.ahead_files.fetch_add(1, Relaxed);
                let file_slot = Slot {
                    _permit: permit,
                    reporter: reporter.clone(),
                };
                #[cfg(test)]
                {
                    reporter
                        .read_started
                        .lock()
                        .unwrap()
                        .push(std::time::Instant::now());
                    if !config.disk_delay.is_zero() {
                        std::thread::sleep(config.disk_delay);
                    }
                    if task_stop.load(Relaxed) {
                        break;
                    }
                }
                let (mut hash_tx, hash_rx) = if compute_hash {
                    let (tx, rx) = oneshot::channel();
                    (Some(tx), Some(rx))
                } else {
                    (None, None)
                };
                let mut file = match open_sync(&path, size) {
                    Ok(file) => file,
                    Err(error) => {
                        let _ = chunks.send(Err(error));
                        if tx
                            .blocking_send(Prepared {
                                rx,
                                hash: hash_rx,
                                file: file_slot,
                            })
                            .is_err()
                        {
                            break;
                        }
                        continue;
                    }
                };
                let mut hasher = compute_hash.then(Sha256::new);
                let mut remaining = size;
                let mut ok = true;
                if remaining != 0 {
                    let count = block.min(remaining.try_into().unwrap_or(usize::MAX));
                    let Some(first) = read_chunk_sync(
                        &handle,
                        &mut file,
                        count,
                        &task_budget,
                        &pool,
                        &reporter,
                        &chunks,
                        &task_stop,
                        hasher.as_mut(),
                    ) else {
                        break;
                    };
                    if first.is_ok() {
                        remaining -= count as u64;
                    } else {
                        remaining = 0;
                        ok = false;
                    }
                    let _ = chunks.send(first);
                }
                if ok
                    && remaining == 0
                    && let (Some(tx), Some(hasher)) = (hash_tx.take(), hasher.take())
                {
                    let _ = tx.send(hasher.finalize().into());
                }
                if tx
                    .blocking_send(Prepared {
                        rx,
                        hash: hash_rx,
                        file: file_slot,
                    })
                    .is_err()
                {
                    break;
                }
                while remaining != 0 {
                    if task_stop.load(Relaxed) || chunks.is_closed() {
                        ok = false;
                        break;
                    }
                    let count = block.min(remaining.try_into().unwrap_or(usize::MAX));
                    let Some(next) = read_chunk_sync(
                        &handle,
                        &mut file,
                        count,
                        &task_budget,
                        &pool,
                        &reporter,
                        &chunks,
                        &task_stop,
                        hasher.as_mut(),
                    ) else {
                        ok = false;
                        break;
                    };
                    let failed = next.is_err();
                    if chunks.send(next).is_err() || failed {
                        ok = false;
                        break;
                    }
                    remaining -= count as u64;
                }
                if ok && let (Some(hash_tx), Some(hasher)) = (hash_tx, hasher) {
                    let _ = hash_tx.send(hasher.finalize().into());
                }
            }
        });
        Self {
            ready,
            stop,
            slots,
            budget,
            task,
        }
    }

    pub async fn next(&mut self) -> Option<Prepared> {
        self.ready.recv().await
    }

    pub async fn finish(mut self) -> Result<()> {
        (&mut self.task)
            .await
            .map_err(|error| RemtpError::TaskFailed {
                message: format!("read-ahead task failed: {error}"),
            })
    }
}

impl Drop for ReadAhead {
    fn drop(&mut self) {
        self.stop.store(true, Relaxed);
        self.slots.close();
        self.budget.close();
    }
}

impl Prepared {
    pub fn into_parts(self) -> (UploadStream, Option<oneshot::Receiver<[u8; 32]>>) {
        let stream = futures::stream::unfold((self.rx, self.file), |(mut rx, slot)| async move {
            rx.recv().await.map(|chunk| (chunk, (rx, slot)))
        })
        .boxed();
        (stream, self.hash)
    }
}

fn open_sync(path: &str, size: u64) -> io::Result<File> {
    let file = File::open(path)?;
    let current = file.metadata()?;
    if !current.is_file() || current.len() != size {
        return Err(io::Error::other("source changed after planning"));
    }
    Ok(file)
}

#[allow(clippy::too_many_arguments)]
fn read_chunk_sync(
    handle: &Handle,
    file: &mut File,
    count: usize,
    budget: &Arc<Semaphore>,
    pool: &Arc<BufferPool>,
    reporter: &Arc<Reporter>,
    chunks: &mpsc::UnboundedSender<io::Result<Bytes>>,
    stop: &AtomicBool,
    hasher: Option<&mut Sha256>,
) -> Option<io::Result<Bytes>> {
    if stop.load(Relaxed) {
        return None;
    }
    let permit = handle.block_on(async {
        tokio::select! {
            permit = budget.clone().acquire_many_owned(count as u32) => permit.ok(),
            _ = chunks.closed() => None,
        }
    })?;
    let mut bytes = pool.take(count);
    if let Err(error) = file.read_exact(&mut bytes[..count]) {
        pool.recycle(bytes);
        return Some(Err(error));
    }
    if let Some(hasher) = hasher {
        hasher.update(&bytes[..count]);
    }
    reporter.ahead_bytes.fetch_add(count as u64, Relaxed);
    Some(Ok(Bytes::from_owner(Buffered {
        bytes,
        len: count,
        pool: pool.clone(),
        _permit: permit,
        reporter: reporter.clone(),
    })))
}

enum WriteMessage {
    Data(Bytes, OwnedSemaphorePermit),
    Commit(u64),
    Abort,
}

struct WriteJob {
    file: PlannedFile,
    chunks: mpsc::UnboundedReceiver<WriteMessage>,
}

pub(super) struct WriteOutcome {
    pub target: String,
    pub source: String,
    pub size: u64,
    pub existing_size: Option<u64>,
    pub issue_id: u64,
    pub pending_bytes: u64,
    pub result: Result<bool>,
}

pub(super) struct WriteHandle {
    tx: mpsc::UnboundedSender<WriteMessage>,
    sink_closed: Arc<AtomicBool>,
    budget: Arc<Semaphore>,
    max_budget: usize,
    cancel: CancelToken,
}

impl WriteHandle {
    pub fn sink(&self) -> WriteBehindSink {
        WriteBehindSink {
            tx: self.tx.clone(),
            sink_closed: self.sink_closed.clone(),
            budget: self.budget.clone(),
            max_budget: self.max_budget,
            cancel: self.cancel.clone(),
        }
    }

    pub fn sink_closed(&self) -> bool {
        self.sink_closed.load(Relaxed)
    }

    pub fn commit(self, pending_bytes: u64) -> bool {
        self.tx.send(WriteMessage::Commit(pending_bytes)).is_ok()
    }

    pub fn abort(self) -> bool {
        self.tx.send(WriteMessage::Abort).is_ok()
    }
}

pub(super) struct WriteBehindSink {
    tx: mpsc::UnboundedSender<WriteMessage>,
    sink_closed: Arc<AtomicBool>,
    budget: Arc<Semaphore>,
    max_budget: usize,
    cancel: CancelToken,
}

impl DownloadSink for WriteBehindSink {
    fn write_chunk(&mut self, chunk: Bytes) -> BoxFuture<'_, Result<()>> {
        async move {
            if self.cancel.is_cancelled() {
                return Err(RemtpError::Cancelled);
            }
            if chunk.is_empty() {
                return Ok(());
            }
            let permits = chunk.len().min(self.max_budget).max(1) as u32;
            let permit = tokio::select! {
                permit = self.budget.clone().acquire_many_owned(permits) => {
                    permit.map_err(|_| {
                        if self.cancel.is_cancelled() {
                            RemtpError::Cancelled
                        } else {
                            self.sink_closed.store(true, Relaxed);
                            RemtpError::Io {
                                message: "local download writer stopped".into(),
                            }
                        }
                    })?
                }
                _ = self.tx.closed() => {
                    self.sink_closed.store(true, Relaxed);
                    return Err(RemtpError::Io {
                        message: "local download writer stopped".into(),
                    });
                }
            };
            if self.tx.send(WriteMessage::Data(chunk, permit)).is_err() {
                self.sink_closed.store(true, Relaxed);
                return Err(RemtpError::Io {
                    message: "local download writer stopped".into(),
                });
            }
            Ok(())
        }
        .boxed()
    }
}

pub(super) struct WriteBehind {
    jobs: Option<mpsc::Sender<WriteJob>>,
    outcomes: mpsc::UnboundedReceiver<WriteOutcome>,
    budget: Arc<Semaphore>,
    max_budget: usize,
    cancel: CancelToken,
    stop: Arc<AtomicBool>,
    task: Option<JoinHandle<()>>,
}

impl WriteBehind {
    pub fn start(
        root: PathBuf,
        verify: VerifyMode,
        cancel: CancelToken,
        config: TransferConfig,
    ) -> Self {
        let (jobs_tx, mut jobs_rx) = mpsc::channel::<WriteJob>(config.read_ahead_files);
        let (outcomes_tx, outcomes_rx) = mpsc::unbounded_channel();
        let budget = Arc::new(Semaphore::new(config.read_ahead_bytes));
        let stop = Arc::new(AtomicBool::new(false));
        let task_cancel = cancel.clone();
        let task_stop = stop.clone();
        let task = tokio::task::spawn_blocking(move || {
            let _local_guard = LOCAL_WORK.blocking_lock();
            let mut journal_cache: Option<(PathBuf, Journal)> = None;
            while let Some(job) = jobs_rx.blocking_recv() {
                if task_stop.load(Relaxed) {
                    break;
                }
                if let Some(outcome) =
                    write_one_file(job, &root, verify, &task_cancel, &mut journal_cache)
                    && outcomes_tx.send(outcome).is_err()
                {
                    break;
                }
            }
            if let Some((_, mut journal)) = journal_cache.take() {
                let _ = journal.flush_sync();
            }
        });
        Self {
            jobs: Some(jobs_tx),
            outcomes: outcomes_rx,
            budget,
            max_budget: config.read_ahead_bytes,
            cancel,
            stop,
            task: Some(task),
        }
    }

    pub fn try_recv_outcome(&mut self) -> Option<WriteOutcome> {
        self.outcomes.try_recv().ok()
    }

    pub async fn begin(&self, file: PlannedFile) -> Result<WriteHandle> {
        let (tx, chunks) = mpsc::unbounded_channel();
        let sink_closed = Arc::new(AtomicBool::new(false));
        let job = WriteJob { file, chunks };
        let Some(jobs) = &self.jobs else {
            return Err(RemtpError::Io {
                message: "download writer is closed".into(),
            });
        };
        jobs.send(job).await.map_err(|_| RemtpError::Io {
            message: "download writer stopped".into(),
        })?;
        Ok(WriteHandle {
            tx,
            sink_closed,
            budget: self.budget.clone(),
            max_budget: self.max_budget,
            cancel: self.cancel.clone(),
        })
    }

    pub async fn finish(
        mut self,
        mut on_outcome: impl FnMut(WriteOutcome) -> Result<()>,
    ) -> Result<()> {
        self.jobs.take();
        while let Some(outcome) = self.outcomes.recv().await {
            on_outcome(outcome)?;
        }
        if let Some(task) = self.task.take() {
            task.await.map_err(|error| RemtpError::TaskFailed {
                message: format!("download writer task failed: {error}"),
            })?;
        }
        Ok(())
    }

    pub async fn abort(mut self) -> Vec<WriteOutcome> {
        self.stop.store(true, Relaxed);
        self.budget.close();
        self.jobs.take();
        if let Some(task) = self.task.take() {
            let _ = task.await;
        }
        std::iter::from_fn(|| self.try_recv_outcome()).collect()
    }
}

impl Drop for WriteBehind {
    fn drop(&mut self) {
        self.stop.store(true, Relaxed);
        self.budget.close();
        self.jobs.take();
    }
}

fn journal_for<'a>(
    cache: &'a mut Option<(PathBuf, Journal)>,
    folder: &Path,
) -> Result<&'a mut Journal> {
    if cache
        .as_ref()
        .is_none_or(|(cached, _)| cached.as_path() != folder)
    {
        // Flush and drop any previous journal first so its volume lock is released before opening another.
        if let Some((_, mut previous)) = cache.take() {
            let _ = previous.flush_sync();
        }
        let journal = Journal::local_sync(folder)?;
        *cache = Some((folder.to_owned(), journal));
    }
    Ok(&mut cache.as_mut().unwrap().1)
}

enum DrainOutcome {
    Committed(u64),
    Aborted,
    None,
}

fn drain_after_error(chunks: &mut mpsc::UnboundedReceiver<WriteMessage>) -> DrainOutcome {
    chunks.close();
    while let Ok(message) = chunks.try_recv() {
        match message {
            WriteMessage::Data(_, _) => {}
            WriteMessage::Commit(pending) => return DrainOutcome::Committed(pending),
            WriteMessage::Abort => return DrainOutcome::Aborted,
        }
    }
    DrainOutcome::None
}

fn write_one_file(
    mut job: WriteJob,
    root: &Path,
    verify: VerifyMode,
    cancel: &CancelToken,
    journal_cache: &mut Option<(PathBuf, Journal)>,
) -> Option<WriteOutcome> {
    let target_str = job.file.target.clone();
    let source = job.file.source.clone();
    let size = job.file.size;
    let existing_size = job.file.existing_size;
    let issue_id = job.file.failure_id;

    let outcome = |pending_bytes: u64, result: Result<bool>| WriteOutcome {
        target: target_str.clone(),
        source: source.clone(),
        size,
        existing_size,
        issue_id,
        pending_bytes,
        result,
    };

    let target = Path::new(&job.file.target);
    let folder = target.parent().unwrap();

    if let Err(error) = check_local_folder(root, folder, false) {
        return match drain_after_error(&mut job.chunks) {
            DrainOutcome::Aborted => None,
            DrainOutcome::Committed(pending) => Some(outcome(pending, Err(error.into()))),
            DrainOutcome::None => Some(outcome(0, Err(error.into()))),
        };
    }

    let replace = matches!(
        job.file.decision,
        Decision::Copy { replace: true } | Decision::CheckSame
    );
    let existing = match std::fs::symlink_metadata(target) {
        Ok(metadata) if replace && regular_file(&metadata) => true,
        Ok(_) => {
            let err = RemtpError::AlreadyExists {
                path: job.file.target.clone(),
            };
            return match drain_after_error(&mut job.chunks) {
                DrainOutcome::Aborted => None,
                DrainOutcome::Committed(pending) => Some(outcome(pending, Err(err))),
                DrainOutcome::None => Some(outcome(0, Err(err))),
            };
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => false,
        Err(error) => {
            return match drain_after_error(&mut job.chunks) {
                DrainOutcome::Aborted => None,
                DrainOutcome::Committed(pending) => Some(outcome(pending, Err(error.into()))),
                DrainOutcome::None => Some(outcome(0, Err(error.into()))),
            };
        }
    };

    let name = target.file_name().unwrap().to_str().unwrap();
    let journal = match journal_for(journal_cache, folder) {
        Ok(journal) => journal,
        Err(error) => {
            return match drain_after_error(&mut job.chunks) {
                DrainOutcome::Aborted => None,
                DrainOutcome::Committed(pending) => Some(outcome(pending, Err(error))),
                DrainOutcome::None => Some(outcome(0, Err(error))),
            };
        }
    };

    let (work, temp, destination) = loop {
        let work = WorkNames::new(name);
        if existing
            && let Err(error) = work.check_backup(
                crate::names::MAX_UNITS,
                if cfg!(unix) { 255 } else { usize::MAX },
            )
        {
            return match drain_after_error(&mut job.chunks) {
                DrainOutcome::Aborted => None,
                DrainOutcome::Committed(pending) => Some(outcome(pending, Err(error))),
                DrainOutcome::None => Some(outcome(0, Err(error))),
            };
        }
        let temp = folder.join(&work.temp);
        match std::fs::symlink_metadata(&temp) {
            Ok(_) => continue,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => {
                return match drain_after_error(&mut job.chunks) {
                    DrainOutcome::Aborted => None,
                    DrainOutcome::Committed(pending) => Some(outcome(pending, Err(error.into()))),
                    DrainOutcome::None => Some(outcome(0, Err(error.into()))),
                };
            }
        }
        if let Err(error) = journal.remember_sync(&work.temp) {
            return match drain_after_error(&mut job.chunks) {
                DrainOutcome::Aborted => None,
                DrainOutcome::Committed(pending) => Some(outcome(pending, Err(error))),
                DrainOutcome::None => Some(outcome(0, Err(error))),
            };
        }
        match OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(&temp)
        {
            Ok(destination) => break (work, temp, destination),
            Err(error) => {
                let forget = journal.forget_sync(&work.temp);
                if error.kind() != io::ErrorKind::AlreadyExists || forget.is_err() {
                    let err = RemtpError::from(error)
                        .with_cleanup("could not update the staging journal", forget);
                    return match drain_after_error(&mut job.chunks) {
                        DrainOutcome::Aborted => None,
                        DrainOutcome::Committed(pending) => Some(outcome(pending, Err(err))),
                        DrainOutcome::None => Some(outcome(0, Err(err))),
                    };
                }
            }
        }
    };

    let mut cleanup = LocalTemp::new(root, temp.clone());
    let mut writer = BufWriter::with_capacity(WRITE_BUF_CAPACITY, destination);
    let mut hasher = (verify == VerifyMode::Checksum
        || matches!(job.file.decision, Decision::CheckSame))
    .then(Sha256::new);

    let pending_bytes = loop {
        match job.chunks.blocking_recv() {
            Some(WriteMessage::Data(chunk, _permit)) => {
                if let Err(error) = writer.write_all(&chunk) {
                    drop(writer);
                    let drained = drain_after_error(&mut job.chunks);
                    let rollback = cleanup
                        .remove_sync()
                        .and_then(|()| journal.forget_sync(&work.temp));
                    if matches!(drained, DrainOutcome::Aborted) {
                        return None;
                    }
                    let pending = match drained {
                        DrainOutcome::Committed(p) => p,
                        _ => 0,
                    };
                    return Some(outcome(
                        pending,
                        Err(RemtpError::from(error)
                            .with_cleanup("could not remove temporary file", rollback)),
                    ));
                }
                if let Some(hasher) = &mut hasher {
                    hasher.update(&chunk);
                }
            }
            Some(WriteMessage::Commit(pending)) => break pending,
            Some(WriteMessage::Abort) | None => {
                drop(writer);
                let _ = cleanup.remove_sync();
                let _ = journal.forget_sync(&work.temp);
                return None;
            }
        }
    };

    let finalize = (|| -> Result<bool> {
        let mut destination = writer.into_inner().map_err(|error| error.into_error())?;
        if destination.metadata()?.len() != job.file.size {
            return Err(verification("size"));
        }
        if let Some(hasher) = hasher {
            let expected: [u8; 32] = hasher.finalize().into();
            let actual = if verify == VerifyMode::Checksum {
                destination.seek(io::SeekFrom::Start(0))?;
                let disk = file_hash_sync(&mut destination, cancel)?;
                if disk != expected {
                    return Err(verification("checksum"));
                }
                disk
            } else {
                expected
            };
            if matches!(job.file.decision, Decision::CheckSame) && existing {
                check_local_folder(root, folder, false)?;
                let metadata = std::fs::symlink_metadata(target)?;
                if !regular_file(&metadata) {
                    return Err(RemtpError::AlreadyExists {
                        path: job.file.target.clone(),
                    });
                }
                if local_hash_sync(target, cancel)? == actual {
                    drop(destination);
                    cleanup.remove_sync()?;
                    return Ok(false);
                }
            }
        }
        if let Some(seconds) = job.file.modified {
            let delta = Duration::from_secs(seconds.unsigned_abs());
            let modified = if seconds < 0 {
                UNIX_EPOCH.checked_sub(delta)
            } else {
                UNIX_EPOCH.checked_add(delta)
            };
            if let Some(modified) = modified {
                destination.set_times(FileTimes::new().set_modified(modified))?;
            }
        }
        if existing {
            platform::barrier_sync(&destination)?;
        }
        drop(destination);
        check_local_folder(root, folder, false)?;
        if cancel.is_cancelled() {
            return Err(RemtpError::Cancelled);
        }
        if !regular_file(&std::fs::symlink_metadata(&temp)?) {
            return Err(verification("temporary file type"));
        }
        if existing {
            let metadata = std::fs::symlink_metadata(target)?;
            if !regular_file(&metadata) {
                return Err(RemtpError::AlreadyExists {
                    path: job.file.target.clone(),
                });
            }
            replace_local_sync(target, &temp, &work.backup, cancel, journal)?;
        } else {
            move_noclobber_sync(&temp, target)?;
        }
        cleanup.disarm();
        Ok(true)
    })();

    let result = match finalize {
        Ok(copied) => {
            journal.forget_deferred_sync(&work.temp);
            Ok(copied)
        }
        Err(error) => {
            let rollback = cleanup.remove_sync().map(|()| {
                journal.forget_deferred_sync(&work.temp);
            });
            Err(error.with_cleanup("could not remove temporary file", rollback))
        }
    };
    Some(outcome(pending_bytes, result))
}

fn regular_file(metadata: &std::fs::Metadata) -> bool {
    metadata.is_file() && !is_link(metadata)
}

fn verification(what: &str) -> RemtpError {
    RemtpError::Protocol {
        message: format!("{what} verification failed"),
    }
}

pub(super) fn local_hash_sync(path: &Path, cancel: &CancelToken) -> Result<[u8; 32]> {
    let mut file = File::open(path)?;
    file_hash_sync(&mut file, cancel)
}

fn file_hash_sync(file: &mut File, cancel: &CancelToken) -> Result<[u8; 32]> {
    let mut hash = Sha256::new();
    let mut block = vec![0; CHUNK];
    loop {
        if cancel.is_cancelled() {
            return Err(RemtpError::Cancelled);
        }
        let read = file.read(&mut block)?;
        if read == 0 {
            break;
        }
        hash.update(&block[..read]);
    }
    Ok(hash.finalize().into())
}

fn replace_local_sync(
    target: &Path,
    temp: &Path,
    backup_name: &str,
    cancel: &CancelToken,
    journal: &mut Journal,
) -> Result<()> {
    let backup = target.with_file_name(backup_name);
    match std::fs::symlink_metadata(&backup) {
        Ok(_) => {
            return Err(RemtpError::AlreadyExists {
                path: backup.display().to_string(),
            });
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    journal.remember_sync(backup_name)?;
    if let Err(error) = move_noclobber_sync(target, &backup) {
        return Err(error.with_cleanup(
            "could not update the staging journal",
            journal.forget_sync(backup_name),
        ));
    }
    let publish = if cancel.is_cancelled() {
        Err(RemtpError::Cancelled)
    } else {
        std::fs::rename(temp, target).map_err(Into::into)
    };
    if let Err(error) = publish {
        let rollback =
            move_noclobber_sync(&backup, target).and_then(|()| journal.forget_sync(backup_name));
        return Err(error.with_cleanup("could not restore the original", rollback));
    }
    let commit = if cancel.is_cancelled() {
        Err(RemtpError::Cancelled)
    } else {
        std::fs::remove_file(&backup).map_err(Into::into)
    };
    if let Err(error) = commit {
        let rollback = (|| -> Result<()> {
            if !regular_file(&std::fs::symlink_metadata(&backup)?) {
                return Err(verification("backup file type"));
            }
            move_noclobber_sync(target, temp)?;
            move_noclobber_sync(&backup, target)?;
            journal.forget_sync(backup_name)
        })();
        return Err(error.with_cleanup("could not restore the original", rollback));
    }
    journal.forget_sync(backup_name)
}
