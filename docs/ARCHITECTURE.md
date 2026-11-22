# ReMTP architecture

```
apps/macos      Native macOS app (Swift, SwiftUI shell + AppKit lists). XcodeGen project.
apps/windows    Native Windows app (later, same Rust core).
crates/remtp-core   All device and transfer logic. No UI, no FFI types.
crates/remtp-ffi    UniFFI bindings over remtp-core (the contract below). Static lib for the apps.
crates/remtp-cli    `remtp` command-line tool on remtp-core: devices, info, ls, push, pull, mkdir, rm, usb-mode, access, release, restore, bench.
crates/remtp-adb    Direct-USB ADB (adbd wire protocol, RSA auth, ReMTP's key in the Keychain), used when no adb server runs.
scripts/            Build glue (Rust static libs, Swift bindings, XCFramework).
```

The apps never talk to MTP directly. Everything goes through `remtp-ffi`, whose API is fixed below so
the UI and the core can be built in parallel.

## remtp-core

- `transport` — `trait Transport` (list, stat, mkdir, delete, rename, upload stream, download stream,
  thumbnail, storages, events). `MtpTransport` on `mtp-rs`; a `MemoryTransport` for tests. ADB/FTP later.
- `device` — one session actor per device. All device operations are serialized through it.
- `tree` — cached listing per storage: path → object handle + entry. Filled with bulk listings, updated
  locally after every mutation and from device events. Never re-list a folder after each file.
- `transfer` — planner (expands folders, creates destination folders up front, detects conflicts and
  bad names before any byte moves), read-ahead pipeline, queue with pause/resume/cancel, metrics.
- `names` — card-safe names: replace `" * / : < > ? \ |` and control chars with `_`, strip trailing
  dots/spaces, limit 255 UTF-16 units, NFC-normalize. Returns a mapping for every rename.
- `adb` — ADB for switching an Android device's USB mode: finds devices whose ADB interface is the only
  thing on USB (USB debugging on, file transfer off), and runs `svc usb setFunctions` through the local adb
  server when one runs, else directly over USB (`remtp-adb`). Never both; never stops another tool's server.
- `access` (macOS only) — who holds the device (ioreg `IOUserClientCreator` / exclusive owner), opt-in
  release of `ptpcamerad`, restore, crash recovery via a state file.

### Transfer engine rules (MTP done right)

1. Never wait on a USB timeout: no zero-length-packet guesswork (mtp-rs handles framing).
2. Plan with bulk listings; one listing per destination folder, cached.
3. Create all destination folders before sending files.
4. New files are written directly. Replacing an existing file uploads under a temporary hidden name in the
   same folder, then deletes the old one and renames the temp file.
5. Host-side pipelines: uploads read ahead into a bounded pooled buffer (default 256 MiB or 64 files) on a
   dedicated blocking thread, and downloads write behind through a bounded queue + buffered writer, so the
   USB pipe never waits for disk. Large files stream; peak memory stays bounded.
6. Send the source modification date with every upload (`NewObjectInfo`), then never trust device dates
   for comparison when the device is known to drop them.
7. Metrics per file: time sending data, **device wait** (last data chunk handed over → upload call
   returns, i.e. the device's media scan + response), and **idle** (previous file done → next file
   starts). Exposed as rolling averages.
8. Progress callbacks are throttled to about 10 per second.

## FFI contract (remtp-ffi, UniFFI proc-macros)

Paths on the device are `/`-separated and relative to a storage root (`/` is the root,
`/Download/Lisbon 2026` a folder). Local paths are absolute POSIX paths. Times are Unix seconds.
All blocking calls are safe to call from any thread; the Swift side calls them off the main thread.

```rust
uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum RemtpError {
    #[error("no such device")] NoDevice,
    #[error("device is held by {holder}")] DeviceBusy { holder: String },
    #[error("device disconnected")] Disconnected,
    #[error("not found: {path}")] NotFound { path: String },
    #[error("already exists: {path}")] AlreadyExists { path: String },
    #[error("cancelled")] Cancelled,
    #[error("{message}")] Io { message: String },
    #[error("{message}")] Protocol { message: String },
}

#[derive(uniffi::Record)]
pub struct DeviceSummary { pub id: String, pub manufacturer: String, pub model: String, pub name: String, pub serial: String }
// id: stable per device (serial, or USB location when there is no serial). name: friendly name if the device has one, else model.

#[derive(uniffi::Record)]
pub struct StorageInfo { pub id: u32, pub description: String, pub capacity_bytes: u64, pub free_bytes: u64, pub removable: bool }

#[derive(uniffi::Record)]
pub struct DeviceDetails { pub summary: DeviceSummary, pub link_speed: Option<String>, pub link_speed_mbps: Option<u32>, pub storages: Vec<StorageInfo> }
// link_speed: "USB 2.0", "USB 3.2 Gen 1", …

#[derive(uniffi::Record)]
pub struct Entry { pub name: String, pub is_dir: bool, pub size: u64, pub modified: Option<i64> }

#[derive(uniffi::Enum)]
pub enum AccessState { Free, HeldBy { process: String, pid: Option<u32> }, Unknown }

#[uniffi::export(with_foreign)]
pub trait DeviceEventListener: Send + Sync {
    fn on_device_added(&self, device: DeviceSummary);
    fn on_device_removed(&self, device_id: String);
}

#[derive(uniffi::Object)] pub struct Engine { /* … */ }
#[uniffi::export]
impl Engine {
    #[uniffi::constructor] pub fn new() -> Arc<Self>;          // also restores ptpcamerad if a previous run crashed while holding it
    pub fn version(&self) -> String;
    pub fn list_devices(&self) -> Result<Vec<DeviceSummary>, RemtpError>;
    pub fn open(&self, device_id: String) -> Result<Arc<Device>, RemtpError>;   // DeviceBusy if another process holds it
    pub fn set_event_listener(&self, listener: Arc<dyn DeviceEventListener>);  // hot-plug
    pub fn access_state(&self, device_id: String) -> AccessState;
    pub fn release_system_hold(&self, device_id: String) -> Result<(), RemtpError>; // opt-in; suppresses ptpcamerad, then opens
    pub fn restore_system_hold(&self) -> Result<(), RemtpError>;                    // undo only what ReMTP changed
    pub fn list_adb_only_devices(&self) -> Result<Vec<AdbOnlyDevice>, RemtpError>;    // USB debugging on, file transfer off
    pub fn set_adb_only_device_listener(&self, listener: Arc<dyn AdbOnlyDeviceListener>); // whole list on change, and once on set
    pub fn adb_access(&self, device_id: String) -> AdbAccess;                       // either kind of id; cheap, never prompts
    pub fn set_usb_mode(&self, device_id: String, mode: UsbMode) -> Result<UsbModeSwitch, RemtpError>; // see below
}

// USB modes. Android picks its USB function (file transfer, charging only, MIDI, tethering, PTP) on the device;
// with USB debugging on, `svc usb setFunctions mtp` / `svc usb setFunctions` (none) switches it from the computer.
// The device then leaves USB and comes back with a different product ID, so its id changes with the mode:
// the app matches the two ids by vendor and serial.
#[derive(uniffi::Enum)] pub enum UsbMode { FileTransfer, ChargingOnly }
#[derive(uniffi::Enum)]
pub enum AdbAccess { Off, Ready, NeedsApproval, Unavailable { reason: String } }
// Off: no ADB interface (USB debugging off). NeedsApproval: "Allow USB debugging?" on the device first.

#[derive(uniffi::Record)]
pub struct AdbOnlyDevice { pub id: String, pub manufacturer: String, pub model: String, pub name: String, pub serial: String, pub adb: AdbAccess }
// On USB with only its ADB interface: charging only (or MIDI, tethering). Not openable. name: the model.

#[derive(uniffi::Enum)]
pub enum UsbModeSwitch { Switched { device_id: Option<String> }, NeedsApproval, Unavailable { reason: String } }
// set_usb_mode closes ReMTP's session with the device, runs the switch through ADB (the adb server if one is
// running, else direct USB), and waits until the device is back on USB in the new mode: device_id is its new id
// (a DeviceSummary id for FileTransfer, an AdbOnlyDevice id for ChargingOnly), None if it didn't come back in
// time. When the device still has to allow this computer, it asks on its screen and the call waits a while
// for the user before returning NeedsApproval. RemtpError only for unknown ids and unexpected failures.

#[uniffi::export(with_foreign)]
pub trait AdbOnlyDeviceListener: Send + Sync { fn on_adb_only_devices_changed(&self, devices: Vec<AdbOnlyDevice>); }

#[derive(uniffi::Object)] pub struct Device { /* … */ }
#[uniffi::export]
impl Device {
    pub fn details(&self) -> Result<DeviceDetails, RemtpError>;   // refreshes free space
    pub fn list(&self, storage_id: u32, path: String) -> Result<Vec<Entry>, RemtpError>;
    pub fn stat(&self, storage_id: u32, path: String) -> Result<Entry, RemtpError>;
    pub fn create_folder(&self, storage_id: u32, path: String) -> Result<(), RemtpError>; // like mkdir -p
    pub fn delete(&self, storage_id: u32, path: String) -> Result<(), RemtpError>;        // recursive
    pub fn rename(&self, storage_id: u32, path: String, new_name: String) -> Result<(), RemtpError>;
    pub fn thumbnail(&self, storage_id: u32, path: String) -> Result<Option<Vec<u8>>, RemtpError>; // see below
    pub fn invalidate(&self, storage_id: u32, path: String);                               // drop cached listing
    pub fn start_transfer(&self, job: TransferJob, observer: Arc<dyn TransferObserver>) -> Result<Arc<Transfer>, RemtpError>;
    pub fn close(&self);
}

// thumbnail: the device's own thumbnail of an image or video (usually a small JPEG; Vec<u8> is Swift `Data`),
// found through the cached tree like any other path. None for other files (by extension) and folders, and when
// the device has no thumbnail for the object or doesn't support GetThumb. Serialized with every other
// operation, so the app asks for one at a time per device and holds off while a transfer runs.

#[derive(uniffi::Enum)] pub enum Direction { ToDevice, FromDevice }
#[derive(uniffi::Enum)] pub enum ConflictPolicy { Ask, Replace, KeepBoth, Skip, SkipIfSame }
#[derive(uniffi::Enum)] pub enum VerifyMode { None, Size, Checksum }
#[derive(uniffi::Enum)] pub enum ConflictChoice { Replace, KeepBoth, Skip }
#[derive(uniffi::Enum)] pub enum IssueKind { Conflict, InvalidName, NameTooLong, TooLargeForStorage, NoSpace, Failed }

#[derive(uniffi::Record)]
pub struct TransferJob {
    pub direction: Direction,
    pub storage_id: u32,
    pub sources: Vec<String>,     // ToDevice: local paths; FromDevice: device paths. Folders recurse.
    pub destination: String,      // ToDevice: device folder; FromDevice: local folder
    pub conflict: ConflictPolicy,
    pub verify: VerifyMode,
    pub card_safe_names: bool,    // default true when the storage is removable
    pub pending_sources: Option<Vec<String>>, // exact source files to replan under the original roots; None plans all
}

#[derive(uniffi::Record)]
pub struct TransferProgress {
    pub files_done: u32, pub files_total: u32,
    pub bytes_done: u64, pub bytes_total: u64,
    pub current_name: String, pub current_bytes_done: u64, pub current_bytes_total: u64,
    pub speed_bytes_per_sec: u64,           // smoothed over ~2 s
    pub avg_ms_per_file: u32, pub device_wait_ms_avg: u32, pub idle_ms_avg: u32,
    pub read_ahead_files: u32, pub read_ahead_bytes: u64,
    pub paused: bool,
}

#[derive(uniffi::Record)]
pub struct TransferIssue {
    pub id: u64, pub path: String,
    pub destination_folder: String,    // destination-side path, including for issues reported against a source path
    pub kind: IssueKind, pub message: String,
    pub existing_size: Option<u64>, pub incoming_size: Option<u64>,
    pub existing_modified: Option<i64>, pub incoming_modified: Option<i64>,   // conflict dates, Unix seconds
    pub retry: Option<IssueRetry>,   // how the file can be copied again on its own, when that can work
    pub conflict_source: Option<String>, // exact source path for an Ask conflict, including if the user skips it
}

#[derive(uniffi::Record)]
pub struct IssueRetry {
    pub source: String, pub folder: String,   // the file's source and the destination folder it was going to
    pub card_safe_name: Option<String>,       // copy with card_safe_names under this name (its own name failed)
    pub keep_both: bool,                      // copy with KeepBoth (the name is taken by something unreplaceable)
}

#[derive(uniffi::Record)] pub struct RenamedFile { pub from: String, pub to: String }

#[derive(uniffi::Record)]
pub struct TransferSummary {
    pub files_copied: u32, pub files_skipped: u32, pub files_failed: u32,
    pub bytes: u64, pub elapsed_ms: u64, pub renamed: Vec<RenamedFile>,
    pub error: Option<String>,   // set when the whole job stopped (disconnect, cancel)
}

#[uniffi::export(with_foreign)]
pub trait TransferObserver: Send + Sync {
    fn on_planned(&self, files_total: u32, bytes_total: u64);
    fn on_pending_sources(&self, sources: Vec<String>); // planned source files that can still be copied, including Ask conflicts
    fn on_progress(&self, progress: TransferProgress);
    fn on_file_done(&self, source: String, destination: String, bytes: u64); // exact source and published destination paths
    fn on_file_left_out(&self, source: String); // a planned source was skipped or left to an individual problem row
    fn on_issue(&self, issue: TransferIssue);      // with ConflictPolicy::Ask the file waits for resolve(); others continue
    fn on_finished(&self, summary: TransferSummary);
}

#[derive(uniffi::Object)] pub struct Transfer { /* … */ }
#[uniffi::export]
impl Transfer {
    pub fn pause(&self);
    pub fn resume(&self);
    pub fn cancel(&self);
    pub fn resolve(&self, issue_id: u64, choice: ConflictChoice);
}
```

`remtp-ffi` also builds a `uniffi-bindgen` binary (`cargo run -p remtp-ffi --bin uniffi-bindgen --features cli`)
used by `scripts/build-macos-core.sh` to generate the Swift bindings.
