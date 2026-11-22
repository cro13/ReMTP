use std::io;
use std::path::Path;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use bytes::Bytes;
use futures::{FutureExt, Stream, StreamExt, future::BoxFuture};
use mtp_rs::CancelToken;
use sha2::{Digest, Sha256};
use tokio::sync::oneshot;

use super::journal::{DeviceJournal, Journal};
use super::metrics::{FileTiming, Reporter};
use super::pipeline::{Prepared, WriteBehindSink, local_hash_sync};
use super::plan::{Decision, PlannedFile};
use super::staging::WorkNames;
use super::{Transfer, TransferJob, VerifyMode};
use crate::device::Session;
use crate::transport::{Download, DownloadSink, Object, Upload, UploadStream};
use crate::{Device, Entry, RemtpError, Result, tree};

type Hash = Arc<Mutex<Sha256>>;

pub(super) async fn upload_file(
    device: &Device,
    job: &TransferJob,
    file: PlannedFile,
    prepared: Prepared,
    transfer: &Transfer,
    journal: DeviceJournal,
) -> Result<bool> {
    let storage = job.storage_id;
    let verify = job.verify;
    let cancel = transfer.cancel.clone();
    let reporter = transfer.reporter.clone();
    let (data, expected_hash) = prepared.into_parts();
    device
        .call(move |session| {
            async move {
                UploadFile {
                    storage,
                    file,
                    data,
                    expected_hash,
                    verify,
                    cancel,
                    reporter,
                    journal,
                }
                .run(session)
                .await
            }
            .boxed()
        })
        .await
}

pub(super) async fn pull_data(
    device: &Device,
    storage: u32,
    source: String,
    size: u64,
    sink: WriteBehindSink,
    transfer: &Transfer,
) -> Result<()> {
    let processing = PullData {
        storage,
        source,
        size,
        reporter: transfer.reporter.clone(),
        sink,
        cancel: transfer.cancel.clone(),
    };
    device
        .call(move |session| processing.run(session).boxed())
        .await
}

struct UploadFile {
    storage: u32,
    file: PlannedFile,
    data: UploadStream,
    expected_hash: Option<oneshot::Receiver<[u8; 32]>>,
    verify: VerifyMode,
    cancel: CancelToken,
    reporter: Arc<Reporter>,
    journal: DeviceJournal,
}

impl UploadFile {
    async fn run(self, session: &mut Session) -> Result<bool> {
        let Self {
            storage,
            file,
            data,
            expected_hash,
            verify,
            cancel,
            reporter,
            journal,
        } = self;
        let parent_path = tree::parent(&file.target);
        let parent = session.resolve(storage, parent_path, &cancel).await?;
        session
            .fill(storage, parent_path, parent.handle, &cancel)
            .await?;
        let name = tree::basename(&file.target);
        let existing = session.tree(storage).lookup(&file.target).cloned();
        let replace = matches!(
            file.decision,
            Decision::Copy { replace: true } | Decision::CheckSame
        );
        if let Some(existing) = &existing
            && (!replace || existing.entry.is_dir)
        {
            return Err(RemtpError::AlreadyExists { path: file.target });
        }
        if matches!(file.decision, Decision::CheckSame)
            && let Some(existing) = &existing
        {
            let old = remote_hash(
                session,
                storage,
                existing.handle,
                existing.entry.size,
                cancel.clone(),
            )
            .await?;
            let source = local_hash(Path::new(&file.source), cancel.clone()).await?;
            if old == source {
                return Ok(false);
            }
        }
        let work = if existing.is_some() {
            let work = loop {
                let work = WorkNames::new(name);
                if [&work.temp, &work.backup].into_iter().all(|work_name| {
                    session
                        .tree(storage)
                        .lookup(&tree::join(parent_path, work_name))
                        .is_none()
                }) {
                    break work;
                }
            };
            work.check_backup(mtp_rs::mtp::MAX_NAME_UNITS, usize::MAX)?;
            Some(work)
        } else {
            None
        };
        let mut journal = if let Some(work) = &work {
            let mut journal = journal.open(parent_path).await?;
            journal.remember(&work.temp).await?;
            Some(journal)
        } else {
            None
        };
        let upload_name = work
            .as_ref()
            .map_or_else(|| name.into(), |work| work.temp.clone());
        let entry = Entry {
            name: upload_name,
            is_dir: false,
            size: file.size,
            modified: file.modified,
        };
        let monitor = Monitor::start(session, &reporter, name, file.size);
        let data = MonitoredUploadStream {
            inner: data,
            cancel: cancel.clone(),
            reporter: reporter.clone(),
            last_chunk: monitor.last_chunk.clone(),
            finished: false,
        }
        .boxed();
        let sent = session
            .transport
            .upload(Upload {
                storage,
                parent: parent.handle,
                entry: entry.clone(),
                data,
                cancel: cancel.clone(),
            })
            .await;
        let sent_at = Instant::now();
        let handle = match sent {
            Ok(handle) => handle,
            Err(error) => {
                if matches!(error, RemtpError::StaleHandle) {
                    session.tree(storage).invalidate(tree::parent(parent_path));
                } else if matches!(error, RemtpError::Cleanup { .. }) {
                    session.tree(storage).invalidate(parent_path);
                }
                monitor.finish(session, sent_at);
                return Err(
                    if let Some(journal) = &mut journal
                        && !error.is_disconnected()
                        && !matches!(error, RemtpError::Cleanup { .. })
                    {
                        error.with_cleanup(
                            "could not update the staging journal",
                            journal.forget(&entry.name).await,
                        )
                    } else {
                        error
                    },
                );
            }
        };
        let verified = async {
            if cancel.is_cancelled() {
                return Err(RemtpError::Cancelled);
            }
            match (verify, expected_hash) {
                (VerifyMode::Checksum, Some(expected)) => {
                    let expected = expected.await.map_err(|_| verification("checksum"))?;
                    let actual =
                        remote_hash(session, storage, handle, entry.size, cancel.clone()).await?;
                    if actual != expected {
                        return Err(verification("checksum"));
                    }
                }
                (VerifyMode::Size, _)
                    if session.transport.stat(handle).await?.entry.size != entry.size =>
                {
                    return Err(verification("size"));
                }
                _ => {}
            }
            if cancel.is_cancelled() {
                return Err(RemtpError::Cancelled);
            }
            Ok(())
        }
        .await;
        let uploaded = tree::join(parent_path, &entry.name);
        session.tree(storage).insert(
            uploaded.clone(),
            Object {
                handle,
                parent: parent.handle,
                storage,
                entry,
            },
        );
        let result = match (verified, existing, &work, &mut journal) {
            (Err(error), _, _, _) => Err(error),
            (Ok(()), Some(old), Some(work), Some(journal)) => {
                replace_remote(session, &file, handle, work, &old, &cancel, journal).await
            }
            (Ok(()), _, _, _) => Ok(()),
        };
        let result = match result {
            Ok(()) => {
                if let (Some(work), Some(journal)) = (&work, &mut journal) {
                    journal.forget(&work.temp).await.map(|()| true)
                } else {
                    Ok(true)
                }
            }
            Err(error) => {
                let cleanup = async {
                    if session
                        .tree(storage)
                        .lookup(&uploaded)
                        .is_some_and(|o| o.handle == handle)
                    {
                        session.delete_known(storage, &uploaded, handle).await?;
                        if let (Some(work), Some(journal)) = (&work, &mut journal) {
                            journal.forget(&work.temp).await?;
                        }
                    }
                    Ok(())
                }
                .await;
                session.tree(storage).invalidate(parent_path);
                Err(error.with_cleanup("could not remove uploaded object", cleanup))
            }
        };
        monitor.finish(session, sent_at);
        result
    }
}

struct MonitoredUploadStream {
    inner: UploadStream,
    cancel: CancelToken,
    reporter: Arc<Reporter>,
    last_chunk: Arc<Mutex<Option<Instant>>>,
    finished: bool,
}

impl Stream for MonitoredUploadStream {
    type Item = io::Result<Bytes>;

    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        if self.cancel.is_cancelled() {
            return Poll::Ready(Some(Err(io::ErrorKind::Interrupted.into())));
        }
        match self.inner.as_mut().poll_next(cx) {
            Poll::Ready(Some(item)) => {
                if let Ok(chunk) = &item {
                    self.reporter.chunk(chunk.len() as u64);
                }
                Poll::Ready(Some(item))
            }
            Poll::Ready(None) => {
                if !self.finished {
                    self.finished = true;
                    *self.last_chunk.lock().unwrap() = Some(Instant::now());
                }
                Poll::Ready(None)
            }
            Poll::Pending => Poll::Pending,
        }
    }
}

async fn replace_remote(
    session: &mut Session,
    file: &PlannedFile,
    handle: crate::transport::Handle,
    work: &WorkNames,
    original: &Object,
    cancel: &CancelToken,
    journal: &mut Journal,
) -> Result<()> {
    let storage = original.storage;
    let name = tree::basename(&file.target);
    let folder = tree::parent(&file.target);
    let uploaded = tree::join(folder, &work.temp);
    let backup = tree::join(folder, &work.backup);
    journal.remember(&work.backup).await?;
    if let Err(error) = session
        .rename_known(storage, &file.target, original.handle, &work.backup)
        .await
    {
        return Err(if matches!(error, RemtpError::AlreadyExists { .. }) {
            error.with_cleanup(
                "could not update the staging journal",
                journal.forget(&work.backup).await,
            )
        } else {
            error
        });
    }
    let publish = if cancel.is_cancelled() {
        Err(RemtpError::Cancelled)
    } else {
        session.rename_known(storage, &uploaded, handle, name).await
    };
    if let Err(error) = publish {
        let rollback = async {
            session
                .rename_known(storage, &backup, original.handle, name)
                .await?;
            journal.forget(&work.backup).await
        }
        .await;
        return Err(error.with_cleanup("could not restore the original", rollback));
    }
    let commit = if cancel.is_cancelled() {
        Err(RemtpError::Cancelled)
    } else {
        session
            .delete_known(storage, &backup, original.handle)
            .await
    };
    if let Err(error) = commit {
        let rollback = async {
            if session.transport.stat(original.handle).await?.entry.name != work.backup {
                return Err(verification("backup name"));
            }
            session
                .rename_known(storage, &file.target, handle, &work.temp)
                .await?;
            session
                .rename_known(storage, &backup, original.handle, name)
                .await?;
            journal.forget(&work.backup).await
        }
        .await;
        return Err(error.with_cleanup("could not restore the original", rollback));
    }
    journal.forget(&work.backup).await
}

struct PullData {
    storage: u32,
    source: String,
    size: u64,
    reporter: Arc<Reporter>,
    sink: WriteBehindSink,
    cancel: CancelToken,
}

impl PullData {
    async fn run(self, session: &mut Session) -> Result<()> {
        let Self {
            storage,
            source,
            size,
            reporter,
            sink,
            cancel,
        } = self;
        let object = session.resolve(storage, &source, &cancel).await?;
        if object.entry.is_dir || object.entry.size != size {
            return Err(verification("source size"));
        }
        let monitor = Monitor::start(session, &reporter, tree::basename(&source), size);
        let count = Mutex::new(monitor.counter());
        let result = session
            .transport
            .download(Download {
                storage,
                handle: object.handle,
                size,
                sink: Box::new(sink),
                cancel,
                progress: Arc::new(move |bytes| count.lock().unwrap()(bytes)),
            })
            .await;
        if matches!(result, Err(RemtpError::StaleHandle)) {
            session.tree(storage).invalidate(tree::parent(&source));
        }
        monitor.finish(session, Instant::now());
        result
    }
}

fn verification(what: &str) -> RemtpError {
    RemtpError::Protocol {
        message: format!("{what} verification failed"),
    }
}

struct Monitor<'a> {
    reporter: &'a Arc<Reporter>,
    started: Instant,
    idle: Option<Duration>,
    last_chunk: Arc<Mutex<Option<Instant>>>,
    size: u64,
}

impl<'a> Monitor<'a> {
    fn start(session: &Session, reporter: &'a Arc<Reporter>, name: &str, size: u64) -> Self {
        let started = Instant::now();
        reporter.start(name, size);
        Self {
            reporter,
            started,
            idle: session.last_file.map(|last| started - last),
            last_chunk: Arc::new(Mutex::new((size == 0).then_some(started))),
            size,
        }
    }

    fn counter(&self) -> impl FnMut(u64) + use<> {
        let reporter = self.reporter.clone();
        let last = self.last_chunk.clone();
        let size = self.size;
        let mut seen = 0;
        move |bytes| {
            seen += bytes;
            reporter.chunk(bytes);
            if seen == size {
                *last.lock().unwrap() = Some(Instant::now());
            }
        }
    }

    fn finish(self, session: &mut Session, sent_at: Instant) {
        let finished = Instant::now();
        let last = self.last_chunk.lock().unwrap().unwrap_or(sent_at);
        self.reporter.timing(FileTiming {
            duration: finished - self.started,
            data: last - self.started,
            device_wait: sent_at.saturating_duration_since(last),
            idle: self.idle,
        });
        session.last_file = Some(finished);
    }
}

async fn local_hash(path: &Path, cancel: CancelToken) -> Result<[u8; 32]> {
    let path = path.to_owned();
    tokio::task::spawn_blocking(move || local_hash_sync(&path, &cancel))
        .await
        .map_err(|error| RemtpError::TaskFailed {
            message: format!("hash task failed: {error}"),
        })?
}

async fn remote_hash(
    session: &mut Session,
    storage: u32,
    handle: u64,
    size: u64,
    cancel: CancelToken,
) -> Result<[u8; 32]> {
    let hash = Hash::default();
    session
        .transport
        .download(Download {
            storage,
            handle,
            size,
            cancel,
            sink: Box::new(HashOnlySink(hash.clone())),
            progress: Arc::new(|_| {}),
        })
        .await?;
    Ok(hash.lock().unwrap().clone().finalize().into())
}

struct HashOnlySink(Hash);

impl DownloadSink for HashOnlySink {
    fn write_chunk(&mut self, chunk: Bytes) -> BoxFuture<'_, Result<()>> {
        self.0.lock().unwrap().update(&chunk);
        Box::pin(async { Ok(()) })
    }
}
