//! Direct-USB ADB: talks to `adbd` over a device's ADB interface without an adb server.
//!
//! ReMTP uses this only when no local adb server is running (docs/DESIGN.md, "adb ownership"): a
//! running server already holds every ADB interface, and ReMTP never uses both or stops another
//! tool's server. The server route lives in `remtp-core` (`adb` module).
//!
//! The device authorizes this computer by RSA key. ReMTP has its own key (not `~/.android/adbkey`),
//! created on first use and kept in the login Keychain on macOS. A new key makes the device ask
//! "Allow USB debugging?" once.
//!
//! All calls block; call them off the main thread.

use std::sync::Arc;
use std::time::Duration;

#[cfg(any(target_os = "macos", test))]
mod key;
#[cfg(target_os = "macos")]
mod keychain;
mod protocol;
mod usb;

/// USB interface class, subclass and protocol of `adbd`'s interface.
pub const ADB_CLASS: u8 = 0xff;
pub const ADB_SUBCLASS: u8 = 0x42;
pub const ADB_PROTOCOL: u8 = 0x01;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("the device has no ADB interface (USB debugging is off)")]
    NoAdbInterface,
    /// The ADB interface is claimed by another program (an adb server, Android Studio, …).
    #[error("another program is using ADB on this device")]
    Busy,
    /// The device hasn't accepted this computer's key: it shows (or showed) "Allow USB debugging?".
    #[error("the device hasn't allowed USB debugging from this computer")]
    NeedsApproval,
    /// The device left USB before the command started.
    #[error("the device disconnected")]
    Disconnected,
    #[error("ADB timed out")]
    Timeout,
    #[error("ADB key: {0}")]
    Key(String),
    #[error("ADB: {0}")]
    Protocol(String),
    /// No key store on this platform (direct ADB is macOS-only for now).
    #[error("direct ADB isn't supported on this platform")]
    Unsupported,
}

pub type Result<T> = std::result::Result<T, Error>;

/// Whether the device already accepts this computer's key.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Authorization {
    Ready,
    NeedsApproval,
}

/// The RSA key this computer authenticates with.
pub trait KeyStore: Send + Sync {
    /// The public key in adbd's format: base64 of the 524-byte `RSAPublicKey` struct (len, n0inv,
    /// n, rr, exponent; little-endian u32 words), a space, and a name. No trailing NUL.
    fn adb_public_key(&self) -> Result<String>;
    /// PKCS#1 v1.5 signature of the 20-byte AUTH token treated as a SHA-1 digest (what adbd checks
    /// with `RSA_verify(NID_sha1, …)`).
    fn sign(&self, token: &[u8]) -> Result<Vec<u8>>;
}

/// ReMTP's own key: RSA-2048, created on first use and kept in the login Keychain (macOS).
/// `Err(Unsupported)` on other platforms.
pub fn keychain_key_store() -> Result<Arc<dyn KeyStore>> {
    #[cfg(target_os = "macos")]
    {
        keychain::load()
    }
    #[cfg(not(target_os = "macos"))]
    {
        Err(Error::Unsupported)
    }
}

/// Whether `device` exposes adbd's interface (USB debugging is on).
pub fn has_adb_interface(device: &nusb::DeviceInfo) -> bool {
    device.interfaces().any(|interface| {
        is_adb_class(
            interface.class(),
            interface.subclass(),
            interface.protocol(),
        )
    })
}

fn is_adb_class(class: u8, subclass: u8, protocol: u8) -> bool {
    (class, subclass, protocol) == (ADB_CLASS, ADB_SUBCLASS, ADB_PROTOCOL)
}

/// Handshake only (CNXN, then AUTH with the signature): whether the device already accepts this
/// computer's key. Never offers the public key, so the device never shows a prompt.
pub fn probe(
    device: &nusb::DeviceInfo,
    keys: &dyn KeyStore,
    timeout: Duration,
) -> Result<Authorization> {
    protocol::Connection::new(usb::UsbPipe::open(device)?, timeout).connect(keys, Duration::ZERO)
}

/// Runs `command` through the `shell:` service and returns its output (stdout and stderr together).
///
/// When the key isn't accepted yet, offers the public key (the device asks "Allow USB debugging?")
/// and waits up to `approval` for the user; `Err(NeedsApproval)` when that runs out (a zero
/// `approval` fails right away). `timeout` bounds each USB transfer and the command itself.
/// Once the device has accepted the OPEN (the command is running), a disconnect ends the output
/// instead of being an error: `svc usb setFunctions` re-enumerates the device while it runs.
pub fn shell(
    device: &nusb::DeviceInfo,
    command: &str,
    keys: &dyn KeyStore,
    approval: Duration,
    timeout: Duration,
) -> Result<String> {
    let mut connection = protocol::Connection::new(usb::UsbPipe::open(device)?, timeout);
    match connection.connect(keys, approval)? {
        Authorization::Ready => connection.shell(command),
        Authorization::NeedsApproval => Err(Error::NeedsApproval),
    }
}
