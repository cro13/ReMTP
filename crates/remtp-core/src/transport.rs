use std::io;
use std::sync::Arc;

use bytes::Bytes;
use futures::future::BoxFuture;
use futures::stream::{BoxStream, Stream};
use mtp_rs::CancelToken;

use crate::{DeviceDetails, Entry, Result, StorageInfo};

mod memory;
mod mtp;
#[cfg(test)]
pub(crate) use memory::MemoryOp;
pub use memory::{MemoryLatency, MemoryTransport};
pub use mtp::MtpTransport;
pub(crate) use mtp::{device_summary, mtp_error};

pub type Handle = u64;
pub type UploadStream = BoxStream<'static, io::Result<Bytes>>;
pub type ProgressFn = Arc<dyn Fn(u64) + Send + Sync>;

pub trait DownloadSink: Send {
    fn write_chunk(&mut self, chunk: Bytes) -> BoxFuture<'_, Result<()>>;
    fn flush(&mut self) -> BoxFuture<'_, Result<()>> {
        Box::pin(async { Ok(()) })
    }
}

#[derive(Clone, Debug)]
pub struct Object {
    pub handle: Handle,
    pub parent: Handle,
    pub storage: u32,
    pub entry: Entry,
}

pub struct Listing {
    pub objects: Vec<Object>,
    pub complete: bool,
}

pub enum Event {
    Added(Handle),
    Removed(Handle),
    Changed(Handle),
    StoragesChanged,
    Reset,
    Disconnected,
}

pub trait Transport: Send + 'static {
    fn details(&mut self) -> BoxFuture<'_, Result<DeviceDetails>>;
    fn storages(&mut self) -> BoxFuture<'_, Result<Vec<StorageInfo>>> {
        Box::pin(async { Ok(self.details().await?.storages) })
    }
    fn list(
        &mut self,
        storage: u32,
        parent: Handle,
        cancel: CancelToken,
    ) -> BoxFuture<'_, Result<Vec<Object>>>;
    fn list_with_completeness(
        &mut self,
        storage: u32,
        parent: Handle,
        cancel: CancelToken,
    ) -> BoxFuture<'_, Result<Listing>> {
        Box::pin(async move {
            Ok(Listing {
                objects: self.list(storage, parent, cancel).await?,
                complete: true,
            })
        })
    }
    fn stat(&mut self, handle: Handle) -> BoxFuture<'_, Result<Object>>;
    fn mkdir(
        &mut self,
        storage: u32,
        parent: Handle,
        name: String,
    ) -> BoxFuture<'_, Result<Handle>>;
    fn delete(&mut self, storage: u32, handle: Handle) -> BoxFuture<'_, Result<()>>;
    fn rename(&mut self, storage: u32, handle: Handle, name: String) -> BoxFuture<'_, Result<()>>;
    fn upload(&mut self, request: Upload) -> BoxFuture<'_, Result<Handle>>;
    fn download(&mut self, request: Download) -> BoxFuture<'_, Result<()>>;
    fn thumbnail(&mut self, storage: u32, handle: Handle)
    -> BoxFuture<'_, Result<Option<Vec<u8>>>>;
    fn events(&self) -> BoxStream<'static, Event>;
    fn close(self: Box<Self>) -> BoxFuture<'static, ()>;
}

pub struct Upload {
    pub storage: u32,
    pub parent: Handle,
    pub entry: Entry,
    pub data: UploadStream,
    pub cancel: CancelToken,
}

pub struct Download {
    pub storage: u32,
    pub handle: Handle,
    pub size: u64,
    pub sink: Box<dyn DownloadSink>,
    pub progress: ProgressFn,
    pub cancel: CancelToken,
}

pub(crate) fn no_events() -> impl Stream<Item = Event> {
    futures::stream::pending()
}
