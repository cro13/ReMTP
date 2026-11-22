use std::io::{self, Read, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpStream};
use std::time::Duration;

use super::AdbAccess;

const CONNECT_TIMEOUT: Duration = Duration::from_millis(200);
const STATUS_TIMEOUT: Duration = Duration::from_millis(750);
const SHELL_TIMEOUT: Duration = Duration::from_secs(5);

pub(super) type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, thiserror::Error)]
pub(super) enum Error {
    #[error(transparent)]
    Io(#[from] io::Error),
    #[error("Invalid reply from the ADB server")]
    InvalidReply,
    #[error("ADB request is too long")]
    RequestTooLong,
    #[error("{0}")]
    Rejected(String),
}

pub(super) struct Server {
    address: SocketAddr,
}

impl Server {
    pub(super) fn local() -> Self {
        let port = std::env::var("ANDROID_ADB_SERVER_PORT")
            .ok()
            .and_then(|port| port.parse().ok())
            .filter(|port| *port != 0)
            .unwrap_or(5037);
        Self {
            address: (Ipv4Addr::LOCALHOST, port).into(),
        }
    }

    pub(super) fn connect(&self) -> io::Result<TcpStream> {
        let stream = TcpStream::connect_timeout(&self.address, CONNECT_TIMEOUT)?;
        stream.set_read_timeout(Some(STATUS_TIMEOUT))?;
        stream.set_write_timeout(Some(STATUS_TIMEOUT))?;
        Ok(stream)
    }

    pub(super) fn devices(&self) -> Result<Vec<ServerDevice>> {
        devices(self.connect()?)
    }

    pub(super) fn shell(&self, serial: &str, command: &str) -> Result<String> {
        let mut stream = self.connect()?;
        request(&mut stream, &format!("host:transport:{serial}"))?;
        stream.set_read_timeout(Some(SHELL_TIMEOUT))?;
        request(&mut stream, &format!("shell:{command}"))?;
        let mut output = Vec::new();
        match stream.take(u64::from(u16::MAX)).read_to_end(&mut output) {
            Ok(_) => {}
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::ConnectionReset | io::ErrorKind::ConnectionAborted
                ) => {}
            Err(error) => return Err(error.into()),
        }
        Ok(String::from_utf8_lossy(&output).into_owned())
    }
}

pub(super) fn devices(mut stream: TcpStream) -> Result<Vec<ServerDevice>> {
    request(&mut stream, "host:devices-l")?;
    Ok(parse_devices(&read_frame(&mut stream)?))
}

fn request(stream: &mut TcpStream, service: &str) -> Result<()> {
    let length = u16::try_from(service.len()).map_err(|_| Error::RequestTooLong)?;
    stream.write_all(format!("{length:04x}{service}").as_bytes())?;
    let mut status = [0u8; 4];
    stream.read_exact(&mut status)?;
    match &status {
        b"OKAY" => Ok(()),
        b"FAIL" => Err(Error::Rejected(read_frame(stream)?)),
        _ => Err(Error::InvalidReply),
    }
}

fn read_frame(stream: &mut TcpStream) -> Result<String> {
    let mut length = [0u8; 4];
    stream.read_exact(&mut length)?;
    let length = str::from_utf8(&length)
        .ok()
        .filter(|length| length.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .and_then(|length| u16::from_str_radix(length, 16).ok())
        .ok_or(Error::InvalidReply)?;
    let mut payload = vec![0u8; usize::from(length)];
    stream.read_exact(&mut payload)?;
    Ok(String::from_utf8_lossy(&payload).into_owned())
}

#[derive(Debug)]
pub(super) struct ServerDevice {
    serial: String,
    access: AdbAccess,
}

pub(super) fn access(devices: &[ServerDevice], serial: &str) -> AdbAccess {
    let mut matches = devices.iter().filter(|device| device.serial == serial);
    match (matches.next(), matches.next()) {
        (Some(device), None) => device.access.clone(),
        (Some(_), Some(_)) => AdbAccess::unavailable("USB serial is not unique"),
        _ => AdbAccess::unavailable("ADB server hasn't detected this device"),
    }
}

fn parse_devices(payload: &str) -> Vec<ServerDevice> {
    payload
        .lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            let serial = fields.next()?.to_owned();
            let access = match fields.next()? {
                "device" => AdbAccess::Ready,
                "unauthorized" | "authorizing" => AdbAccess::NeedsApproval,
                "offline" => AdbAccess::unavailable("Device is offline in ADB"),
                "no" if fields.next() == Some("permissions") => {
                    AdbAccess::unavailable("ADB server doesn't have USB permission")
                }
                _ => AdbAccess::unavailable("Device isn't ready in ADB"),
            };
            Some(ServerDevice { serial, access })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use std::net::TcpListener;
    use std::thread::{self, JoinHandle};

    use super::*;

    fn fake_server(handler: impl FnOnce(TcpStream) + Send + 'static) -> (Server, JoinHandle<()>) {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        (
            Server {
                address: listener.local_addr().unwrap(),
            },
            thread::spawn(move || {
                let (stream, _) = listener.accept().unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(2)))
                    .unwrap();
                handler(stream);
            }),
        )
    }

    fn expect(stream: &mut TcpStream, expected: &[u8]) {
        let mut received = vec![0; expected.len()];
        stream.read_exact(&mut received).unwrap();
        assert_eq!(received, expected);
    }

    #[test]
    fn gets_long_listing_and_maps_device_states() {
        let listing = concat!(
            "FAKE-001\tdevice usb:1-3 product:tablet model:Fake_Tablet transport_id:1\n",
            "FAKE-002  unauthorized usb:1-4\n",
            "FAKE-003  offline usb:1-5\n",
            "FAKE-004  no permissions (missing udev rules); see help\n",
            "FAKE-005  recovery usb:1-6\n",
            "FAKE-006  device usb:1-7\nFAKE-006  device usb:1-8\n",
            "malformed\n",
        );
        let (server, thread) = fake_server(move |mut stream| {
            expect(&mut stream, b"000ehost:devices-l");
            stream.write_all(b"OK").unwrap();
            stream
                .write_all(format!("AY{:04X}{listing}", listing.len()).as_bytes())
                .unwrap();
        });
        let devices = server.devices().unwrap();
        thread.join().unwrap();
        assert_eq!(devices.len(), 7);
        assert_eq!(access(&devices, "FAKE-001"), AdbAccess::Ready);
        assert_eq!(access(&devices, "FAKE-002"), AdbAccess::NeedsApproval);
        assert_eq!(
            access(&devices, "FAKE-003"),
            AdbAccess::unavailable("Device is offline in ADB")
        );
        assert_eq!(
            access(&devices, "FAKE-004"),
            AdbAccess::unavailable("ADB server doesn't have USB permission")
        );
        assert_eq!(
            access(&devices, "FAKE-005"),
            AdbAccess::unavailable("Device isn't ready in ADB")
        );
        assert_eq!(
            access(&devices, "FAKE-006"),
            AdbAccess::unavailable("USB serial is not unique")
        );
        assert_eq!(
            access(&devices, "unknown"),
            AdbAccess::unavailable("ADB server hasn't detected this device")
        );
    }

    #[test]
    fn shell_selects_transport_then_reads_unframed_output_until_eof() {
        let (server, thread) = fake_server(|mut stream| {
            expect(&mut stream, b"0017host:transport:FAKE-001");
            stream.write_all(b"OKAY").unwrap();
            expect(&mut stream, b"001ashell:svc usb getFunctions");
            stream.write_all(b"OKAYmtp\n").unwrap();
        });
        assert_eq!(
            server.shell("FAKE-001", "svc usb getFunctions").unwrap(),
            "mtp\n"
        );
        thread.join().unwrap();
    }

    #[test]
    fn fail_contains_a_framed_reason() {
        let (server, thread) = fake_server(|mut stream| {
            expect(&mut stream, b"0017host:transport:FAKE-001");
            stream.write_all(b"FAIL0013device unauthorized").unwrap();
        });
        let error = server
            .shell("FAKE-001", "svc usb getFunctions")
            .unwrap_err();
        assert!(matches!(error, Error::Rejected(reason) if reason == "device unauthorized"));
        thread.join().unwrap();
    }

    #[test]
    fn invalid_length_is_not_a_device_list() {
        let (server, thread) = fake_server(|mut stream| {
            expect(&mut stream, b"000ehost:devices-l");
            stream.write_all(b"OKAY+003bad").unwrap();
        });
        assert!(matches!(server.devices(), Err(Error::InvalidReply)));
        thread.join().unwrap();
    }
}
