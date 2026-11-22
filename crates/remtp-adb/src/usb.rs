use std::time::Duration;

use nusb::descriptors::TransferType;
use nusb::transfer::{Buffer, Bulk, Direction, In, Out, TransferError};
use nusb::{Endpoint, ErrorKind, MaybeFuture};

use crate::protocol::BytePipe;
use crate::{Error, Result, is_adb_class};

pub(crate) struct UsbPipe {
    input: Endpoint<Bulk, In>,
    output: Endpoint<Bulk, Out>,
}

impl UsbPipe {
    pub(crate) fn open(info: &nusb::DeviceInfo) -> Result<Self> {
        let device = info.open().wait().map_err(usb_error)?;
        let config = device
            .active_configuration()
            .map_err(|error| Error::Protocol(error.to_string()))?;
        let adb = config
            .interface_alt_settings()
            .find(|intf| is_adb_class(intf.class(), intf.subclass(), intf.protocol()))
            .ok_or(Error::NoAdbInterface)?;
        let address = |direction| {
            adb.endpoints()
                .find(|ep| {
                    ep.transfer_type() == TransferType::Bulk
                        && ep.direction() == direction
                        && ep.max_packet_size() != 0
                })
                .map(|ep| ep.address())
                .ok_or_else(|| Error::Protocol(format!("missing ADB bulk {direction:?} endpoint")))
        };
        let (input, output) = (address(Direction::In)?, address(Direction::Out)?);
        let interface = device
            .claim_interface(adb.interface_number())
            .wait()
            .map_err(usb_error)?;
        if adb.alternate_setting() != 0 {
            interface
                .set_alt_setting(adb.alternate_setting())
                .wait()
                .map_err(usb_error)?;
        }
        Ok(Self {
            input: interface.endpoint(input).map_err(usb_error)?,
            output: interface.endpoint(output).map_err(usb_error)?,
        })
    }
}

impl BytePipe for UsbPipe {
    fn out_packet_size(&self) -> usize {
        self.output.max_packet_size()
    }

    fn read(&mut self, wanted: usize, timeout: Duration) -> Result<Vec<u8>> {
        if self.input.pending() == 0 {
            let packet = self.input.max_packet_size();
            self.input
                .submit(Buffer::new(wanted.next_multiple_of(packet)));
        }
        // During approval, another wait can resume this read without losing partial packets.
        self.input
            .wait_next_complete(timeout)
            .ok_or(Error::Timeout)?
            .into_result()
            .map(Buffer::into_vec)
            .map_err(transfer_error)
    }

    fn write(&mut self, bytes: &[u8], timeout: Duration) -> Result<()> {
        let mut buffer = Buffer::new(bytes.len());
        buffer.extend_from_slice(bytes);
        self.output.submit(buffer);
        let completion = self
            .output
            .wait_next_complete(timeout)
            .ok_or(Error::Timeout)?;
        completion.status.map_err(transfer_error)?;
        if completion.actual_len != bytes.len() {
            return Err(Error::Protocol("short USB write".into()));
        }
        Ok(())
    }
}

fn usb_error(error: nusb::Error) -> Error {
    classify_usb_error(error.kind(), || error.to_string())
}

fn classify_usb_error(kind: ErrorKind, description: impl FnOnce() -> String) -> Error {
    match kind {
        ErrorKind::Busy => Error::Busy,
        ErrorKind::Disconnected => Error::Disconnected,
        _ => Error::Protocol(description()),
    }
}

fn transfer_error(error: TransferError) -> Error {
    match error {
        TransferError::Disconnected => Error::Disconnected,
        TransferError::Cancelled => Error::Timeout,
        _ => Error::Protocol(error.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exclusive_usb_claim_maps_to_busy() {
        let error = classify_usb_error(ErrorKind::Busy, || "interface is already claimed".into());
        assert!(matches!(error, Error::Busy));
    }
}
