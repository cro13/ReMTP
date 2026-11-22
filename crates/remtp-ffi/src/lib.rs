use std::future::Future;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use core::device::DeviceEvent;
use core::transfer::{self, TransferEvent};
use futures::StreamExt;
use remtp_core as core;
use tokio::runtime::Runtime;
use tokio::sync::mpsc;
use tokio::task::AbortHandle;

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum RemtpError {
    #[error("no such device")]
    NoDevice,
    #[error("device is held by {holder}")]
    DeviceBusy { holder: String },
    #[error("device disconnected")]
    Disconnected,
    #[error("not found: {path}")]
    NotFound { path: String },
    #[error("already exists: {path}")]
    AlreadyExists { path: String },
    #[error("cancelled")]
    Cancelled,
    #[error("{message}")]
    Io { message: String },
    #[error("{message}")]
    Protocol { message: String },
}

#[derive(uniffi::Record)]
pub struct DeviceSummary {
    pub id: String,
    pub manufacturer: String,
    pub model: String,
    pub name: String,
    pub serial: String,
}

#[derive(uniffi::Record)]
pub struct StorageInfo {
    pub id: u32,
    pub description: String,
    pub capacity_bytes: u64,
    pub free_bytes: u64,
    pub removable: bool,
}

#[derive(uniffi::Record)]
pub struct DeviceDetails {
    pub summary: DeviceSummary,
    pub link_speed: Option<String>,
    pub link_speed_mbps: Option<u32>,
    pub storages: Vec<StorageInfo>,
}

#[derive(uniffi::Record)]
pub struct Entry {
    pub name: String,
    pub is_dir: bool,
    pub size: u64,
    pub modified: Option<i64>,
}

#[derive(uniffi::Enum)]
pub enum AccessState {
    Free,
    HeldBy { process: String, pid: Option<u32> },
    Unknown,
}

#[uniffi::export(with_foreign)]
pub trait DeviceEventListener: Send + Sync {
    fn on_device_added(&self, device: DeviceSummary);
    fn on_device_removed(&self, device_id: String);
}

/// What an Android device offers on USB, as far as files go.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum UsbMode {
    /// MTP: ReMTP can browse and copy files.
    FileTransfer,
    /// No data function. USB debugging may still be on.
    ChargingOnly,
}

/// Whether ReMTP can run ADB commands on a device (to switch its USB mode).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum AdbAccess {
    /// No ADB interface: USB debugging is off (or it isn't an Android device).
    Off,
    /// This computer can run commands now, through the running adb server or directly over USB.
    Ready,
    /// The device has to allow this computer first ("Allow USB debugging?" on its screen).
    NeedsApproval,
    /// ADB is there but can't be used now (offline, held by another program, …).
    Unavailable { reason: String },
}

/// An Android device on USB with USB debugging on but file transfer off (charging only, or a mode
/// such as MIDI or tethering). It can't be opened; `set_usb_mode(id, FileTransfer)` turns file
/// transfer on.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AdbOnlyDevice {
    /// Same rules as `DeviceSummary.id`. Android uses a different USB product ID per mode, so this
    /// differs from the device's id in file-transfer mode: match the two by vendor and serial.
    pub id: String,
    pub manufacturer: String,
    pub model: String,
    /// The model (there's no MTP session to read a friendly name from).
    pub name: String,
    pub serial: String,
    pub adb: AdbAccess,
}

/// The outcome of `Engine::set_usb_mode`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum UsbModeSwitch {
    /// The device switched. `device_id` is its id in the new mode (a `DeviceSummary` id for
    /// FileTransfer, an `AdbOnlyDevice` id for ChargingOnly), or None when it didn't come back on
    /// USB in time.
    Switched { device_id: Option<String> },
    /// The device still asks "Allow USB debugging?": switch again once the user has allowed it.
    NeedsApproval,
    /// ADB can't do it: USB debugging off, device offline, ADB held by another program, or the
    /// device refused the command.
    Unavailable { reason: String },
}

#[uniffi::export(with_foreign)]
pub trait AdbOnlyDeviceListener: Send + Sync {
    /// The whole current list whenever it changes, and once right after the listener is set.
    fn on_adb_only_devices_changed(&self, devices: Vec<AdbOnlyDevice>);
}

#[derive(uniffi::Enum)]
pub enum Direction {
    ToDevice,
    FromDevice,
}
#[derive(uniffi::Enum)]
pub enum ConflictPolicy {
    Ask,
    Replace,
    KeepBoth,
    Skip,
    SkipIfSame,
}
#[derive(uniffi::Enum)]
pub enum VerifyMode {
    None,
    Size,
    Checksum,
}
#[derive(uniffi::Enum)]
pub enum ConflictChoice {
    Replace,
    KeepBoth,
    Skip,
}
#[derive(uniffi::Enum)]
pub enum IssueKind {
    Conflict,
    InvalidName,
    NameTooLong,
    TooLargeForStorage,
    NoSpace,
    Failed,
}

#[derive(uniffi::Record)]
pub struct TransferJob {
    pub direction: Direction,
    pub storage_id: u32,
    pub sources: Vec<String>,
    pub destination: String,
    pub conflict: ConflictPolicy,
    pub verify: VerifyMode,
    pub card_safe_names: bool,
    pub pending_sources: Option<Vec<String>>,
}

#[derive(uniffi::Record)]
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

#[derive(uniffi::Record)]
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
    pub retry: Option<IssueRetry>,
    pub conflict_source: Option<String>,
}

#[derive(uniffi::Record)]
pub struct IssueRetry {
    pub source: String,
    pub folder: String,
    pub card_safe_name: Option<String>,
    pub keep_both: bool,
}

#[derive(uniffi::Record)]
pub struct RenamedFile {
    pub from: String,
    pub to: String,
}

#[derive(uniffi::Record)]
pub struct TransferSummary {
    pub files_copied: u32,
    pub files_skipped: u32,
    pub files_failed: u32,
    pub bytes: u64,
    pub elapsed_ms: u64,
    pub renamed: Vec<RenamedFile>,
    pub error: Option<String>,
}

#[uniffi::export(with_foreign)]
pub trait TransferObserver: Send + Sync {
    fn on_planned(&self, files_total: u32, bytes_total: u64);
    fn on_pending_sources(&self, sources: Vec<String>);
    fn on_progress(&self, progress: TransferProgress);
    fn on_file_done(&self, source: String, destination: String, bytes: u64);
    fn on_file_left_out(&self, source: String);
    fn on_issue(&self, issue: TransferIssue);
    fn on_finished(&self, summary: TransferSummary);
}

#[derive(uniffi::Object)]
pub struct Engine {
    inner: Arc<core::Engine>,
    watcher: Mutex<Option<AbortHandle>>,
    adb_only_watcher: Mutex<Option<AdbOnlyWatcher>>,
}

struct AdbOnlyWatcher {
    task: AbortHandle,
    active: Arc<AtomicBool>,
}

impl Drop for AdbOnlyWatcher {
    fn drop(&mut self) {
        self.active.store(false, Ordering::Release);
        self.task.abort();
    }
}

#[uniffi::export]
impl Engine {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            inner: Arc::new(core::Engine::new()),
            watcher: Mutex::new(None),
            adb_only_watcher: Mutex::new(None),
        })
    }

    pub fn version(&self) -> String {
        env!("CARGO_PKG_VERSION").into()
    }

    pub fn list_devices(&self) -> Result<Vec<DeviceSummary>, RemtpError> {
        Ok(self
            .inner
            .list_devices()?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub fn open(&self, device_id: String) -> Result<Arc<Device>, RemtpError> {
        let engine = self.inner.clone();
        let inner = wait(async move { engine.open(&device_id).await })?;
        Ok(Arc::new(Device { inner }))
    }

    pub fn set_event_listener(&self, listener: Arc<dyn DeviceEventListener>) {
        let Ok(runtime) = runtime() else {
            return;
        };
        let mut watcher = self.watcher.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(previous) = watcher.take() {
            previous.abort();
        }
        let Ok(events) = self.inner.device_events() else {
            return;
        };
        let (tx, mut rx) = mpsc::channel(64);
        if std::thread::Builder::new()
            .name("remtp-hotplug".into())
            .spawn(move || {
                while let Some(event) = rx.blocking_recv() {
                    match event {
                        DeviceEvent::Added(device) => listener.on_device_added(device.into()),
                        DeviceEvent::Removed(id) => listener.on_device_removed(id),
                    }
                }
            })
            .is_err()
        {
            return;
        }
        *watcher = Some(
            runtime
                .spawn(async move {
                    let mut events = std::pin::pin!(events);
                    while let Some(event) = events.next().await {
                        if tx.send(event).await.is_err() {
                            break;
                        }
                    }
                })
                .abort_handle(),
        );
    }

    pub fn access_state(&self, device_id: String) -> AccessState {
        self.inner.access_state(&device_id).into()
    }

    pub fn release_system_hold(&self, device_id: String) -> Result<(), RemtpError> {
        let engine = self.inner.clone();
        wait(async move { engine.release_system_hold(&device_id).await })
    }

    pub fn restore_system_hold(&self) -> Result<(), RemtpError> {
        Ok(self.inner.restore_system_hold()?)
    }

    /// Android devices with USB debugging on but file transfer off.
    pub fn list_adb_only_devices(&self) -> Result<Vec<AdbOnlyDevice>, RemtpError> {
        Ok(self
            .inner
            .list_adb_only_devices()?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// Hot-plug for `AdbOnlyDevice`s (replaces any previous listener).
    pub fn set_adb_only_device_listener(&self, listener: Arc<dyn AdbOnlyDeviceListener>) {
        let Ok(runtime) = runtime() else {
            return;
        };
        let mut watcher = self
            .adb_only_watcher
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        drop(watcher.take());
        let events = self.inner.adb_only_device_events();
        let (tx, mut rx) = mpsc::channel::<Vec<core::AdbOnlyDevice>>(64);
        let active = Arc::new(AtomicBool::new(true));
        let delivering = active.clone();
        if std::thread::Builder::new()
            .name("remtp-adb-hotplug".into())
            .spawn(move || {
                while let Some(devices) = rx.blocking_recv() {
                    if !delivering.load(Ordering::Acquire) {
                        break;
                    }
                    listener
                        .on_adb_only_devices_changed(devices.into_iter().map(Into::into).collect());
                }
            })
            .is_err()
        {
            return;
        }
        let task = runtime
            .spawn(async move {
                let mut events = std::pin::pin!(events);
                while let Some(devices) = events.next().await {
                    if tx.send(devices).await.is_err() {
                        break;
                    }
                }
            })
            .abort_handle();
        *watcher = Some(AdbOnlyWatcher { task, active });
    }

    /// ADB access for a `DeviceSummary` id or an `AdbOnlyDevice` id. Cheap; may answer from a cache
    /// and never makes the device show a prompt.
    pub fn adb_access(&self, device_id: String) -> AdbAccess {
        self.inner.adb_access(&device_id).into()
    }

    /// Switches the device's USB mode through ADB and waits until it's back on USB in the new mode
    /// (or a timeout). Closes ReMTP's session with the device first. If the device still has to
    /// allow this computer, it asks on its screen and this waits for the user for a while.
    /// Errors are for unknown devices and unexpected failures; ADB problems are `Unavailable`.
    pub fn set_usb_mode(
        &self,
        device_id: String,
        mode: UsbMode,
    ) -> Result<UsbModeSwitch, RemtpError> {
        let engine = self.inner.clone();
        wait(async move { engine.set_usb_mode(&device_id, mode.into()).await }).map(Into::into)
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        if let Some(watcher) = self
            .watcher
            .get_mut()
            .unwrap_or_else(|e| e.into_inner())
            .take()
        {
            watcher.abort();
        }
    }
}

#[derive(uniffi::Object)]
pub struct Device {
    inner: Arc<core::Device>,
}

#[uniffi::export]
impl Device {
    pub fn details(&self) -> Result<DeviceDetails, RemtpError> {
        let device = self.inner.clone();
        Ok(wait(async move { device.details().await })?.into())
    }

    pub fn list(&self, storage_id: u32, path: String) -> Result<Vec<Entry>, RemtpError> {
        let device = self.inner.clone();
        Ok(wait(async move { device.list(storage_id, &path).await })?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub fn stat(&self, storage_id: u32, path: String) -> Result<Entry, RemtpError> {
        let device = self.inner.clone();
        Ok(wait(async move { device.stat(storage_id, &path).await })?.into())
    }

    pub fn create_folder(&self, storage_id: u32, path: String) -> Result<(), RemtpError> {
        let device = self.inner.clone();
        wait(async move { device.create_folder(storage_id, &path).await })
    }

    pub fn delete(&self, storage_id: u32, path: String) -> Result<(), RemtpError> {
        let device = self.inner.clone();
        wait(async move { device.delete(storage_id, &path).await })
    }

    pub fn rename(
        &self,
        storage_id: u32,
        path: String,
        new_name: String,
    ) -> Result<(), RemtpError> {
        let device = self.inner.clone();
        wait(async move { device.rename(storage_id, &path, &new_name).await })
    }

    /// The device's own thumbnail of an image or video (usually a small JPEG). `None` for other files,
    /// and when the device has none for it or doesn't do thumbnails.
    pub fn thumbnail(&self, storage_id: u32, path: String) -> Result<Option<Vec<u8>>, RemtpError> {
        let device = self.inner.clone();
        wait(async move { device.thumbnail(storage_id, &path).await })
    }

    pub fn invalidate(&self, storage_id: u32, path: String) {
        let device = self.inner.clone();
        if let Err(error) = wait(async move { device.invalidate(storage_id, &path).await }) {
            eprintln!("ReMTP: {error}");
        }
    }

    pub fn start_transfer(
        &self,
        job: TransferJob,
        observer: Arc<dyn TransferObserver>,
    ) -> Result<Arc<Transfer>, RemtpError> {
        let device = self.inner.clone();
        let (inner, mut events) = wait(async move {
            let mut job = job;
            match job.pending_sources.take() {
                Some(sources) => device.start_transfer_remaining(job.into(), sources),
                None => device.start_transfer(job.into()),
            }
        })?;
        if let Err(error) = std::thread::Builder::new()
            .name("remtp-transfer".into())
            .spawn(move || {
                while let Some(event) = events.blocking_recv() {
                    match event {
                        TransferEvent::Planned {
                            files_total,
                            bytes_total,
                        } => observer.on_planned(files_total, bytes_total),
                        TransferEvent::PendingSources(sources) => {
                            observer.on_pending_sources(sources)
                        }
                        TransferEvent::Progress(progress) => observer.on_progress(progress.into()),
                        TransferEvent::FileDone {
                            path,
                            source,
                            bytes,
                        } => observer.on_file_done(source, path, bytes),
                        TransferEvent::FileLeftOut { source } => observer.on_file_left_out(source),
                        TransferEvent::Issue(issue) => observer.on_issue(issue.into()),
                        TransferEvent::Finished(summary) => {
                            observer.on_finished(summary.into());
                            return;
                        }
                    }
                }
                observer.on_finished(TransferSummary {
                    files_copied: 0,
                    files_skipped: 0,
                    files_failed: 0,
                    bytes: 0,
                    elapsed_ms: 0,
                    renamed: Vec::new(),
                    error: Some("transfer ended without a summary".into()),
                });
            })
        {
            inner.cancel();
            return Err(RemtpError::Io {
                message: error.to_string(),
            });
        }
        Ok(Arc::new(Transfer { inner }))
    }

    pub fn close(&self) {
        let device = self.inner.clone();
        if let Err(error) = wait(async move {
            device.close().await;
            Ok(())
        }) {
            eprintln!("ReMTP: {error}");
        }
    }
}

#[derive(uniffi::Object)]
pub struct Transfer {
    inner: Arc<transfer::Transfer>,
}

#[uniffi::export]
impl Transfer {
    pub fn pause(&self) {
        self.inner.pause();
    }
    pub fn resume(&self) {
        self.inner.resume();
    }
    pub fn cancel(&self) {
        self.inner.cancel();
    }
    pub fn resolve(&self, issue_id: u64, choice: ConflictChoice) {
        self.inner.resolve(issue_id, choice.into());
    }
}

fn runtime() -> Result<&'static Runtime, RemtpError> {
    static RUNTIME: OnceLock<Result<Runtime, String>> = OnceLock::new();
    RUNTIME
        .get_or_init(|| Runtime::new().map_err(|error| error.to_string()))
        .as_ref()
        .map_err(|error| RemtpError::Io {
            message: format!("could not create the ReMTP runtime: {error}"),
        })
}

fn wait<T: Send + 'static>(
    future: impl Future<Output = core::Result<T>> + Send + 'static,
) -> Result<T, RemtpError> {
    let (tx, rx) = std::sync::mpsc::sync_channel(1);
    runtime()?.spawn(async move {
        let _ = tx.send(future.await);
    });
    rx.recv()
        .map_err(|_| RemtpError::Protocol {
            message: "ReMTP runtime task ended without a result".into(),
        })?
        .map_err(Into::into)
}

impl From<core::RemtpError> for RemtpError {
    fn from(error: core::RemtpError) -> Self {
        use core::RemtpError as E;
        match error {
            E::NoDevice => Self::NoDevice,
            E::DeviceBusy { holder } => Self::DeviceBusy { holder },
            E::Disconnected => Self::Disconnected,
            E::NotFound { path } => Self::NotFound { path },
            E::AlreadyExists { path } => Self::AlreadyExists { path },
            E::Cancelled => Self::Cancelled,
            E::Io { message } => Self::Io { message },
            E::Protocol { message } => Self::Protocol { message },
            error => Self::Protocol {
                message: error.to_string(),
            },
        }
    }
}

impl From<UsbMode> for core::UsbMode {
    fn from(mode: UsbMode) -> Self {
        match mode {
            UsbMode::FileTransfer => Self::FileTransfer,
            UsbMode::ChargingOnly => Self::ChargingOnly,
        }
    }
}

impl From<core::AdbAccess> for AdbAccess {
    fn from(access: core::AdbAccess) -> Self {
        match access {
            core::AdbAccess::Off => Self::Off,
            core::AdbAccess::Ready => Self::Ready,
            core::AdbAccess::NeedsApproval => Self::NeedsApproval,
            core::AdbAccess::Unavailable { reason } => Self::Unavailable { reason },
        }
    }
}

impl From<core::AdbOnlyDevice> for AdbOnlyDevice {
    fn from(device: core::AdbOnlyDevice) -> Self {
        Self {
            id: device.id,
            manufacturer: device.manufacturer,
            model: device.model,
            name: device.name,
            serial: device.serial,
            adb: device.adb.into(),
        }
    }
}

impl From<core::UsbModeSwitch> for UsbModeSwitch {
    fn from(result: core::UsbModeSwitch) -> Self {
        match result {
            core::UsbModeSwitch::Switched { device_id } => Self::Switched { device_id },
            core::UsbModeSwitch::NeedsApproval => Self::NeedsApproval,
            core::UsbModeSwitch::Unavailable { reason } => Self::Unavailable { reason },
        }
    }
}

impl From<core::AccessState> for AccessState {
    fn from(value: core::AccessState) -> Self {
        match value {
            core::AccessState::Free => Self::Free,
            core::AccessState::HeldBy { process, pid } => Self::HeldBy { process, pid },
            core::AccessState::Unknown => Self::Unknown,
        }
    }
}

macro_rules! record {
    ($from:path => $to:path { $($plain:ident),* $(,)? } { $($nested:ident),* $(,)? } { $($list:ident),* $(,)? }) => {
        impl From<$from> for $to {
            fn from(value: $from) -> Self {
                Self { $($plain: value.$plain,)* $($nested: value.$nested.into(),)*
                    $($list: value.$list.into_iter().map(Into::into).collect(),)* }
            }
        }
    };
}

macro_rules! variants {
    ($from:ident => $to:path; $($variant:ident),+ $(,)?) => {
        impl From<$from> for $to {
            fn from(value: $from) -> Self {
                match value { $($from::$variant => Self::$variant,)+ }
            }
        }
    };
}

record!(core::DeviceSummary => DeviceSummary { id, manufacturer, model, name, serial } {} {});
record!(core::StorageInfo => StorageInfo { id, description, capacity_bytes, free_bytes, removable } {} {});
record!(core::DeviceDetails => DeviceDetails { link_speed, link_speed_mbps } { summary } { storages });
record!(core::Entry => Entry { name, is_dir, size, modified } {} {});
record!(TransferJob => transfer::TransferJob { storage_id, sources, destination, card_safe_names } { direction, conflict, verify } {});
record!(transfer::TransferProgress => TransferProgress {
    files_done, files_total, bytes_done, bytes_total, current_name, current_bytes_done, current_bytes_total,
    speed_bytes_per_sec, avg_ms_per_file, device_wait_ms_avg, idle_ms_avg, read_ahead_files, read_ahead_bytes, paused,
} {} {});
record!(transfer::IssueRetry => IssueRetry { source, folder, card_safe_name, keep_both } {} {});
impl From<transfer::TransferIssue> for TransferIssue {
    fn from(value: transfer::TransferIssue) -> Self {
        Self {
            id: value.id,
            path: value.path,
            destination_folder: value.destination_folder,
            kind: value.kind.into(),
            message: value.message,
            existing_size: value.existing_size,
            incoming_size: value.incoming_size,
            existing_modified: value.existing_modified,
            incoming_modified: value.incoming_modified,
            retry: value.retry.map(Into::into),
            conflict_source: value.conflict_source,
        }
    }
}
record!(transfer::RenamedFile => RenamedFile { from, to } {} {});
record!(transfer::TransferSummary => TransferSummary { files_copied, files_skipped, files_failed, bytes, elapsed_ms, error } {} { renamed });
variants!(Direction => transfer::Direction; ToDevice, FromDevice);
variants!(ConflictPolicy => transfer::ConflictPolicy; Ask, Replace, KeepBoth, Skip, SkipIfSame);
variants!(VerifyMode => transfer::VerifyMode; None, Size, Checksum);
variants!(ConflictChoice => transfer::ConflictChoice; Replace, KeepBoth, Skip);
use transfer::IssueKind as CoreIssueKind;
variants!(CoreIssueKind => IssueKind; Conflict, InvalidName, NameTooLong, TooLargeForStorage, NoSpace, Failed);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runtime_task_panic_is_a_protocol_error() {
        let result = wait::<()>(async { panic!("test runtime panic") });
        assert!(matches!(result, Err(RemtpError::Protocol { .. })));
    }
}
