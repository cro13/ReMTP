#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AccessState {
    Free,
    HeldBy { process: String, pid: Option<u32> },
    Unknown,
}

#[cfg(target_os = "macos")]
mod platform {
    use std::fs::{self, File, OpenOptions};
    use std::io::{ErrorKind, Write};
    use std::path::PathBuf;
    use std::process::{self, Command, Output};

    use mtp_rs::mtp::MtpDeviceInfo;

    use super::AccessState;
    use crate::{RemtpError, Result};

    const SERVICE: &str = "com.apple.ptpcamerad";

    #[derive(Default)]
    struct Node<'a> {
        depth: usize,
        kind: &'a str,
        properties: Vec<(&'a str, &'a str)>,
    }

    impl<'a> Node<'a> {
        fn field(&self, key: &str) -> Option<&'a str> {
            self.properties
                .iter()
                .find_map(|&(k, v)| (k == key).then_some(v))
        }
    }

    fn nodes(text: &str) -> Vec<Node<'_>> {
        let mut nodes: Vec<Node<'_>> = Vec::new();
        for line in text.lines() {
            if let Some(depth) = line
                .find("+-o ")
                .filter(|&index| line[..index].trim_matches([' ', '|']).is_empty())
            {
                let kind = line
                    .split_once("<class ")
                    .and_then(|(_, rest)| rest.split_once(','))
                    .map_or("", |(kind, _)| kind);
                nodes.push(Node {
                    depth,
                    kind,
                    properties: Vec::new(),
                });
            } else if let (Some(node), Some((key, value))) = (
                nodes.last_mut(),
                line.trim_start_matches([' ', '|']).split_once(" = "),
            ) {
                node.properties
                    .push((key.trim_matches('"'), value.trim().trim_matches('"')));
            }
        }
        nodes
    }

    fn number(text: &str) -> Option<u32> {
        if let Some(hex) = text.strip_prefix("0x") {
            u32::from_str_radix(hex, 16).ok()
        } else {
            text.parse().ok()
        }
    }

    fn location_hash(id: u32) -> u64 {
        let bus = format!("{:02x}", id >> 24);
        let mut ports = id << 8;
        let chain = std::iter::from_fn(move || {
            if ports == 0 {
                return None;
            }
            let port = (ports >> 28) as u8;
            ports <<= 4;
            Some(port)
        });
        bus.bytes()
            .chain([0xff])
            .chain(chain)
            .fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
                (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3)
            })
    }

    fn owner(value: &str) -> Option<AccessState> {
        let value = value.trim();
        if value.is_empty() || matches!(value, "0" | "None" | "(null)" | "No" | "false") {
            return None;
        }
        let (pid, name) = if let Some(value) = value.strip_prefix("pid ") {
            let (pid, name) = value.split_once(',').unwrap_or((value, ""));
            (number(pid.trim()), name.trim())
        } else if let Some(pid) = number(value) {
            (Some(pid), "")
        } else {
            (None, value)
        };
        if pid == Some(process::id()) {
            return Some(AccessState::Free);
        }
        let process = if name.is_empty() {
            pid.and_then(process_name)
                .unwrap_or_else(|| "another process".into())
        } else {
            name.rsplit('/').next().unwrap_or(name).into()
        };
        Some(AccessState::HeldBy { process, pid })
    }

    fn process_name(pid: u32) -> Option<String> {
        let output = Command::new("/bin/ps")
            .args(["-p", &pid.to_string(), "-o", "comm="])
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        let output = String::from_utf8_lossy(&output.stdout);
        Some(output.trim().rsplit('/').next()?.to_owned()).filter(|name| !name.is_empty())
    }

    fn find_owner(
        text: &str,
        vendor: u16,
        product: u16,
        serial: Option<&str>,
        location: u64,
    ) -> AccessState {
        let nodes = nodes(text);
        let candidates = || {
            nodes.iter().enumerate().filter(|(_, node)| {
                node.kind == "IOUSBHostDevice"
                    && node.field("idVendor").and_then(number) == Some(u32::from(vendor))
                    && node.field("idProduct").and_then(number) == Some(u32::from(product))
            })
        };
        let Some((index, device)) = candidates()
            .find(|(_, node)| {
                node.field("locationID").and_then(number).map(location_hash) == Some(location)
            })
            .or_else(|| {
                let serial = serial.filter(|s| !s.is_empty())?;
                let mut matching = candidates()
                    .filter(|(_, node)| node.field("USB Serial Number") == Some(serial));
                let device = matching.next()?;
                matching.next().is_none().then_some(device)
            })
        else {
            return AccessState::Unknown;
        };
        let mut found_interface = false;
        let mut mtp_depth = None;
        for node in nodes
            .iter()
            .skip(index + 1)
            .take_while(|node| node.depth > device.depth && node.kind != "IOUSBHostDevice")
        {
            if mtp_depth.is_some_and(|depth| node.depth <= depth) {
                mtp_depth = None;
            }
            if node.kind == "IOUSBHostInterface" {
                let interface_string = node
                    .field("USB Interface Name")
                    .unwrap_or_default()
                    .to_ascii_lowercase();
                if node.field("bInterfaceClass").and_then(number) == Some(6)
                    || interface_string.contains("mtp")
                    || interface_string.contains("ptp")
                {
                    found_interface = true;
                    mtp_depth = Some(node.depth);
                }
            }
            if mtp_depth.is_some()
                && let Some(state) = node
                    .field("IOUserClientCreator")
                    .and_then(owner)
                    .or_else(|| node.field("UsbExclusiveOwner").and_then(owner))
            {
                return state;
            }
        }
        device
            .field("UsbExclusiveOwner")
            .and_then(owner)
            .unwrap_or(if found_interface {
                AccessState::Free
            } else {
                AccessState::Unknown
            })
    }

    pub fn state(info: &MtpDeviceInfo) -> AccessState {
        let Ok(output) = Command::new("/usr/sbin/ioreg")
            .args([
                "-p",
                "IOService",
                "-l",
                "-w",
                "0",
                "-r",
                "-c",
                "IOUSBHostDevice",
            ])
            .output()
        else {
            return AccessState::Unknown;
        };
        if !output.status.success() {
            return AccessState::Unknown;
        }
        find_owner(
            &String::from_utf8_lossy(&output.stdout),
            info.vendor_id,
            info.product_id,
            info.serial_number.as_deref(),
            info.location_id,
        )
    }

    fn checked(command: &str, output: Output) -> Result<Output> {
        if output.status.success() {
            Ok(output)
        } else {
            Err(RemtpError::Io {
                message: format!(
                    "{command}: {} ({})",
                    String::from_utf8_lossy(&output.stderr).trim(),
                    output.status
                ),
            })
        }
    }

    fn gui_domain() -> Result<String> {
        let output = checked("id", Command::new("/usr/bin/id").arg("-u").output()?)?;
        let uid = String::from_utf8_lossy(&output.stdout)
            .trim()
            .parse::<u32>()
            .map_err(|e| RemtpError::Io {
                message: e.to_string(),
            })?;
        Ok(format!("gui/{uid}"))
    }

    fn state_path() -> Result<PathBuf> {
        let home = std::env::var_os("HOME")
            .filter(|value| !value.is_empty())
            .ok_or_else(|| RemtpError::Io {
                message: "HOME is unset".into(),
            })?;
        Ok(PathBuf::from(home).join("Library/Application Support/ReMTP/ptpcamerad-disabled"))
    }

    fn lock(path: &std::path::Path) -> Result<File> {
        let guard = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(path.with_extension("lock"))?;
        guard.lock()?;
        Ok(guard)
    }

    struct RecoveryOwner {
        pid: u32,
        started: String,
    }

    fn process_started(pid: u32) -> Option<String> {
        let output = Command::new("/bin/ps")
            .env("LC_ALL", "C")
            .args(["-p", &pid.to_string(), "-o", "lstart="])
            .output()
            .ok()?;
        output
            .status
            .success()
            .then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned())
            .filter(|s| !s.is_empty())
    }

    impl RecoveryOwner {
        fn active(&self) -> bool {
            process_started(self.pid).as_deref() == Some(&self.started)
        }
    }

    fn read_owner(path: &std::path::Path) -> Result<Option<RecoveryOwner>> {
        let state = match fs::read_to_string(path) {
            Ok(state) => state,
            Err(e) if e.kind() == ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e.into()),
        };
        let (pid, started) = state.split_once('\n').unwrap_or((&state, ""));
        let pid = pid.parse().map_err(|e| RemtpError::Io {
            message: format!("invalid ptpcamerad recovery state: {e}"),
        })?;
        Ok(Some(RecoveryOwner {
            pid,
            started: started.trim().to_owned(),
        }))
    }

    fn service_disabled(domain: &str) -> Result<bool> {
        let status = checked(
            "launchctl print-disabled",
            Command::new("/bin/launchctl")
                .args(["print-disabled", domain])
                .output()?,
        )?;
        Ok(String::from_utf8_lossy(&status.stdout).lines().any(|line| {
            line.split_once("=>").is_some_and(|(key, value)| {
                key.trim().trim_matches('"') == SERVICE
                    && matches!(
                        value.trim().trim_end_matches(',').trim(),
                        "disabled" | "true"
                    )
            })
        }))
    }

    pub struct Suppression {
        path: PathBuf,
        _lock: File,
    }

    impl Suppression {
        pub fn restore(self) -> Result<()> {
            restore_locked(&self.path, false)
        }
    }

    pub fn suppress() -> Result<Suppression> {
        let path = state_path()?;
        fs::create_dir_all(path.parent().unwrap())?;
        let _lock = lock(&path)?;
        suppress_locked(&path).map_err(|error| {
            error.with_cleanup("could not restore ptpcamerad", restore_locked(&path, false))
        })?;
        Ok(Suppression { path, _lock })
    }

    fn suppress_locked(path: &std::path::Path) -> Result<()> {
        let previous = read_owner(path)?;
        if previous
            .as_ref()
            .is_some_and(|owner| owner.pid != process::id() && owner.active())
        {
            return Err(RemtpError::DeviceBusy {
                holder: "another ReMTP instance".into(),
            });
        }
        let domain = gui_domain()?;
        let disabled = service_disabled(&domain)?;
        if !disabled || previous.is_some() {
            let pid = process::id();
            let started = process_started(pid).ok_or_else(|| RemtpError::Io {
                message: "could not identify the ReMTP process".into(),
            })?;
            let pending = path.with_extension("pending");
            let mut file = File::create(&pending)?;
            writeln!(file, "{pid}\n{started}")?;
            file.sync_all()?;
            fs::rename(pending, path)?;
        }
        if !disabled {
            checked(
                "launchctl disable",
                Command::new("/bin/launchctl")
                    .args(["disable", &format!("{domain}/{SERVICE}")])
                    .output()?,
            )?;
        }
        let output = Command::new("/usr/bin/pkill")
            .args(["-9", "-x", "ptpcamerad"])
            .output()?;
        if output.status.code() != Some(1) {
            checked("pkill", output)?;
        }
        Ok(())
    }

    pub fn restore(stale_only: bool) -> Result<()> {
        let path = state_path()?;
        if !path.parent().unwrap().try_exists()? {
            return Ok(());
        }
        let _lock = lock(&path)?;
        restore_locked(&path, stale_only)
    }

    fn restore_locked(path: &std::path::Path, stale_only: bool) -> Result<()> {
        if let Some(owner) = read_owner(path)? {
            if (stale_only || owner.pid != process::id()) && owner.active() {
                return Ok(());
            }
            let domain = gui_domain()?;
            if service_disabled(&domain)? {
                checked(
                    "launchctl enable",
                    Command::new("/bin/launchctl")
                        .args(["enable", &format!("{domain}/{SERVICE}")])
                        .output()?,
                )?;
            }
            fs::remove_file(path)?;
        }
        Ok(())
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn holder_lookup_prefers_location_when_serials_match() {
            let registry = r#"+-o First  <class IOUSBHostDevice, id 1>
  | "idVendor" = 16642
  | "idProduct" = 4658
  | "USB Serial Number" = "1234567"
  | "locationID" = 0x14100000
  | "UsbExclusiveOwner" = "FirstOwner"
+-o Second  <class IOUSBHostDevice, id 2>
  | "idVendor" = 16642
  | "idProduct" = 4658
  | "USB Serial Number" = "1234567"
  | "locationID" = 0x14200000
  | "UsbExclusiveOwner" = "SecondOwner""#;
            assert_eq!(
                find_owner(
                    registry,
                    16642,
                    4658,
                    Some("1234567"),
                    location_hash(0x14200000)
                ),
                AccessState::HeldBy {
                    process: "SecondOwner".into(),
                    pid: None
                }
            );
            assert_eq!(
                find_owner(registry, 16642, 4658, Some("1234567"), 0),
                AccessState::Unknown
            );
        }

        #[test]
        fn finds_holder_on_matching_mtp_interface_only() {
            let registry = r#"+-o Phone@14100000  <class IOUSBHostDevice, id 1>
  | "idVendor" = 6353
  | "idProduct" = 4
  | "locationID" = 0x14100000
  +-o ADB@1  <class IOUSBHostInterface, id 2>
  | | "bInterfaceClass" = 255
  | +-o Client  <class IOUSBHostInterfaceUserClient, id 3>
  |     "IOUserClientCreator" = "pid 124, adb"
  +-o MTP@0  <class IOUSBHostInterface, id 4>
    | "bInterfaceClass" = 6
    +-o Client  <class IOUSBHostInterfaceUserClient, id 5>
        "IOUserClientCreator" = "pid 42, ptpcamerad""#;
            assert_eq!(
                find_owner(registry, 6353, 4, None, location_hash(0x14100000)),
                AccessState::HeldBy {
                    process: "ptpcamerad".into(),
                    pid: Some(42)
                }
            );
            assert_eq!(find_owner(registry, 6353, 4, None, 0), AccessState::Unknown);
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod platform {
    use super::AccessState;
    use crate::Result;

    pub fn state(_: &mtp_rs::mtp::MtpDeviceInfo) -> AccessState {
        AccessState::Unknown
    }
    pub fn restore(_: bool) -> Result<()> {
        Ok(())
    }
}

#[cfg(target_os = "macos")]
pub(crate) use platform::suppress;
pub(crate) use platform::{restore, state};
