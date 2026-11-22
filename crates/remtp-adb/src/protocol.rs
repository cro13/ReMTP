use std::io::{Cursor, Read};
use std::time::{Duration, Instant};

use crate::{Authorization, Error, KeyStore, Result};

const HEADER_LEN: usize = 24;
const MAX_PAYLOAD: usize = 256 * 1024;
const VERSION_LEGACY: u32 = 0x0100_0000;
const VERSION: u32 = 0x0100_0001;
const CNXN: u32 = u32::from_le_bytes(*b"CNXN");
const AUTH: u32 = u32::from_le_bytes(*b"AUTH");
const OPEN: u32 = u32::from_le_bytes(*b"OPEN");
const OKAY: u32 = u32::from_le_bytes(*b"OKAY");
const WRTE: u32 = u32::from_le_bytes(*b"WRTE");
const CLSE: u32 = u32::from_le_bytes(*b"CLSE");
const AUTH_TOKEN: u32 = 1;
const AUTH_SIGNATURE: u32 = 2;
const AUTH_PUBLIC_KEY: u32 = 3;
const LOCAL_ID: u32 = 1;

pub(crate) trait BytePipe {
    fn out_packet_size(&self) -> usize;
    fn read(&mut self, wanted: usize, timeout: Duration) -> Result<Vec<u8>>;
    fn write(&mut self, bytes: &[u8], timeout: Duration) -> Result<()>;
}

pub(crate) struct Connection<P> {
    pipe: P,
    pending: Cursor<Vec<u8>>,
    version: u32,
    max_payload: usize,
    timeout: Duration,
}

impl<P: BytePipe> Connection<P> {
    pub(crate) fn new(pipe: P, timeout: Duration) -> Self {
        Self {
            pipe,
            pending: Cursor::default(),
            version: VERSION_LEGACY,
            max_payload: MAX_PAYLOAD,
            timeout,
        }
    }

    pub(crate) fn connect(
        &mut self,
        keys: &dyn KeyStore,
        approval: Duration,
    ) -> Result<Authorization> {
        let deadline = Deadline::new(self.timeout);
        self.send(CNXN, VERSION, MAX_PAYLOAD as u32, b"host::\0", &deadline)?;
        let reply = self.connection_reply(&deadline, false)?;
        if reply.header.command == CNXN {
            return self.accept(reply.header);
        }

        let signature = keys.sign(&reply.payload)?;
        self.send(AUTH, AUTH_SIGNATURE, 0, &signature, &deadline)?;
        let reply = self.connection_reply(&deadline, false)?;
        if reply.header.command == CNXN {
            return self.accept(reply.header);
        }
        if approval.is_zero() {
            return Ok(Authorization::NeedsApproval);
        }

        let mut public_key = keys.adb_public_key()?.into_bytes();
        public_key.push(0);
        self.send(AUTH, AUTH_PUBLIC_KEY, 0, &public_key, &deadline)?;
        let deadline = Deadline::new(approval);
        loop {
            match self.connection_reply(&deadline, true) {
                Ok(reply) if reply.header.command == CNXN => return self.accept(reply.header),
                Ok(_) => continue,
                Err(Error::Timeout) => return Ok(Authorization::NeedsApproval),
                Err(error) => return Err(error),
            }
        }
    }

    fn connection_reply(&mut self, deadline: &Deadline, waiting_for_user: bool) -> Result<Message> {
        loop {
            let reply = self.receive(deadline, true, waiting_for_user)?;
            match reply.header.command {
                CNXN => return Ok(reply),
                AUTH if reply.header.arg0 == AUTH_TOKEN => {
                    if reply.payload.len() != 20 {
                        return Err(Error::Protocol("invalid AUTH token length".into()));
                    }
                    return Ok(reply);
                }
                _ => continue,
            }
        }
    }

    fn accept(&mut self, header: Header) -> Result<Authorization> {
        if header.arg0 < VERSION_LEGACY || header.arg1 == 0 {
            return Err(Error::Protocol(
                "invalid CNXN version or payload limit".into(),
            ));
        }
        self.version = header.arg0.min(VERSION);
        self.max_payload = (header.arg1 as usize).min(MAX_PAYLOAD);
        Ok(Authorization::Ready)
    }

    pub(crate) fn shell(&mut self, command: &str) -> Result<String> {
        let deadline = Deadline::new(self.timeout);
        if command.contains('\0') {
            return Err(Error::Protocol("ADB shell command contains a NUL".into()));
        }
        let service = format!("shell:{command}\0");
        self.send(OPEN, LOCAL_ID, 0, service.as_bytes(), &deadline)?;

        let remote_id = loop {
            let header = self.receive(&deadline, false, false)?.header;
            if header.arg1 == LOCAL_ID {
                match header.command {
                    OKAY if header.arg0 != 0 => break header.arg0,
                    CLSE => return Err(Error::Protocol("device refused the shell stream".into())),
                    _ => continue,
                }
            }
        };

        let mut output = Vec::new();
        match self.read_shell(remote_id, &deadline, &mut output) {
            // A USB mode change can remove the device before adbd can send CLSE.
            Ok(()) | Err(Error::Disconnected) => Ok(String::from_utf8_lossy(&output).into_owned()),
            Err(error) => Err(error),
        }
    }

    fn read_shell(
        &mut self,
        remote_id: u32,
        deadline: &Deadline,
        output: &mut Vec<u8>,
    ) -> Result<()> {
        loop {
            let message = self.receive(deadline, false, false)?;
            if message.header.arg0 != remote_id || message.header.arg1 != LOCAL_ID {
                continue;
            }
            match message.header.command {
                WRTE => {
                    output.extend_from_slice(&message.payload);
                    self.send(OKAY, LOCAL_ID, remote_id, &[], deadline)?;
                }
                CLSE => return self.send(CLSE, LOCAL_ID, remote_id, &[], deadline),
                _ => continue,
            }
        }
    }

    fn send(
        &mut self,
        command: u32,
        arg0: u32,
        arg1: u32,
        payload: &[u8],
        deadline: &Deadline,
    ) -> Result<()> {
        if payload.len() > self.max_payload {
            return Err(Error::Protocol(
                "payload exceeds the ADB peer's limit".into(),
            ));
        }
        let header = Header {
            command,
            arg0,
            arg1,
            len: payload.len(),
            checksum: if self.version < VERSION {
                checksum(payload)
            } else {
                0
            },
        };
        self.pipe.write(&header.encode(), deadline.remaining()?)?;
        if !payload.is_empty() {
            self.pipe.write(payload, deadline.remaining()?)?;
            if payload.len().is_multiple_of(self.pipe.out_packet_size()) {
                self.pipe.write(&[], deadline.remaining()?)?;
            }
        }
        Ok(())
    }

    fn receive(
        &mut self,
        deadline: &Deadline,
        resync: bool,
        waiting_for_user: bool,
    ) -> Result<Message> {
        let mut bytes = [0; HEADER_LEN];
        self.fill(&mut bytes, deadline, waiting_for_user)?;
        let header = loop {
            deadline.remaining()?;
            if let Some(header) = Header::decode(&bytes) {
                break header;
            }
            if !resync {
                return Err(Error::Protocol("invalid ADB message header".into()));
            }
            // A previous host can have left part of a frame in the bulk IN queue.
            bytes.rotate_left(1);
            self.fill(&mut bytes[HEADER_LEN - 1..], deadline, waiting_for_user)?;
        };
        let mut payload = vec![0; header.len];
        self.fill(&mut payload, deadline, waiting_for_user)?;

        // Before CNXN, the peer may already be omitting checksums on AUTH frames.
        let legacy = if header.command == CNXN {
            header.arg0 < VERSION
        } else {
            !resync && self.version < VERSION
        };
        if legacy && header.checksum != checksum(&payload) {
            return Err(Error::Protocol("invalid ADB payload checksum".into()));
        }
        Ok(Message { header, payload })
    }

    fn fill(
        &mut self,
        mut bytes: &mut [u8],
        deadline: &Deadline,
        waiting_for_user: bool,
    ) -> Result<()> {
        while !bytes.is_empty() {
            // USB bulk reads round up to a packet; preserve any bytes past the requested length.
            let count = self
                .pending
                .read(bytes)
                .expect("reading an in-memory buffer");
            bytes = &mut bytes[count..];
            if !bytes.is_empty() {
                let remaining = deadline.remaining()?;
                let wait = remaining.min(self.timeout);
                match self.pipe.read(bytes.len(), wait) {
                    Ok(chunk) => self.pending = Cursor::new(chunk),
                    Err(Error::Timeout) if waiting_for_user && wait < remaining => continue,
                    Err(error) => return Err(error),
                }
            }
        }
        Ok(())
    }
}

struct Deadline {
    start: Instant,
    limit: Duration,
}

impl Deadline {
    fn new(limit: Duration) -> Self {
        Self {
            start: Instant::now(),
            limit,
        }
    }

    fn remaining(&self) -> Result<Duration> {
        let left = self.limit.saturating_sub(self.start.elapsed());
        if left.is_zero() {
            Err(Error::Timeout)
        } else {
            Ok(left)
        }
    }
}

#[derive(Clone, Copy)]
struct Header {
    command: u32,
    arg0: u32,
    arg1: u32,
    len: usize,
    checksum: u32,
}

impl Header {
    fn encode(self) -> [u8; HEADER_LEN] {
        let mut bytes = [0; HEADER_LEN];
        let words = [
            self.command,
            self.arg0,
            self.arg1,
            self.len as u32,
            self.checksum,
            !self.command,
        ];
        for (destination, word) in bytes.chunks_exact_mut(4).zip(words) {
            destination.copy_from_slice(&word.to_le_bytes());
        }
        bytes
    }

    fn decode(bytes: &[u8; HEADER_LEN]) -> Option<Self> {
        let word = |index| u32::from_le_bytes(bytes[index..index + 4].try_into().unwrap());
        let command = word(0);
        let len = word(12) as usize;
        if word(20) != !command || len > MAX_PAYLOAD {
            return None;
        }
        Some(Self {
            command,
            arg0: word(4),
            arg1: word(8),
            len,
            checksum: word(16),
        })
    }
}

struct Message {
    header: Header,
    payload: Vec<u8>,
}

fn checksum(bytes: &[u8]) -> u32 {
    bytes.iter().map(|&byte| u32::from(byte)).sum()
}

#[cfg(test)]
mod tests;
