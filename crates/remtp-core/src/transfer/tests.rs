use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use tokio::sync::mpsc;

use super::*;
use crate::DeviceSummary;
use crate::transport::{MemoryLatency, MemoryOp, MemoryTransport, MtpTransport, Transport, Upload};
use crate::{Entry, Result};
use bytes::Bytes;
use futures::StreamExt;

static NEXT: AtomicU64 = AtomicU64::new(0);

struct Scratch(PathBuf);
impl Scratch {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "remtp-test-{}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }

    fn file(&self, name: &str, bytes: &[u8]) -> String {
        let path = self.0.join(name);
        std::fs::write(&path, bytes).unwrap();
        path.to_str().unwrap().into()
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn upload(storage_id: u32, sources: Vec<String>) -> TransferJob {
    TransferJob {
        direction: Direction::ToDevice,
        storage_id,
        sources,
        destination: "/inbox/nested".into(),
        conflict: ConflictPolicy::Ask,
        verify: VerifyMode::None,
        card_safe_names: true,
    }
}

async fn finish(mut events: mpsc::UnboundedReceiver<TransferEvent>) -> TransferSummary {
    tokio::time::timeout(Duration::from_secs(10), async move {
        while let Some(event) = events.recv().await {
            if let TransferEvent::Finished(summary) = event {
                return summary;
            }
        }
        panic!("no transfer summary");
    })
    .await
    .unwrap()
}

#[tokio::test]
async fn read_ahead_overlaps_disk_and_device_wait() {
    let scratch = Scratch::new();
    let files = 10;
    let disk = Duration::from_millis(80);
    let usb = Duration::from_millis(100);
    let sources = (0..files)
        .map(|i| scratch.file(&format!("file-{i}"), &[0xab; 2048]))
        .collect();
    let upload_ends = Arc::new(Mutex::new(Vec::new()));
    let mut memory = MemoryTransport::new(MemoryLatency {
        upload: usb,
        ..MemoryLatency::default()
    });
    let ends = upload_ends.clone();
    memory.hook = Some(Box::new(move |op| {
        if let MemoryOp::Uploaded(name) = op {
            assert!(name.starts_with("file-"));
            ends.lock().unwrap().push(Instant::now());
        }
        Ok(())
    }));
    let device = Device::from_transport(memory);
    let config = TransferConfig {
        read_ahead_files: 3,
        read_ahead_bytes: 16384,
        disk_delay: disk,
    };
    let started = Instant::now();
    let (transfer, events) = device
        .start_transfer_with(upload(1, sources), config)
        .unwrap();
    let summary = finish(events).await;
    assert_eq!(summary.files_copied, files, "{summary:?}");
    let elapsed = started.elapsed();
    let reads = transfer.reporter.read_started.lock().unwrap().clone();
    let uploads = upload_ends.lock().unwrap().clone();
    assert_eq!(reads.len(), files as usize);
    assert_eq!(uploads.len(), files as usize);
    assert!(
        reads[1..]
            .iter()
            .zip(&uploads)
            .all(|(read, uploaded)| read < uploaded)
    );
    // Wall-clock bounds are unreliable on shared CI runners; the ordering check above proves the
    // overlap. Keep only the floor: the device time can't be hidden.
    assert!(elapsed >= usb * files, "elapsed {elapsed:?}");
    let metrics = transfer.metrics();
    // Without read-ahead every file would idle for the whole disk read (80 ms); staying under half of it
    // shows the read was hidden behind the device wait, with headroom for a busy runner (25.6 ms seen).
    assert!(metrics.idle_average < disk / 2, "{metrics:?}");
    assert!(metrics.device_wait_average >= usb, "{metrics:?}");
    assert_eq!(
        device.list(1, "/inbox/nested").await.unwrap().len(),
        files as usize
    );
    device.close().await;
}

#[tokio::test]
async fn asks_only_for_conflict_and_copies_other_files_before_resolution() {
    let scratch = Scratch::new();
    let set_modified = |path: &str, timestamp: u64| {
        std::fs::File::options()
            .write(true)
            .open(path)
            .unwrap()
            .set_times(
                std::fs::FileTimes::new()
                    .set_modified(std::time::UNIX_EPOCH + Duration::from_secs(timestamp)),
            )
            .unwrap();
    };
    let existing = scratch.file("same.bin", b"old contents");
    set_modified(&existing, 1_700_000_000);
    let device = Device::from_transport(MemoryTransport::default());
    let (_, events) = device
        .start_transfer(upload(1, vec![existing.clone()]))
        .unwrap();
    let summary = finish(events).await;
    assert_eq!(summary.files_copied, 1, "{summary:?}");
    let updated = scratch.file("same.bin", b"new");
    set_modified(&updated, 1_700_086_400);
    let free = scratch.file("free.bin", b"independent");
    let (transfer, mut events) = device
        .start_transfer(upload(1, vec![updated, free]))
        .unwrap();
    let issue = tokio::time::timeout(Duration::from_secs(5), async {
        let mut issue = None;
        while let Some(event) = events.recv().await {
            match event {
                TransferEvent::Issue(conflict) if conflict.kind == IssueKind::Conflict => {
                    assert_eq!(conflict.destination_folder, "/inbox/nested");
                    assert_eq!(conflict.existing_modified, Some(1_700_000_000));
                    assert_eq!(conflict.incoming_modified, Some(1_700_086_400));
                    issue = Some(conflict.id)
                }
                TransferEvent::FileDone { path, .. } => {
                    assert_eq!(path, "/inbox/nested/free.bin");
                    return issue.unwrap();
                }
                _ => {}
            }
        }
        panic!("unexpected end of transfer");
    })
    .await
    .unwrap();
    transfer.pause();
    transfer.resolve(issue, ConflictChoice::Replace);
    assert_eq!(
        device.stat(1, "/inbox/nested/same.bin").await.unwrap().size,
        12
    );
    transfer.resume();
    let summary = finish(events).await;
    assert_eq!(summary.files_copied, 2, "{summary:?}");
    assert_eq!(
        device.stat(1, "/inbox/nested/same.bin").await.unwrap().size,
        3
    );
    assert_eq!(device.list(1, "/inbox/nested").await.unwrap().len(), 2);
    device.close().await;
}

#[tokio::test]
async fn continues_only_exact_nested_sources_and_still_asks_about_real_conflicts() {
    let original = Scratch::new();
    let unrelated = Scratch::new();
    let nested = original.0.join("album").join("disc");
    let other_nested = unrelated.0.join("album").join("disc");
    std::fs::create_dir_all(&nested).unwrap();
    std::fs::create_dir_all(&other_nested).unwrap();
    let write = |name: &str, bytes: &[u8]| {
        let path = nested.join(name);
        std::fs::write(&path, bytes).unwrap();
        path.into_os_string().into_string().unwrap()
    };
    let root = original.0.join("album").to_str().unwrap().to_owned();
    let other_root = unrelated.0.join("album").to_str().unwrap().to_owned();
    let copied = write("01.bin", b"published");
    std::fs::write(other_nested.join("02.bin"), b"real").unwrap();
    let device = Device::from_transport(MemoryTransport::default());
    let (_, mut events) = device
        .start_transfer(upload(1, vec![root.clone()]))
        .unwrap();
    assert!(matches!(
        events.recv().await,
        Some(TransferEvent::Planned { .. })
    ));
    assert!(
        matches!(events.recv().await, Some(TransferEvent::PendingSources(sources)) if sources == [copied.clone()])
    );
    let (_, other_events) = device.start_transfer(upload(1, vec![other_root])).unwrap();
    let mut confirmed = None;
    while let Some(event) = events.recv().await {
        if let TransferEvent::FileDone { path, source, .. } = event {
            assert_eq!(path, "/inbox/nested/album/disc/01.bin");
            confirmed = Some(source);
        }
    }
    assert_eq!(confirmed, Some(copied));
    assert_eq!(finish(other_events).await.files_copied, 1);

    let collision = write("02.bin", b"new!");
    let remaining = write("03.bin", b"remaining");
    write("04.bin", b"added later");
    let (transfer, mut events) = device
        .start_transfer_remaining(
            upload(1, vec![root]),
            vec![collision.clone(), remaining.clone()],
        )
        .unwrap();
    let summary = tokio::time::timeout(Duration::from_secs(5), async {
        let mut conflicts = Vec::new();
        let mut completed = Vec::new();
        while let Some(event) = events.recv().await {
            match event {
                TransferEvent::Issue(issue) => {
                    assert_eq!(issue.kind, IssueKind::Conflict);
                    assert_eq!(issue.existing_size, issue.incoming_size);
                    assert_eq!(issue.conflict_source.as_deref(), Some(collision.as_str()));
                    conflicts.push(issue.id);
                    transfer.resolve(issue.id, ConflictChoice::Replace);
                }
                TransferEvent::FileDone { source, .. } => completed.push(source),
                TransferEvent::Finished(summary) => {
                    assert_eq!(conflicts.len(), 1);
                    assert_eq!(completed, [remaining, collision]);
                    return summary;
                }
                _ => {}
            }
        }
        panic!("no transfer summary");
    })
    .await
    .unwrap();
    assert_eq!(summary.files_copied, 2, "{summary:?}");
    assert!(summary.error.is_none());
    assert_eq!(
        device
            .list(1, "/inbox/nested/album/disc")
            .await
            .unwrap()
            .len(),
        3
    );
    device.close().await;
}

#[tokio::test]
async fn queues_jobs_and_cancels_queued_or_waiting_jobs() {
    let scratch = Scratch::new();
    let source = scratch.file("track", b"old");
    let device = Device::from_transport(MemoryTransport::default());
    let (_, events) = device
        .start_transfer(upload(1, vec![source.clone()]))
        .unwrap();
    assert_eq!(finish(events).await.files_copied, 1);
    let (waiting, mut events) = device
        .start_transfer(upload(1, vec![source.clone()]))
        .unwrap();
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if matches!(events.recv().await, Some(TransferEvent::Issue(_))) {
                break;
            }
        }
    })
    .await
    .unwrap();
    let (queued, queued_events) = device.start_transfer(upload(1, vec![source])).unwrap();
    queued.cancel();
    assert_eq!(
        finish(queued_events).await.error.as_deref(),
        Some("cancelled")
    );
    waiting.cancel();
    assert_eq!(finish(events).await.error.as_deref(), Some("cancelled"));
    device.close().await;
}

async fn virtual_device(backing: PathBuf) -> Arc<Device> {
    use mtp_rs::mtp::MtpDevice;
    use mtp_rs::virtual_device::{VirtualDeviceConfig, VirtualStorageConfig};

    let mtp = MtpDevice::builder()
        .use_object_prop_list(true)
        .open_virtual(VirtualDeviceConfig {
            storages: vec![VirtualStorageConfig {
                description: "Internal Storage".into(),
                capacity: 1 << 30,
                backing_dir: backing,
                read_only: false,
            }],
            watch_backing_dirs: false,
            ..VirtualDeviceConfig::default()
        })
        .await
        .unwrap();
    Device::from_transport(MtpTransport::new(
        mtp,
        DeviceSummary {
            id: "virtual".into(),
            manufacturer: String::new(),
            model: String::new(),
            name: "Virtual MTP".into(),
            serial: String::new(),
        },
        None,
    ))
}

#[tokio::test]
async fn virtual_mtp_streams_upload_and_download_with_checksums() {
    let scratch = Scratch::new();
    let backing = scratch.0.join("device");
    std::fs::create_dir(&backing).unwrap();
    let device = virtual_device(backing).await;
    let storage = device.details().await.unwrap().storages[0].id;
    let contents = (0..2_300_000)
        .map(|i| ((i * 57) % 251) as u8)
        .collect::<Vec<_>>();
    let source = scratch.file("source.bin", &contents);
    let mut job = upload(storage, vec![source]);
    job.verify = VerifyMode::Checksum;
    let config = TransferConfig {
        read_ahead_bytes: 16_384,
        ..TransferConfig::default()
    };
    let (_, mut events) = device.start_transfer_with(job, config).unwrap();
    let summary = finish_with_issues(&mut events).await;
    assert_eq!(summary.files_copied, 1, "{summary:?}");
    device
        .rename(storage, "/inbox/nested", "renamed")
        .await
        .unwrap();
    assert_eq!(
        device
            .stat(storage, "/inbox/renamed/source.bin")
            .await
            .unwrap()
            .size,
        contents.len() as u64
    );
    let local = scratch.0.join("out");
    let (_, mut events) = device
        .start_transfer(TransferJob {
            direction: Direction::FromDevice,
            storage_id: storage,
            sources: vec!["/inbox".into()],
            destination: local.to_str().unwrap().into(),
            conflict: ConflictPolicy::Replace,
            verify: VerifyMode::Checksum,
            card_safe_names: false,
        })
        .unwrap();
    let summary = finish_with_issues(&mut events).await;
    assert_eq!(summary.files_copied, 1, "{summary:?}");
    assert_eq!(
        std::fs::read(local.join("inbox/renamed/source.bin")).unwrap(),
        contents
    );
    device.delete(storage, "/inbox").await.unwrap();
    let interrupted = device
        .call(move |session| {
            session.transport.upload(Upload {
                storage,
                parent: 0,
                entry: Entry {
                    name: "interrupted.bin".into(),
                    is_dir: false,
                    size: 2 << 20,
                    modified: None,
                },
                data: futures::stream::iter([
                    Ok(Bytes::from(vec![0; 1 << 20])),
                    Err(std::io::Error::other("simulated source read failure")),
                ])
                .boxed(),
                cancel: CancelToken::new(),
            })
        })
        .await;
    assert!(interrupted.is_err());
    device.invalidate(storage, "/").await.unwrap();
    assert!(device.list(storage, "/").await.unwrap().is_empty());
    device.close().await;
}

#[tokio::test]
async fn virtual_mtp_photo_without_a_thumbnail_is_none() {
    let scratch = Scratch::new();
    let backing = scratch.0.join("device");
    std::fs::create_dir_all(backing.join("DCIM")).unwrap();
    std::fs::write(backing.join("DCIM/photo.jpg"), [0xff, 0xd8, 0xff, 0xd9]).unwrap();
    let device = virtual_device(backing).await;
    let storage = device.details().await.unwrap().storages[0].id;
    assert_eq!(
        device.thumbnail(storage, "/DCIM/photo.jpg").await.unwrap(),
        None
    );
    assert_eq!(device.list(storage, "/DCIM").await.unwrap().len(), 1);
    device.close().await;
}

async fn finish_with_issues(
    events: &mut mpsc::UnboundedReceiver<TransferEvent>,
) -> TransferSummary {
    tokio::time::timeout(Duration::from_secs(10), async {
        while let Some(event) = events.recv().await {
            match event {
                TransferEvent::Issue(issue) => panic!("{issue:?}"),
                TransferEvent::Finished(summary) => return summary,
                _ => {}
            }
        }
        panic!("no transfer summary");
    })
    .await
    .unwrap()
}

async fn seed(memory: &mut MemoryTransport, parent: u64, name: &str, data: &'static [u8]) -> u64 {
    memory
        .upload(Upload {
            storage: 1,
            parent,
            entry: Entry {
                name: name.into(),
                is_dir: false,
                size: data.len() as u64,
                modified: None,
            },
            data: futures::stream::iter([Ok(Bytes::from_static(data))]).boxed(),
            cancel: CancelToken::new(),
        })
        .await
        .unwrap()
}

fn pull(destination: &Path, source: &str) -> TransferJob {
    TransferJob {
        direction: Direction::FromDevice,
        storage_id: 1,
        sources: vec![source.into()],
        destination: destination.to_str().unwrap().into(),
        conflict: ConflictPolicy::Replace,
        verify: VerifyMode::Size,
        card_safe_names: false,
    }
}

fn replace(sources: Vec<String>) -> TransferJob {
    TransferJob {
        destination: "/".into(),
        conflict: ConflictPolicy::Replace,
        ..upload(1, sources)
    }
}

#[tokio::test]
async fn upload_cancelled_after_backup_restores_original() {
    let scratch = Scratch::new();
    let mut memory = MemoryTransport::default();
    let original = seed(&mut memory, 0, "track.bin", b"original").await;
    let active = Arc::new(Mutex::new(None::<Arc<Transfer>>));
    let signal = active.clone();
    memory.hook = Some(Box::new(move |op| {
        if matches!(op, MemoryOp::Renamed(name) if name.starts_with(".remtp-bak-")) {
            signal.lock().unwrap().take().unwrap().cancel();
        }
        Ok(())
    }));
    let device = Device::from_transport(memory);
    let (transfer, events) = device
        .start_transfer(replace(vec![scratch.file("track.bin", b"updated")]))
        .unwrap();
    *active.lock().unwrap() = Some(transfer);
    assert_eq!(finish(events).await.error.as_deref(), Some("cancelled"));
    assert_original(&device, original).await;
}

#[tokio::test]
async fn upload_publish_or_backup_delete_failure_restores_original() {
    for fail_publish in [true, false] {
        let scratch = Scratch::new();
        let mut memory = MemoryTransport::default();
        let original = seed(&mut memory, 0, "track.bin", b"original").await;
        let mut failed = false;
        memory.hook = Some(Box::new(move |op| {
            let inject = if fail_publish {
                matches!(op, MemoryOp::Rename("track.bin"))
            } else {
                matches!(op, MemoryOp::Delete(name) if name.starts_with(".remtp-bak-"))
            };
            if inject && !failed {
                failed = true;
                Err(std::io::Error::other("injected failure").into())
            } else {
                Ok(())
            }
        }));
        let device = Device::from_transport(memory);
        let (_, events) = device
            .start_transfer(replace(vec![scratch.file("track.bin", b"updated")]))
            .unwrap();
        let summary = finish(events).await;
        assert_eq!(summary.files_failed, 1, "{summary:?}");
        assert_original(&device, original).await;
    }
}

async fn assert_original(device: &Device, original: u64) {
    let entries = device.list(1, "/").await.unwrap();
    assert_eq!(entries.len(), 1, "{entries:?}");
    assert_eq!(entries[0].name, "track.bin");
    assert_eq!(entries[0].size, 8);
    device
        .call(move |session| {
            async move {
                assert_eq!(
                    session.transport.stat(original).await?.entry.name,
                    "track.bin"
                );
                Ok(())
            }
            .boxed()
        })
        .await
        .unwrap();
    device.close().await;
}

#[tokio::test]
async fn planning_recovers_only_journaled_work_in_the_destination() {
    let scratch = Scratch::new();
    let mut memory = MemoryTransport::default();
    let folder = format!("/{}", staging::work_id());
    let parent = memory
        .mkdir(1, 0, tree::basename(&folder).into())
        .await
        .unwrap();
    let remote = staging::WorkNames::new("track.bin");
    let unowned_remote = staging::WorkNames::new("leave.bin");
    for name in [
        &remote.temp,
        &remote.backup,
        &unowned_remote.temp,
        &unowned_remote.backup,
    ] {
        seed(&mut memory, parent, name, b"remote").await;
    }
    seed(&mut memory, parent, "source.bin", b"source").await;
    let device = Device::from_transport(memory);
    let key = journal::DeviceJournal::new("memory", 1);
    {
        let mut journal = key.clone().open(&folder).await.unwrap();
        journal.remember(&remote.temp).await.unwrap();
        journal.remember(&remote.backup).await.unwrap();
    }
    let local = staging::WorkNames::new("local.bin");
    let unowned_local = staging::WorkNames::new("leave.bin");
    for name in [
        &local.temp,
        &local.backup,
        &unowned_local.temp,
        &unowned_local.backup,
    ] {
        scratch.file(name, b"local");
    }
    let sibling = scratch.0.join("sibling");
    std::fs::create_dir(&sibling).unwrap();
    std::fs::write(sibling.join(&local.temp), b"outside this job").unwrap();
    {
        let mut journal = journal::Journal::local(&sibling).await.unwrap();
        journal.remember(&local.temp).await.unwrap();
    }
    {
        let mut journal = journal::Journal::local(&scratch.0).await.unwrap();
        journal.remember(&local.temp).await.unwrap();
        journal.remember(&local.backup).await.unwrap();
    }

    let pull_job = pull(&scratch.0, &tree::join(&folder, "source.bin"));
    Plan::build(&device, &pull_job, None, CancelToken::new())
        .await
        .unwrap();
    assert_eq!(
        std::fs::read(scratch.0.join("local.bin")).unwrap(),
        b"local"
    );
    assert!(!scratch.0.join(&local.temp).exists());
    assert!(!scratch.0.join(&local.backup).exists());
    for name in [&unowned_local.temp, &unowned_local.backup] {
        assert_eq!(std::fs::read(scratch.0.join(name)).unwrap(), b"local");
    }
    assert_eq!(
        std::fs::read(sibling.join(&local.temp)).unwrap(),
        b"outside this job"
    );
    assert!(
        journal::Journal::local(&scratch.0)
            .await
            .unwrap()
            .names()
            .is_empty()
    );
    for name in [
        &remote.temp,
        &remote.backup,
        &unowned_remote.temp,
        &unowned_remote.backup,
    ] {
        assert!(device.stat(1, &tree::join(&folder, name)).await.is_ok());
    }

    let mut upload_job = replace(vec![scratch.file("incoming.bin", b"incoming")]);
    upload_job.destination = folder.clone();
    Plan::build(&device, &upload_job, None, CancelToken::new())
        .await
        .unwrap();
    for name in [&remote.temp, &remote.backup] {
        assert!(matches!(
            device.stat(1, &tree::join(&folder, name)).await,
            Err(RemtpError::NotFound { .. })
        ));
    }
    for name in [
        &unowned_remote.temp,
        &unowned_remote.backup,
        "track.bin",
        "source.bin",
    ] {
        assert!(device.stat(1, &tree::join(&folder, name)).await.is_ok());
    }
    assert!(key.open(&folder).await.unwrap().names().is_empty());
    device.close().await;
}

#[tokio::test]
async fn exclusive_publish_preserves_both_files_on_collision() {
    let scratch = Scratch::new();
    let temp = scratch.file("temp.bin", b"incoming");
    let target = scratch.file("target.bin", b"keep me");
    assert!(matches!(
        staging::move_noclobber(Path::new(&temp), Path::new(&target)).await,
        Err(RemtpError::AlreadyExists { .. })
    ));
    assert_eq!(std::fs::read(&temp).unwrap(), b"incoming");
    assert_eq!(std::fs::read(&target).unwrap(), b"keep me");
}

#[tokio::test]
async fn skip_counts_all_files_in_colliding_subtrees() {
    let scratch = Scratch::new();
    std::fs::create_dir_all(scratch.0.join("upload/nested/empty")).unwrap();
    scratch.file("upload/file", b"one");
    scratch.file("upload/nested/file", b"two");
    scratch.file("download", b"local collision");
    let mut memory = MemoryTransport::default();
    seed(&mut memory, 0, "upload", b"device collision").await;
    let download = memory.mkdir(1, 0, "download".into()).await.unwrap();
    let nested = memory.mkdir(1, download, "nested".into()).await.unwrap();
    seed(&mut memory, download, "file", b"one").await;
    seed(&mut memory, nested, "file", b"two").await;
    let device = Device::from_transport(memory);
    for mut job in [
        replace(vec![scratch.0.join("upload").to_str().unwrap().into()]),
        pull(&scratch.0, "/download"),
    ] {
        job.conflict = ConflictPolicy::Skip;
        let (_, mut events) = device.start_transfer(job).unwrap();
        let summary = finish_with_issues(&mut events).await;
        assert_eq!(
            (
                summary.files_copied,
                summary.files_skipped,
                summary.files_failed
            ),
            (0, 2, 0),
            "{summary:?}"
        );
        assert!(summary.error.is_none(), "{summary:?}");
    }
    device.close().await;
}

#[tokio::test]
async fn stale_delete_without_modified_date_refuses_to_retry() {
    let mut memory = MemoryTransport::default();
    seed(&mut memory, 0, "track.bin", b"contents").await;
    let mut first = true;
    memory.hook = Some(Box::new(move |op| {
        if matches!(op, MemoryOp::Delete("track.bin")) && std::mem::take(&mut first) {
            return Err(RemtpError::StaleHandle);
        }
        Ok(())
    }));
    let device = Device::from_transport(memory);
    assert!(matches!(
        device.delete(1, "/track.bin").await,
        Err(RemtpError::Protocol { message }) if message.contains("changed on the device")
    ));
    assert!(device.stat(1, "/track.bin").await.is_ok());
    device.close().await;
}

#[tokio::test]
async fn replace_reserves_existing_target_against_other_sources() {
    let first = Scratch::new();
    let second = Scratch::new();
    let mut memory = MemoryTransport::default();
    seed(&mut memory, 0, "track.bin", b"original").await;
    let device = Device::from_transport(memory);
    let paths = vec![
        first.file("track.bin", b"first"),
        second.file("TRACK.BIN", b"second"),
    ];
    let job = replace(paths);
    let plan = Plan::build(&device, &job, None, CancelToken::new())
        .await
        .unwrap();
    assert_eq!(plan.issues.len(), 1);
    assert_eq!(plan.issues[0].kind, IssueKind::Failed);
    assert_eq!(
        plan.issues[0].retry,
        Some(IssueRetry {
            source: job.sources[1].clone(),
            folder: "/".into(),
            card_safe_name: None,
            keep_both: true,
        })
    );
    let (_, events) = device.start_transfer(job).unwrap();
    let summary = finish(events).await;
    assert_eq!(
        (summary.files_copied, summary.files_failed),
        (1, 1),
        "{summary:?}"
    );
    let out = first.0.join("out");
    let (_, events) = device.start_transfer(pull(&out, "/track.bin")).unwrap();
    assert_eq!(finish(events).await.files_copied, 1);
    assert_eq!(std::fs::read(out.join("track.bin")).unwrap(), b"first");
    device.close().await;
}

#[tokio::test]
async fn name_failures_retry_under_the_card_safe_name() {
    let scratch = Scratch::new();
    let long = scratch.file(&format!("{}.bin", "a".repeat(251)), b"data");
    let reserved = scratch.file(".remtp-tmp-track.bin", b"data");
    let device = Device::from_transport(MemoryTransport::default());
    let mut job = replace(vec![long.clone(), reserved]);
    job.card_safe_names = false;
    let plan = Plan::build(&device, &job, None, CancelToken::new())
        .await
        .unwrap();
    let issues: Vec<_> = plan
        .issues
        .iter()
        .map(|i| (i.kind, i.retry.clone()))
        .collect();
    assert_eq!(
        issues,
        [
            (
                IssueKind::NameTooLong,
                Some(IssueRetry {
                    source: long,
                    folder: "/".into(),
                    card_safe_name: Some(format!("{}.bi", "a".repeat(251))),
                    keep_both: false,
                })
            ),
            (IssueKind::InvalidName, None),
        ]
    );
    device.close().await;
}

#[tokio::test]
async fn keep_both_reserves_a_new_name_for_each_source() {
    let first = Scratch::new();
    let second = Scratch::new();
    let paths = vec![
        first.file("track.bin", b"first"),
        second.file("track.bin", b"second"),
    ];
    let device = Device::from_transport(MemoryTransport::default());
    let mut job = replace(paths);
    job.conflict = ConflictPolicy::KeepBoth;
    let (_, events) = device.start_transfer(job).unwrap();
    let summary = finish(events).await;
    assert_eq!(summary.files_copied, 2, "{summary:?}");
    let out = first.0.join("out");
    let (_, events) = device.start_transfer(pull(&out, "/")).unwrap();
    assert_eq!(finish(events).await.files_copied, 2);
    assert_eq!(std::fs::read(out.join("track.bin")).unwrap(), b"first");
    assert_eq!(std::fs::read(out.join("track (2).bin")).unwrap(), b"second");
    device.close().await;
}

#[tokio::test]
async fn invalid_device_names_never_enter_the_listing_or_download() {
    let scratch = Scratch::new();
    let mut memory = MemoryTransport::default();
    for name in ["", ".", "..", "bad/slash", "bad\\slash", "bad\0nul"] {
        seed(&mut memory, 0, name, b"not a path").await;
    }
    seed(&mut memory, 0, "good.bin", b"data").await;
    let device = Device::from_transport(memory);
    let entries = device.list(1, "/").await.unwrap();
    assert_eq!(entries.len(), 1, "{entries:?}");
    assert_eq!(entries[0].name, "good.bin");
    let (_, events) = device.start_transfer(pull(&scratch.0, "/")).unwrap();
    assert_eq!(finish(events).await.files_copied, 1);
    assert_eq!(std::fs::read_dir(&scratch.0).unwrap().count(), 1);
    device.close().await;
}

#[cfg(unix)]
#[tokio::test]
async fn download_refuses_symlinked_subfolder() {
    let destination = Scratch::new();
    let outside = Scratch::new();
    std::os::unix::fs::symlink(&outside.0, destination.0.join("folder")).unwrap();
    let mut memory = MemoryTransport::default();
    let folder = memory.mkdir(1, 0, "folder".into()).await.unwrap();
    seed(&mut memory, folder, "track.bin", b"do not write outside").await;
    let device = Device::from_transport(memory);
    let (_, mut events) = device
        .start_transfer(pull(&destination.0, "/folder"))
        .unwrap();
    assert!(matches!(
        events.recv().await,
        Some(TransferEvent::Planned { .. })
    ));
    assert!(
        matches!(events.recv().await, Some(TransferEvent::Issue(issue)) if issue.kind == IssueKind::Failed)
    );
    let summary = finish(events).await;
    assert_eq!(
        (summary.files_copied, summary.files_failed),
        (0, 1),
        "{summary:?}"
    );
    assert_eq!(std::fs::read_dir(&outside.0).unwrap().count(), 0);
    device.close().await;
}

#[tokio::test]
async fn download_never_publishes_over_a_new_local_file() {
    let scratch = Scratch::new();
    let mut memory = MemoryTransport::default();
    seed(&mut memory, 0, "track.bin", b"incoming").await;
    let final_path = scratch.0.join("track.bin");
    let race = final_path.clone();
    memory.hook = Some(Box::new(move |op| {
        if matches!(op, MemoryOp::Downloaded) {
            assert!(!race.exists());
            std::fs::write(&race, b"keep me")?;
        }
        Ok(())
    }));
    let device = Device::from_transport(memory);
    let (_, events) = device
        .start_transfer(pull(&scratch.0, "/track.bin"))
        .unwrap();
    let summary = finish(events).await;
    assert_eq!(
        (summary.files_copied, summary.files_failed),
        (0, 1),
        "{summary:?}"
    );
    assert_eq!(std::fs::read(final_path).unwrap(), b"keep me");
    assert_eq!(std::fs::read_dir(&scratch.0).unwrap().count(), 1);
    device.close().await;
}

#[tokio::test]
async fn failed_download_keeps_local_original_and_removes_temp() {
    let scratch = Scratch::new();
    let original = scratch.file("track.bin", b"local original");
    let mut memory = MemoryTransport::default();
    seed(&mut memory, 0, "track.bin", b"incoming").await;
    memory.hook = Some(Box::new(|op| -> Result<()> {
        if matches!(op, MemoryOp::Downloaded) {
            return Err(std::io::Error::other("simulated read failure").into());
        }
        Ok(())
    }));
    let device = Device::from_transport(memory);
    let (_, events) = device
        .start_transfer(pull(&scratch.0, "/track.bin"))
        .unwrap();
    let summary = finish(events).await;
    assert_eq!(
        (summary.files_copied, summary.files_failed),
        (0, 1),
        "{summary:?}"
    );
    assert_eq!(std::fs::read(original).unwrap(), b"local original");
    assert_eq!(std::fs::read_dir(&scratch.0).unwrap().count(), 1);
    device.close().await;
}

#[tokio::test]
async fn panicking_device_request_still_finishes_transfer() {
    let scratch = Scratch::new();
    let mut memory = MemoryTransport::default();
    memory.hook = Some(Box::new(|op| {
        if matches!(op, MemoryOp::Uploaded(_)) {
            panic!("test transport panic");
        }
        Ok(())
    }));
    let device = Device::from_transport(memory);
    let (_, events) = device
        .start_transfer(replace(vec![scratch.file("track.bin", b"incoming")]))
        .unwrap();
    assert_eq!(
        finish(events).await.error.as_deref(),
        Some("device request panicked")
    );
    device.close().await;
}

#[cfg(unix)]
#[tokio::test]
async fn download_rechecks_subfolders_before_publish() {
    let destination = Scratch::new();
    let outside = Scratch::new();
    let mut memory = MemoryTransport::default();
    let folder = memory.mkdir(1, 0, "folder".into()).await.unwrap();
    seed(&mut memory, folder, "track.bin", b"incoming").await;
    let outside_path = outside.0.clone();
    let folder_path = destination.0.join("folder");
    let parked_path = destination.0.join("parked");
    memory.hook = Some(Box::new(move |op| {
        if matches!(op, MemoryOp::Downloaded) {
            std::fs::rename(&folder_path, &parked_path)?;
            std::os::unix::fs::symlink(&outside_path, &folder_path)?;
        }
        Ok(())
    }));
    let device = Device::from_transport(memory);
    let (_, events) = device
        .start_transfer(pull(&destination.0, "/folder"))
        .unwrap();
    let summary = finish(events).await;
    assert_eq!(
        (summary.files_copied, summary.files_failed),
        (0, 1),
        "{summary:?}"
    );
    assert_eq!(std::fs::read_dir(&outside.0).unwrap().count(), 0);
    assert!(!destination.0.join("parked/track.bin").exists());
    device.close().await;
}

#[tokio::test]
async fn cancelled_upload_reports_cleanup_failure() {
    let scratch = Scratch::new();
    let active = Arc::new(Mutex::new(None::<Arc<Transfer>>));
    let signal = active.clone();
    let mut memory = MemoryTransport::default();
    memory.hook = Some(Box::new(move |op| {
        match op {
            MemoryOp::Uploaded("track.bin") => signal.lock().unwrap().take().unwrap().cancel(),
            MemoryOp::Delete("track.bin") => {
                return Err(std::io::Error::other("cleanup denied").into());
            }
            _ => {}
        }
        Ok(())
    }));
    let device = Device::from_transport(memory);
    let (transfer, events) = device
        .start_transfer(replace(vec![scratch.file("track.bin", b"incoming")]))
        .unwrap();
    *active.lock().unwrap() = Some(transfer);
    let summary = finish(events).await;
    assert!(
        summary
            .error
            .as_deref()
            .is_some_and(|error| error.contains("cancelled") && error.contains("cleanup denied")),
        "{summary:?}"
    );
    device.close().await;
}

#[tokio::test]
async fn write_behind_handles_multi_folder_downloads_skip_if_same_and_stale_retry() {
    let scratch = Scratch::new();
    let mut memory = MemoryTransport::default();
    let a = memory.mkdir(1, 0, "a".into()).await.unwrap();
    let b = memory.mkdir(1, 0, "b".into()).await.unwrap();
    seed(&mut memory, a, "same.bin", b"identical").await;
    seed(&mut memory, a, "changed.bin", b"new-bytes").await;
    seed(&mut memory, b, "fresh.bin", b"from-b").await;
    let mut stale = true;
    memory.hook = Some(Box::new(move |op| {
        if matches!(op, MemoryOp::Downloaded) && std::mem::take(&mut stale) {
            return Err(RemtpError::StaleHandle);
        }
        Ok(())
    }));
    std::fs::create_dir(scratch.0.join("a")).unwrap();
    std::fs::write(scratch.0.join("a/same.bin"), b"identical").unwrap();
    std::fs::write(scratch.0.join("a/changed.bin"), b"old-bytes").unwrap();
    let device = Device::from_transport(memory);
    let (_, mut events) = device
        .start_transfer(TransferJob {
            direction: Direction::FromDevice,
            storage_id: 1,
            sources: vec!["/".into()],
            destination: scratch.0.to_str().unwrap().into(),
            conflict: ConflictPolicy::SkipIfSame,
            verify: VerifyMode::None,
            card_safe_names: false,
        })
        .unwrap();
    let summary = finish_with_issues(&mut events).await;
    assert_eq!(
        (
            summary.files_copied,
            summary.files_skipped,
            summary.files_failed
        ),
        (2, 1, 0),
        "{summary:?}"
    );
    assert_eq!(
        std::fs::read(scratch.0.join("a/same.bin")).unwrap(),
        b"identical"
    );
    assert_eq!(
        std::fs::read(scratch.0.join("a/changed.bin")).unwrap(),
        b"new-bytes"
    );
    assert_eq!(
        std::fs::read(scratch.0.join("b/fresh.bin")).unwrap(),
        b"from-b"
    );
    device.close().await;
}
