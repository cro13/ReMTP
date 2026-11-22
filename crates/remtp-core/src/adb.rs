mod server;

use std::collections::{HashMap, HashSet};
use std::io;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use futures::{Stream, StreamExt, stream};
use nusb::{DeviceId, DeviceInfo, MaybeFuture, hotplug::HotplugEvent};

use crate::device::{DeviceKey, device_ids};
use crate::{Engine, RemtpError, Result};

const PROBE_TIMEOUT: Duration = Duration::from_millis(600);
const COMMAND_TIMEOUT: Duration = Duration::from_secs(5);
const APPROVAL_WAIT: Duration = Duration::from_secs(30);
const RECONNECT_WAIT: Duration = Duration::from_secs(15);
const POLL_PERIOD: Duration = Duration::from_millis(250);
const ACCESS_REFRESH: Duration = Duration::from_secs(2);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UsbMode {
    FileTransfer,
    ChargingOnly,
}

impl UsbMode {
    fn command(self) -> &'static str {
        match self {
            Self::FileTransfer => "svc usb setFunctions mtp",
            Self::ChargingOnly => "svc usb setFunctions",
        }
    }

    fn is_current(self, output: &str) -> bool {
        let functions = output
            .trim()
            .split(',')
            .filter(|function| !matches!(*function, "" | "adb"));
        match self {
            Self::FileTransfer => functions.eq(["mtp"]),
            Self::ChargingOnly => functions.eq(std::iter::empty::<&str>()),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AdbAccess {
    Off,
    Ready,
    NeedsApproval,
    Unavailable { reason: String },
}

impl AdbAccess {
    fn unavailable(reason: &str) -> Self {
        Self::Unavailable {
            reason: reason.into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdbOnlyDevice {
    pub id: String,
    pub manufacturer: String,
    pub model: String,
    pub name: String,
    pub serial: String,
    pub adb: AdbAccess,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UsbModeSwitch {
    Switched { device_id: Option<String> },
    NeedsApproval,
    Unavailable { reason: String },
}

impl UsbModeSwitch {
    fn from_access(access: AdbAccess) -> Self {
        match access {
            AdbAccess::NeedsApproval => Self::NeedsApproval,
            AdbAccess::Unavailable { reason } => Self::Unavailable { reason },
            AdbAccess::Off => Self::unavailable("USB debugging is off"),
            AdbAccess::Ready => Self::unavailable("ADB couldn't switch USB modes"),
        }
    }

    fn unavailable(reason: &str) -> Self {
        Self::Unavailable {
            reason: reason.into(),
        }
    }
}

#[derive(Default)]
pub(crate) struct AdbState {
    duplicates: Mutex<HashSet<String>>,
    direct_access: Mutex<HashMap<DeviceId, AdbAccess>>,
    switching: Arc<Mutex<HashMap<u64, DeviceKey>>>,
}

impl AdbState {
    pub(crate) fn is_switching(&self, key: &DeviceKey) -> bool {
        self.switching.lock().unwrap().get(&key.location) == Some(key)
    }

    fn reserve(&self, key: &DeviceKey) -> Option<SwitchGuard> {
        let mut switching = self.switching.lock().unwrap();
        let std::collections::hash_map::Entry::Vacant(entry) = switching.entry(key.location) else {
            return None;
        };
        entry.insert(key.clone());
        Some(SwitchGuard {
            switching: self.switching.clone(),
            location: key.location,
        })
    }

    fn direct_access(&self, device: &UsbDevice) -> AdbAccess {
        let mut cache = self.direct_access.lock().unwrap();
        if let Some(access) = cache.get(&device.info.id()) {
            return access.clone();
        }
        if self.is_switching(&device.identity.key) {
            return AdbAccess::unavailable("USB mode is changing");
        }
        let access = remtp_adb::keychain_key_store()
            .and_then(|keys| remtp_adb::probe(&device.info, keys.as_ref(), PROBE_TIMEOUT))
            .map_or_else(direct_error, |auth| match auth {
                remtp_adb::Authorization::Ready => AdbAccess::Ready,
                remtp_adb::Authorization::NeedsApproval => AdbAccess::NeedsApproval,
            });
        cache.insert(device.info.id(), access.clone());
        access
    }

    fn direct_switch(
        &self,
        device: &UsbDevice,
        mode: UsbMode,
    ) -> std::result::Result<CommandOutcome, AdbAccess> {
        // Wait for any probe already using the interface before starting the command.
        let id = device.info.id();
        self.direct_access.lock().unwrap().remove(&id);
        let keys = remtp_adb::keychain_key_store().map_err(direct_error)?;
        let mut unconfirmed = None;
        let outcome = send_mode(mode, device.id(mode).is_some(), |command, approval| {
            let output = match remtp_adb::shell(
                &device.info,
                command,
                keys.as_ref(),
                approval,
                COMMAND_TIMEOUT,
            ) {
                // The mode command re-enumerates the device, and macOS can report that as an
                // aborted (timed-out) transfer instead of a disconnect. Whether it worked shows
                // when the device comes back.
                Err(error @ (remtp_adb::Error::Timeout | remtp_adb::Error::Disconnected))
                    if command == mode.command() =>
                {
                    unconfirmed = Some(direct_error(error));
                    Ok(String::new())
                }
                output => output.map_err(direct_error),
            };
            let access = output
                .as_ref()
                .map_or_else(|access| (*access).clone(), |_| AdbAccess::Ready);
            self.direct_access.lock().unwrap().insert(id, access);
            output
        })?;
        Ok(match (outcome, unconfirmed) {
            (CommandOutcome::Sent, Some(access)) => CommandOutcome::Unconfirmed(access),
            (outcome, _) => outcome,
        })
    }
}

struct SwitchGuard {
    switching: Arc<Mutex<HashMap<u64, DeviceKey>>>,
    location: u64,
}

impl Drop for SwitchGuard {
    fn drop(&mut self) {
        self.switching.lock().unwrap().remove(&self.location);
    }
}

struct UsbIdentity {
    key: DeviceKey,
    has_adb: bool,
}

struct UsbDevice {
    info: DeviceInfo,
    identity: UsbIdentity,
    mtp_id: Option<String>,
    adb_only_id: Option<String>,
}

impl UsbDevice {
    fn id(&self, mode: UsbMode) -> Option<&str> {
        match mode {
            UsbMode::FileTransfer => self.mtp_id.as_deref(),
            UsbMode::ChargingOnly => self.adb_only_id.as_deref(),
        }
    }
}

fn topology_id(bus: &str, ports: &[u8]) -> u64 {
    // mtp-rs hashes the same USB topology so discovery can match its IDs back to nusb devices.
    bus.bytes()
        .chain([0xff])
        .chain(ports.iter().copied())
        .fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
            (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3)
        })
}

fn usb_identity(info: &DeviceInfo) -> UsbIdentity {
    UsbIdentity {
        key: DeviceKey {
            vendor: info.vendor_id(),
            product: info.product_id(),
            location: topology_id(info.bus_id(), info.port_chain()),
            serial: info.serial_number().unwrap_or_default().into(),
        },
        has_adb: remtp_adb::has_adb_interface(info),
    }
}

fn classify_ids(
    usb: &[&UsbIdentity],
    mtp: &HashMap<DeviceKey, String>,
    duplicates: &mut HashSet<String>,
) -> HashMap<DeviceKey, String> {
    let keys = usb
        .iter()
        .filter(|device| device.has_adb && !mtp.contains_key(&device.key))
        .map(|device| device.key.clone())
        .collect::<Vec<_>>();
    let ids = device_ids(&keys, duplicates);
    keys.into_iter().zip(ids).collect()
}

fn server_serial<'a>(
    device: &'a UsbIdentity,
    usb: &[&UsbIdentity],
) -> std::result::Result<&'a str, AdbAccess> {
    let serial = device.key.serial.trim();
    if serial.is_empty() {
        return Err(AdbAccess::unavailable("Device has no USB serial for ADB"));
    }
    if usb
        .iter()
        .filter(|other| other.has_adb && other.key.serial.trim() == serial)
        .count()
        > 1
    {
        return Err(AdbAccess::unavailable("USB serial is not unique"));
    }
    Ok(serial)
}

struct ReconnectKey {
    key: DeviceKey,
    unique_serial: bool,
}

impl ReconnectKey {
    fn new(key: &DeviceKey, usb: &[&UsbIdentity]) -> Self {
        let unique_serial = key.serial_id().is_some()
            && usb
                .iter()
                .filter(|device| same_serial(&device.key, key))
                .count()
                == 1;
        Self {
            key: key.clone(),
            unique_serial,
        }
    }

    fn find<'a, T>(&self, candidates: impl IntoIterator<Item = (&'a DeviceKey, T)>) -> Option<T> {
        let mut remaining = candidates
            .into_iter()
            .filter(|(key, _)| same_serial(key, &self.key));
        let (first, value) = remaining.next()?;
        if first.location == self.key.location {
            return Some(value);
        }
        match remaining.next() {
            None => self.unique_serial.then_some(value),
            Some(second) => std::iter::once(second)
                .chain(remaining)
                .find(|(key, _)| key.location == self.key.location)
                .map(|(_, value)| value),
        }
    }
}

fn same_serial(left: &DeviceKey, right: &DeviceKey) -> bool {
    left.vendor == right.vendor && left.serial.trim() == right.serial.trim()
}

impl Engine {
    fn usb_devices(&self) -> Result<Vec<UsbDevice>> {
        let mut devices = nusb::list_devices()
            .wait()
            .map_err(usb_error)?
            .map(|info| UsbDevice {
                identity: usb_identity(&info),
                info,
                mtp_id: None,
                adb_only_id: None,
            })
            .collect::<Vec<_>>();
        let live = devices
            .iter()
            .map(|device| device.info.id())
            .collect::<HashSet<_>>();
        self.adb
            .direct_access
            .lock()
            .unwrap()
            .retain(|id, _| live.contains(id));
        let mtp = self.mtp_ids()?;
        let mut adb_ids = classify_ids(
            &identities(&devices),
            &mtp,
            &mut self.adb.duplicates.lock().unwrap(),
        );
        for device in &mut devices {
            device.mtp_id = mtp.get(&device.identity.key).cloned();
            device.adb_only_id = adb_ids.remove(&device.identity.key);
        }
        Ok(devices)
    }

    pub fn list_adb_only_devices(&self) -> Result<Vec<AdbOnlyDevice>> {
        let usb = self.usb_devices()?;
        let identities = identities(&usb);
        let mut devices = usb
            .iter()
            .filter_map(|device| Some((device.adb_only_id.as_ref()?, device)))
            .peekable();
        if devices.peek().is_none() {
            return Ok(Vec::new());
        }
        let route = Route::select();
        let mut devices = devices
            .map(|(id, device)| {
                let model = device.info.product_string().unwrap_or_default().to_owned();
                AdbOnlyDevice {
                    id: id.clone(),
                    manufacturer: device.info.manufacturer_string().unwrap_or_default().into(),
                    name: model.clone(),
                    model,
                    serial: device.identity.key.serial.clone(),
                    adb: route.access(&self.adb, device, &identities),
                }
            })
            .collect::<Vec<_>>();
        devices.sort_unstable_by(|left, right| left.id.cmp(&right.id));
        Ok(devices)
    }

    pub fn adb_only_device_events(
        self: &Arc<Self>,
    ) -> impl Stream<Item = Vec<AdbOnlyDevice>> + use<> {
        let engine = Arc::downgrade(self);
        let watch = nusb::watch_devices().ok();
        stream::unfold(
            (engine, watch, None, true),
            |(engine, mut watch, mut previous, mut settle)| async move {
                loop {
                    let current_engine = engine.upgrade()?;
                    if let Some(devices) = &previous {
                        let event = match &mut watch {
                            Some(watch) if Vec::is_empty(devices) && !settle => {
                                Some(watch.next().await)
                            }
                            Some(watch) => tokio::time::timeout(ACCESS_REFRESH, watch.next())
                                .await
                                .ok(),
                            None => {
                                tokio::time::sleep(ACCESS_REFRESH).await;
                                None
                            }
                        };
                        match event {
                            Some(Some(HotplugEvent::Connected(_))) => settle = true,
                            Some(Some(HotplugEvent::Disconnected(id))) => {
                                current_engine.adb.direct_access.lock().unwrap().remove(&id);
                            }
                            Some(None) => watch = None,
                            None => settle = false,
                        }
                    }
                    let list = blocking(move || current_engine.list_adb_only_devices()).await;
                    let devices = match (list, &previous) {
                        (Ok(devices), _) => devices,
                        (Err(_), None) => Vec::new(),
                        (Err(_), Some(_)) => continue,
                    };
                    if previous.as_ref() != Some(&devices) {
                        previous = Some(devices.clone());
                        return Some((devices, (engine, watch, previous, settle)));
                    }
                }
            },
        )
    }

    pub fn adb_access(&self, id: &str) -> AdbAccess {
        let Ok(usb) = self.usb_devices() else {
            return AdbAccess::unavailable("Couldn't list USB devices");
        };
        let Some(device) = find(&usb, id) else {
            return AdbAccess::unavailable("Device isn't connected over USB");
        };
        if !device.identity.has_adb {
            return AdbAccess::Off;
        }
        Route::select().access(&self.adb, device, &identities(&usb))
    }

    pub async fn set_usb_mode(self: &Arc<Self>, id: &str, mode: UsbMode) -> Result<UsbModeSwitch> {
        let engine = self.clone();
        let usb = blocking(move || engine.usb_devices()).await?;
        let device = find(&usb, id).ok_or(RemtpError::NoDevice)?;
        if !device.identity.has_adb {
            return Ok(UsbModeSwitch::from_access(AdbAccess::Off));
        }
        let Some(guard) = self.adb.reserve(&device.identity.key) else {
            return Ok(UsbModeSwitch::unavailable("USB mode is already changing"));
        };
        self.close_for_usb_switch(&device.identity.key).await;
        let engine = self.clone();
        let original = device.info.id();
        let original_key = device.identity.key.clone();
        blocking(move || {
            let _guard = guard;
            let usb = engine.usb_devices()?;
            let Some(device) = usb
                .iter()
                .find(|device| device.info.id() == original && device.identity.key == original_key)
            else {
                return Ok(UsbModeSwitch::unavailable("Device disconnected"));
            };
            let devices = identities(&usb);
            let reconnect = ReconnectKey::new(&device.identity.key, &devices);
            let unconfirmed = match Route::select().switch(&engine.adb, device, &devices, mode) {
                Ok(CommandOutcome::Sent) => None,
                Ok(CommandOutcome::Unconfirmed(access)) => Some(access),
                Ok(CommandOutcome::AlreadySet) => {
                    return Ok(UsbModeSwitch::Switched {
                        device_id: device.id(mode).map(str::to_owned),
                    });
                }
                Err(access) => return Ok(UsbModeSwitch::from_access(access)),
            };
            let deadline = Instant::now() + RECONNECT_WAIT;
            loop {
                std::thread::sleep(POLL_PERIOD);
                let current = engine.usb_devices()?;
                let returned =
                    reconnect.find(current.iter().map(|device| (&device.identity.key, device)));
                if let Some(id) = returned
                    .filter(|device| {
                        device.info.id() != original
                            || device.identity.key.product != original_key.product
                    })
                    .and_then(|device| device.id(mode))
                {
                    return Ok(UsbModeSwitch::Switched {
                        device_id: Some(id.into()),
                    });
                }
                if Instant::now() >= deadline {
                    // A command that failed while the device never left USB most likely didn't run.
                    if let Some(access) = unconfirmed
                        && current.iter().any(|device| device.info.id() == original)
                    {
                        return Ok(UsbModeSwitch::from_access(access));
                    }
                    return Ok(UsbModeSwitch::Switched { device_id: None });
                }
            }
        })
        .await
    }
}

fn identities(usb: &[UsbDevice]) -> Vec<&UsbIdentity> {
    usb.iter().map(|device| &device.identity).collect()
}

fn find<'a>(usb: &'a [UsbDevice], id: &str) -> Option<&'a UsbDevice> {
    usb.iter().find(|device| {
        device.mtp_id.as_deref() == Some(id) || device.adb_only_id.as_deref() == Some(id)
    })
}

enum Route {
    Server(server::Server, Vec<server::ServerDevice>),
    Direct,
    Unavailable(AdbAccess),
}

#[derive(Debug, PartialEq, Eq)]
enum CommandOutcome {
    AlreadySet,
    Sent,
    /// The connection failed while the mode command ran: the device may or may not be switching.
    Unconfirmed(AdbAccess),
}

fn send_mode(
    mode: UsbMode,
    maybe_already_set: bool,
    mut shell: impl FnMut(&str, Duration) -> std::result::Result<String, AdbAccess>,
) -> std::result::Result<CommandOutcome, AdbAccess> {
    let mut approval = APPROVAL_WAIT;
    if maybe_already_set {
        if mode.is_current(&shell("svc usb getFunctions", approval)?) {
            return Ok(CommandOutcome::AlreadySet);
        }
        approval = Duration::ZERO;
    }
    let output = shell(mode.command(), approval)?;
    // Android may return no output when USB drops, or print an operation ID before that.
    if output
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .all(|line| {
            line.strip_prefix("setCurrentFunctions opId:")
                .is_some_and(|id| id.trim().parse::<i64>().is_ok())
        })
    {
        Ok(CommandOutcome::Sent)
    } else {
        Err(AdbAccess::unavailable(
            "Android refused the USB mode command",
        ))
    }
}

impl Route {
    fn select() -> Self {
        let server = server::Server::local();
        match server.connect() {
            Ok(stream) => match server::devices(stream) {
                Ok(devices) => Self::Server(server, devices),
                Err(error) => Self::Unavailable(server_error(error)),
            },
            Err(error) if error.kind() == io::ErrorKind::ConnectionRefused => Self::Direct,
            Err(_) => Self::Unavailable(AdbAccess::unavailable(
                "Couldn't reach the local ADB server",
            )),
        }
    }

    fn access(&self, state: &AdbState, device: &UsbDevice, usb: &[&UsbIdentity]) -> AdbAccess {
        match self {
            Self::Server(_, devices) => server_serial(&device.identity, usb)
                .map_or_else(|access| access, |serial| server::access(devices, serial)),
            Self::Direct => state.direct_access(device),
            Self::Unavailable(access) => access.clone(),
        }
    }

    fn switch(
        self,
        state: &AdbState,
        device: &UsbDevice,
        usb: &[&UsbIdentity],
        mode: UsbMode,
    ) -> std::result::Result<CommandOutcome, AdbAccess> {
        match self {
            Self::Server(server, devices) => {
                let serial = server_serial(&device.identity, usb)?;
                let mut access = server::access(&devices, serial);
                let deadline = Instant::now() + APPROVAL_WAIT;
                while access == AdbAccess::NeedsApproval && Instant::now() < deadline {
                    std::thread::sleep(POLL_PERIOD);
                    let devices = server.devices().map_err(server_error)?;
                    access = server::access(&devices, serial);
                }
                if access != AdbAccess::Ready {
                    return Err(access);
                }
                send_mode(mode, device.id(mode).is_some(), |command, _| {
                    server.shell(serial, command).map_err(server_error)
                })
            }
            Self::Direct => state.direct_switch(device, mode),
            Self::Unavailable(access) => Err(access),
        }
    }
}

fn server_error(error: server::Error) -> AdbAccess {
    match error {
        server::Error::Rejected(text) if text.contains("unauthorized") => AdbAccess::NeedsApproval,
        server::Error::Rejected(text) if text.contains("offline") => {
            AdbAccess::unavailable("Device is offline in ADB")
        }
        server::Error::Io(error)
            if matches!(
                error.kind(),
                io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
            ) =>
        {
            AdbAccess::unavailable("ADB server timed out")
        }
        _ => AdbAccess::unavailable("Couldn't communicate with the ADB server"),
    }
}

fn direct_error(error: remtp_adb::Error) -> AdbAccess {
    use remtp_adb::Error;
    match error {
        Error::NoAdbInterface => AdbAccess::Off,
        Error::NeedsApproval => AdbAccess::NeedsApproval,
        Error::Busy => AdbAccess::unavailable("Another program is using ADB"),
        Error::Disconnected => AdbAccess::unavailable("Device disconnected"),
        Error::Timeout => AdbAccess::unavailable("ADB timed out"),
        Error::Key(_) => AdbAccess::unavailable("Couldn't use ReMTP's ADB key"),
        Error::Unsupported => {
            AdbAccess::unavailable("Direct USB ADB isn't supported on this platform")
        }
        Error::Protocol(_) => {
            AdbAccess::unavailable("Couldn't communicate with the device over ADB")
        }
    }
}

fn usb_error(error: nusb::Error) -> RemtpError {
    RemtpError::Io {
        message: format!("Couldn't list USB devices: {error}"),
    }
}

async fn blocking<T: Send + 'static>(
    work: impl FnOnce() -> Result<T> + Send + 'static,
) -> Result<T> {
    tokio::task::spawn_blocking(work)
        .await
        .map_err(|error| RemtpError::TaskFailed {
            message: format!("USB mode task failed: {error}"),
        })?
}

#[cfg(test)]
mod tests {
    use super::*;

    fn identity(product: u16, location: u64, serial: &str, has_adb: bool) -> UsbIdentity {
        UsbIdentity {
            key: DeviceKey {
                vendor: 0xfade,
                product,
                location,
                serial: serial.into(),
            },
            has_adb,
        }
    }

    #[test]
    fn switch_command_accepts_operation_id_or_disconnect_but_not_an_error() {
        for output in ["", "setCurrentFunctions opId:1\r\n"] {
            assert_eq!(
                send_mode(UsbMode::FileTransfer, false, |command, approval| {
                    assert_eq!(command, "svc usb setFunctions mtp");
                    assert_eq!(approval, APPROVAL_WAIT);
                    Ok(output.into())
                }),
                Ok(CommandOutcome::Sent)
            );
        }
        assert_eq!(
            send_mode(UsbMode::FileTransfer, false, |_, _| Ok(
                "Invalid USB functions".into()
            )),
            Err(AdbAccess::unavailable(
                "Android refused the USB mode command"
            ))
        );
    }

    #[test]
    fn charging_check_does_not_confuse_midi_with_charging_only() {
        assert_eq!(
            send_mode(UsbMode::ChargingOnly, true, |command, approval| {
                assert_eq!(command, "svc usb getFunctions");
                assert_eq!(approval, APPROVAL_WAIT);
                Ok("\n".into())
            }),
            Ok(CommandOutcome::AlreadySet)
        );
        let mut commands = [
            ("svc usb getFunctions", APPROVAL_WAIT, "midi\n"),
            ("svc usb setFunctions", Duration::ZERO, ""),
        ]
        .into_iter();
        assert_eq!(
            send_mode(UsbMode::ChargingOnly, true, |command, approval| {
                let (expected_command, expected_approval, output) = commands.next().unwrap();
                assert_eq!((command, approval), (expected_command, expected_approval));
                Ok(output.into())
            }),
            Ok(CommandOutcome::Sent)
        );
        assert!(commands.next().is_none());
    }

    #[test]
    fn adb_only_excludes_mtp_and_reuses_device_id_rules() {
        let mtp = identity(1, 1, "FAKE-001", true);
        let charging = identity(1, 2, "FAKE-002", true);
        let duplicate = identity(1, 3, "FAKE-002", true);
        let missing = identity(1, 4, "", true);
        let no_adb = identity(1, 5, "FAKE-003", false);
        let unique = identity(1, 6, "FAKE-004", true);
        let devices = [&mtp, &charging, &duplicate, &missing, &no_adb, &unique];
        let mtp_ids = HashMap::from([(mtp.key.clone(), "fade:0001:FAKE-001".into())]);
        let mut duplicates = HashSet::new();
        let ids = classify_ids(&devices, &mtp_ids, &mut duplicates);
        assert_eq!(ids.len(), 4);
        assert_eq!(ids[&charging.key], "fade:0001:loc0000000000000002");
        assert_eq!(ids[&duplicate.key], "fade:0001:loc0000000000000003");
        assert_eq!(ids[&missing.key], "fade:0001:loc0000000000000004");
        assert_eq!(ids[&unique.key], "fade:0001:FAKE-004");
        assert_eq!(
            classify_ids(&[&charging], &mtp_ids, &mut duplicates)[&charging.key],
            ids[&charging.key]
        );
    }

    #[test]
    fn changing_product_keeps_identity_but_does_not_match_other_vendors() {
        let before = identity(1, 1, "FAKE-001", true);
        let after = identity(2, 2, "FAKE-001", true);
        let mut other_vendor = identity(2, 1, "FAKE-001", true);
        other_vendor.key.vendor = 0xcafe;
        let reconnect = ReconnectKey::new(&before.key, &[&before, &other_vendor]);
        assert_eq!(
            reconnect.find([(&other_vendor.key, "wrong vendor"), (&after.key, "new id")]),
            Some("new id")
        );
        assert_eq!(reconnect.find([(&other_vendor.key, "wrong vendor")]), None);
    }

    #[test]
    fn duplicate_or_placeholder_serials_require_the_same_physical_port() {
        let before = identity(1, 1, "FAKE-001", true);
        let other = identity(2, 2, "FAKE-001", true);
        let after = identity(2, 1, "FAKE-001", true);
        let reconnect = ReconnectKey::new(&before.key, &[&before, &other]);
        assert_eq!(reconnect.find([(&other.key, "unrelated")]), None);
        assert_eq!(
            reconnect.find([(&other.key, "unrelated"), (&after.key, "same port")]),
            Some("same port")
        );
        assert_eq!(
            server_serial(&before, &[&before, &other]),
            Err(AdbAccess::unavailable("USB serial is not unique"))
        );
        let unspecified = identity(1, 1, "000000", true);
        let other = identity(2, 2, "000000", true);
        assert_eq!(
            ReconnectKey::new(&unspecified.key, &[&unspecified]).find([(&other.key, "unrelated")]),
            None
        );
    }
}
