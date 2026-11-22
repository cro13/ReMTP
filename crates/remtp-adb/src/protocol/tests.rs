use std::collections::VecDeque;

use super::*;

const IO_TIMEOUT: Duration = Duration::from_secs(5);
const APPROVAL: Duration = Duration::from_secs(2);
const PACKET: usize = 64;
const TOKEN: &[u8] = &[0x5a; 20];
const SIGNATURE: &[u8] = &[0x83; 256];
const PUBLIC_KEY: &str = "test-key ReMTP";
const REMOTE_ID: u32 = 21;

enum Step {
    Read(Result<Vec<u8>>),
    Write(Vec<u8>, Result<()>),
}

#[derive(Default)]
struct Script(VecDeque<Step>);

impl Script {
    fn new() -> Self {
        let mut script = Self::default();
        script.expect_message(CNXN, VERSION, 256 * 1024, b"host::\0", true);
        script
    }

    fn bytes(&mut self, bytes: Vec<u8>) {
        self.0.push_back(Step::Read(Ok(bytes)));
    }

    fn error(&mut self, error: Error) {
        self.0.push_back(Step::Read(Err(error)));
    }

    fn expect_message(&mut self, command: u32, arg0: u32, arg1: u32, data: &[u8], legacy: bool) {
        let packet = frame(command, arg0, arg1, data, legacy);
        self.0.push_back(Step::Write(packet[..24].to_vec(), Ok(())));
        if !data.is_empty() {
            self.0.push_back(Step::Write(packet[24..].to_vec(), Ok(())));
            if data.len().is_multiple_of(PACKET) {
                self.0.push_back(Step::Write(Vec::new(), Ok(())));
            }
        }
    }

    fn authenticated(&mut self) {
        self.bytes(frame(CNXN, VERSION, 256 * 1024, b"device::\0", false));
    }

    fn challenge(&mut self) {
        self.bytes(frame(AUTH, AUTH_TOKEN, 0, TOKEN, false));
    }

    fn expect_signature(&mut self) {
        self.challenge();
        self.expect_message(AUTH, AUTH_SIGNATURE, 0, SIGNATURE, true);
    }

    fn expect_public_key(&mut self) {
        self.expect_signature();
        self.challenge();
        self.expect_message(AUTH, AUTH_PUBLIC_KEY, 0, b"test-key ReMTP\0", true);
    }

    fn expect_open(&mut self) {
        self.expect_message(OPEN, LOCAL_ID, 0, b"shell:command\0", false);
    }

    fn finish(self) {
        assert!(self.0.is_empty(), "{} unused script steps", self.0.len());
    }
}

impl BytePipe for Script {
    fn out_packet_size(&self) -> usize {
        PACKET
    }

    fn read(&mut self, wanted: usize, timeout: Duration) -> Result<Vec<u8>> {
        assert!(!timeout.is_zero() && timeout <= IO_TIMEOUT);
        let Some(Step::Read(result)) = self.0.pop_front() else {
            panic!("unexpected read of {wanted} bytes");
        };
        if let Ok(ref bytes) = result {
            assert!(bytes.len() <= wanted.next_multiple_of(PACKET));
        }
        result
    }

    fn write(&mut self, bytes: &[u8], timeout: Duration) -> Result<()> {
        assert!(!timeout.is_zero() && timeout <= IO_TIMEOUT);
        let Some(Step::Write(expected, result)) = self.0.pop_front() else {
            panic!("unexpected write: {bytes:?}");
        };
        assert_eq!(bytes, expected);
        result
    }
}

fn frame(command: u32, arg0: u32, arg1: u32, data: &[u8], legacy: bool) -> Vec<u8> {
    let sum = if legacy {
        data.iter().map(|&byte| u32::from(byte)).sum()
    } else {
        0
    };
    [
        command,
        arg0,
        arg1,
        data.len() as u32,
        sum,
        command ^ u32::MAX,
    ]
    .into_iter()
    .flat_map(u32::to_le_bytes)
    .chain(data.iter().copied())
    .collect()
}

struct TestKeys(bool);

impl KeyStore for TestKeys {
    fn adb_public_key(&self) -> Result<String> {
        assert!(self.0, "a probe cannot ask for the public key");
        Ok(PUBLIC_KEY.into())
    }

    fn sign(&self, token: &[u8]) -> Result<Vec<u8>> {
        assert_eq!(token, TOKEN);
        Ok(SIGNATURE.to_vec())
    }
}

#[test]
fn connects_without_auth_and_ignores_stale_usb_data() {
    let mut script = Script::new();
    script.bytes(b"stale fragment".to_vec());
    script.bytes(frame(WRTE, REMOTE_ID, LOCAL_ID, b"stale message", false));
    script.bytes(Vec::new());
    script.authenticated();
    let mut conn = Connection::new(script, IO_TIMEOUT);
    assert_eq!(
        conn.connect(&TestKeys(false), Duration::ZERO).unwrap(),
        Authorization::Ready
    );
    conn.pipe.finish();
}

#[test]
fn probe_accepts_a_signature() {
    let mut script = Script::new();
    script.expect_signature();
    script.authenticated();
    let mut conn = Connection::new(script, IO_TIMEOUT);
    assert_eq!(
        conn.connect(&TestKeys(false), Duration::ZERO).unwrap(),
        Authorization::Ready
    );
    conn.pipe.finish();
}

#[test]
fn probe_reports_rejected_signature_without_prompting() {
    let mut script = Script::new();
    script.expect_signature();
    script.challenge();
    let mut conn = Connection::new(script, IO_TIMEOUT);
    assert_eq!(
        conn.connect(&TestKeys(false), Duration::ZERO).unwrap(),
        Authorization::NeedsApproval
    );
    conn.pipe.finish();
}

#[test]
fn shell_can_ask_for_approval() {
    let mut script = Script::new();
    script.expect_public_key();
    script.challenge();
    script.authenticated();
    let mut conn = Connection::new(script, IO_TIMEOUT);
    assert_eq!(
        conn.connect(&TestKeys(true), APPROVAL).unwrap(),
        Authorization::Ready
    );
    conn.pipe.finish();
}

#[test]
fn approval_budget_is_separate_from_io_timeout() {
    let mut script = Script::new();
    script.expect_public_key();
    let packet = frame(CNXN, VERSION, MAX_PAYLOAD as u32, b"device::\0", false);
    script.bytes(packet[..12].to_vec());
    script.error(Error::Timeout);
    script.bytes(packet[12..].to_vec());
    let mut conn = Connection::new(script, APPROVAL);
    assert_eq!(
        conn.connect(&TestKeys(true), IO_TIMEOUT).unwrap(),
        Authorization::Ready
    );
    conn.pipe.finish();
}

#[test]
fn approval_timeout_is_not_a_transport_error() {
    let mut script = Script::new();
    script.expect_public_key();
    script.error(Error::Timeout);
    let mut conn = Connection::new(script, IO_TIMEOUT);
    assert_eq!(
        conn.connect(&TestKeys(true), APPROVAL).unwrap(),
        Authorization::NeedsApproval
    );
    conn.pipe.finish();
}

#[test]
fn shell_reads_multiple_writes_and_handles_packet_boundaries() {
    let mut script = Script::new();
    script.authenticated();
    script.expect_open();
    script.bytes(frame(OKAY, REMOTE_ID, LOCAL_ID, b"", false));
    let full_packet = [b'x'; PACKET];
    let write = frame(WRTE, REMOTE_ID, LOCAL_ID, &full_packet, false);
    script.bytes(write[..24].to_vec());
    script.bytes(write[24..].to_vec());
    script.expect_message(OKAY, LOCAL_ID, REMOTE_ID, b"", false);
    script.bytes(Vec::new());
    script.bytes(frame(WRTE, REMOTE_ID, LOCAL_ID, b" done", false));
    script.expect_message(OKAY, LOCAL_ID, REMOTE_ID, b"", false);
    script.bytes(frame(CLSE, REMOTE_ID, LOCAL_ID, b"", false));
    script.expect_message(CLSE, LOCAL_ID, REMOTE_ID, b"", false);
    let mut conn = Connection::new(script, IO_TIMEOUT);
    conn.connect(&TestKeys(false), APPROVAL).unwrap();
    assert_eq!(
        conn.shell("command").unwrap(),
        format!("{} done", "x".repeat(PACKET))
    );
    conn.pipe.finish();
}

#[test]
fn disconnect_before_okay_fails_but_after_okay_keeps_output_even_during_ack() {
    for accepted in [false, true] {
        let mut script = Script::new();
        script.authenticated();
        script.expect_open();
        if accepted {
            script.bytes(frame(OKAY, REMOTE_ID, LOCAL_ID, b"", false));
            script.bytes(frame(WRTE, REMOTE_ID, LOCAL_ID, b"switching", false));
            script.0.push_back(Step::Write(
                frame(OKAY, LOCAL_ID, REMOTE_ID, b"", false),
                Err(Error::Disconnected),
            ));
        } else {
            script.error(Error::Disconnected);
        }
        let mut conn = Connection::new(script, IO_TIMEOUT);
        conn.connect(&TestKeys(false), APPROVAL).unwrap();
        let output = conn.shell("command");
        if accepted {
            assert_eq!(output.unwrap(), "switching");
        } else {
            assert!(matches!(output, Err(Error::Disconnected)));
        }
        conn.pipe.finish();
    }
}

#[test]
fn legacy_connection_honors_peer_limit_and_checksums() {
    let mut script = Script::new();
    script.bytes(frame(CNXN, VERSION_LEGACY, 14, b"device::\0", true));
    script.expect_message(OPEN, LOCAL_ID, 0, b"shell:command\0", true);
    script.bytes(frame(OKAY, REMOTE_ID, LOCAL_ID, b"", true));
    script.bytes(frame(WRTE, REMOTE_ID, LOCAL_ID, b"bad checksum", false));
    let mut conn = Connection::new(script, IO_TIMEOUT);
    conn.connect(&TestKeys(false), APPROVAL).unwrap();
    assert!(
        matches!(conn.shell("too long"), Err(Error::Protocol(message)) if message.contains("peer's limit"))
    );
    assert!(
        matches!(conn.shell("command"), Err(Error::Protocol(message)) if message.contains("checksum"))
    );
    conn.pipe.finish();
}
