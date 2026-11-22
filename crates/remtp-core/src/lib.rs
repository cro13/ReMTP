pub mod access;
pub mod adb;
pub mod device;
pub mod names;
pub mod transfer;
pub mod transport;
mod tree;

pub use access::AccessState;
pub use adb::{AdbAccess, AdbOnlyDevice, UsbMode, UsbModeSwitch};
pub use device::{Device, Engine};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum RemtpError {
    #[error("no such device")]
    NoDevice,
    #[error("device is held by {holder}")]
    DeviceBusy { holder: String },
    #[error("device disconnected")]
    Disconnected,
    #[error("MTP operation timed out; reopen the device before trying again")]
    MtpTimeout,
    #[error("not found: {path}")]
    NotFound { path: String },
    #[error("already exists: {path}")]
    AlreadyExists { path: String },
    #[error("storage full")]
    NoSpace,
    #[error("stale object handle")]
    StaleHandle,
    #[error("cancelled")]
    Cancelled,
    #[error(
        "delete of {path} stopped at {next}; {remaining} object(s) not confirmed deleted: {source}"
    )]
    DeleteIncomplete {
        path: String,
        next: String,
        remaining: usize,
        source: Box<Self>,
    },
    #[error("{message}")]
    Io { message: String },
    #[error("{message}")]
    Protocol { message: String },
    #[error("{message}")]
    TaskFailed { message: String },
    #[error("{source}; {operation}: {cleanup}")]
    Cleanup {
        source: Box<Self>,
        operation: &'static str,
        cleanup: Box<Self>,
    },
}

pub type Result<T> = std::result::Result<T, RemtpError>;

impl RemtpError {
    fn with_cleanup(self, operation: &'static str, result: Result<()>) -> Self {
        match result {
            Ok(()) => self,
            Err(cleanup) => Self::Cleanup {
                source: Box::new(self),
                operation,
                cleanup: Box::new(cleanup),
            },
        }
    }

    fn is_disconnected(&self) -> bool {
        match self {
            Self::Disconnected | Self::MtpTimeout => true,
            Self::DeleteIncomplete { source, .. } => source.is_disconnected(),
            Self::Cleanup {
                source, cleanup, ..
            } => source.is_disconnected() || cleanup.is_disconnected(),
            _ => false,
        }
    }

    fn stops_transfer(&self) -> bool {
        match self {
            Self::Cancelled | Self::Disconnected | Self::MtpTimeout | Self::TaskFailed { .. } => {
                true
            }
            Self::DeleteIncomplete { source, .. } => source.stops_transfer(),
            Self::Cleanup {
                source, cleanup, ..
            } => source.stops_transfer() || cleanup.stops_transfer(),
            _ => false,
        }
    }
}

impl From<std::io::Error> for RemtpError {
    fn from(error: std::io::Error) -> Self {
        match error.kind() {
            std::io::ErrorKind::StorageFull => Self::NoSpace,
            _ => Self::Io {
                message: error.to_string(),
            },
        }
    }
}

#[derive(Clone, Debug)]
pub struct DeviceSummary {
    /// `VID:PID:serial` uses a unique, trimmed USB serial. Serial numbers shorter than six
    /// characters, repeated digits, known dummy strings (such as `1234567`), values in the
    /// reserved `loc<location>` form, and duplicates use `VID:PID:loc<location>` instead.
    /// VID, PID, and location are hexadecimal. Location IDs are stable on the same USB port;
    /// once seen duplicated, a serial stays ambiguous for the lifetime of the engine.
    pub id: String,
    pub manufacturer: String,
    pub model: String,
    pub name: String,
    pub serial: String,
}

#[derive(Clone, Debug)]
pub struct StorageInfo {
    pub id: u32,
    pub description: String,
    pub capacity_bytes: u64,
    pub free_bytes: u64,
    pub removable: bool,
}

#[derive(Clone, Debug)]
pub struct DeviceDetails {
    pub summary: DeviceSummary,
    pub link_speed: Option<String>,
    pub link_speed_mbps: Option<u32>,
    pub storages: Vec<StorageInfo>,
}

#[derive(Clone, Debug)]
pub struct Entry {
    pub name: String,
    pub is_dir: bool,
    pub size: u64,
    pub modified: Option<i64>,
}
