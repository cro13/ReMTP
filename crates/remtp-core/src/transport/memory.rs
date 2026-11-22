use std::collections::{HashMap, HashSet};
use std::io;
use std::time::Duration;

use bytes::{Bytes, BytesMut};
use futures::{FutureExt, StreamExt, future::BoxFuture, stream::BoxStream};
use mtp_rs::CancelToken;

use super::{Download, Event, Handle, Object, Transport, Upload, no_events};
use crate::{DeviceDetails, DeviceSummary, Entry, RemtpError, Result, StorageInfo};

#[derive(Clone, Copy, Debug, Default)]
pub struct MemoryLatency {
    pub details: Duration,
    pub list: Duration,
    pub stat: Duration,
    pub mkdir: Duration,
    pub delete: Duration,
    pub rename: Duration,
    pub upload: Duration,
    pub download: Duration,
}

#[cfg(test)]
pub(crate) enum MemoryOp<'a> {
    List(Handle),
    Renamed(&'a str),
    Rename(&'a str),
    Delete(&'a str),
    Uploaded(&'a str),
    Downloaded,
    Thumbnail(&'a str),
}

#[cfg(test)]
type Hook = Box<dyn FnMut(MemoryOp<'_>) -> Result<()> + Send>;

#[derive(Default)]
pub struct MemoryTransport {
    objects: HashMap<Handle, (Object, Bytes)>,
    next: Handle,
    latency: MemoryLatency,
    #[cfg(test)]
    pub(crate) hook: Option<Hook>,
}

impl MemoryTransport {
    pub fn new(latency: MemoryLatency) -> Self {
        Self {
            latency,
            ..Self::default()
        }
    }

    fn insert(
        &mut self,
        storage: u32,
        parent: Handle,
        entry: Entry,
        bytes: Bytes,
    ) -> Result<Handle> {
        storage_exists(storage)?;
        if parent != 0
            && !self
                .objects
                .get(&parent)
                .is_some_and(|(object, _)| object.entry.is_dir)
        {
            return Err(missing(parent));
        }
        if self
            .objects
            .values()
            .any(|(object, _)| object.parent == parent && object.entry.name == entry.name)
        {
            return Err(RemtpError::AlreadyExists { path: entry.name });
        }
        self.next += 1;
        let handle = self.next;
        self.objects.insert(
            handle,
            (
                Object {
                    handle,
                    parent,
                    storage,
                    entry,
                },
                bytes,
            ),
        );
        Ok(handle)
    }
}

fn missing(handle: Handle) -> RemtpError {
    RemtpError::NotFound {
        path: handle.to_string(),
    }
}

fn storage_exists(storage: u32) -> Result<()> {
    if storage == 1 {
        Ok(())
    } else {
        Err(missing(u64::from(storage)))
    }
}

async fn delay(duration: Duration) {
    if !duration.is_zero() {
        tokio::time::sleep(duration).await;
    }
}

impl Transport for MemoryTransport {
    fn details(&mut self) -> BoxFuture<'_, Result<DeviceDetails>> {
        async {
            delay(self.latency.details).await;
            let total = 1 << 40;
            let used: u64 = self
                .objects
                .values()
                .map(|(_, bytes)| bytes.len() as u64)
                .sum();
            Ok(DeviceDetails {
                summary: DeviceSummary {
                    id: "memory".into(),
                    manufacturer: "ReMTP".into(),
                    model: "Memory".into(),
                    name: "Memory".into(),
                    serial: "memory".into(),
                },
                storages: vec![StorageInfo {
                    id: 1,
                    description: "Memory".into(),
                    capacity_bytes: total,
                    free_bytes: total - used,
                    removable: false,
                }],
                link_speed: None,
                link_speed_mbps: None,
            })
        }
        .boxed()
    }

    fn list(
        &mut self,
        storage: u32,
        parent: Handle,
        cancel: CancelToken,
    ) -> BoxFuture<'_, Result<Vec<Object>>> {
        async move {
            delay(self.latency.list).await;
            storage_exists(storage)?;
            if cancel.is_cancelled() {
                return Err(RemtpError::Cancelled);
            }
            #[cfg(test)]
            if let Some(hook) = &mut self.hook {
                hook(MemoryOp::List(parent))?;
            }
            Ok(self
                .objects
                .values()
                .filter(|(item, _)| item.storage == storage && item.parent == parent)
                .map(|(item, _)| item.clone())
                .collect())
        }
        .boxed()
    }

    fn stat(&mut self, handle: Handle) -> BoxFuture<'_, Result<Object>> {
        async move {
            delay(self.latency.stat).await;
            self.objects
                .get(&handle)
                .map(|(item, _)| item.clone())
                .ok_or_else(|| missing(handle))
        }
        .boxed()
    }

    fn mkdir(
        &mut self,
        storage: u32,
        parent: Handle,
        name: String,
    ) -> BoxFuture<'_, Result<Handle>> {
        async move {
            delay(self.latency.mkdir).await;
            self.insert(
                storage,
                parent,
                Entry {
                    name,
                    is_dir: true,
                    size: 0,
                    modified: None,
                },
                Bytes::new(),
            )
        }
        .boxed()
    }

    fn delete(&mut self, storage: u32, handle: Handle) -> BoxFuture<'_, Result<()>> {
        async move {
            delay(self.latency.delete).await;
            storage_exists(storage)?;
            if !self.objects.contains_key(&handle) {
                return Err(missing(handle));
            }
            #[cfg(test)]
            if let Some(hook) = &mut self.hook {
                hook(MemoryOp::Delete(&self.objects[&handle].0.entry.name))?;
            }
            let mut pending = vec![handle];
            let mut deleted = HashSet::new();
            while let Some(handle) = pending.pop() {
                if deleted.insert(handle) {
                    pending.extend(
                        self.objects
                            .values()
                            .filter(|(item, _)| item.parent == handle)
                            .map(|(item, _)| item.handle),
                    );
                }
            }
            self.objects.retain(|handle, _| !deleted.contains(handle));
            Ok(())
        }
        .boxed()
    }

    fn rename(&mut self, storage: u32, handle: Handle, name: String) -> BoxFuture<'_, Result<()>> {
        async move {
            #[cfg(test)]
            if let Some(hook) = &mut self.hook {
                hook(MemoryOp::Rename(&name))?;
            }
            delay(self.latency.rename).await;
            storage_exists(storage)?;
            let parent = self
                .objects
                .get(&handle)
                .ok_or_else(|| missing(handle))?
                .0
                .parent;
            if self.objects.values().any(|(item, _)| {
                item.parent == parent && item.handle != handle && item.entry.name == name
            }) {
                return Err(RemtpError::AlreadyExists { path: name });
            }
            #[cfg(test)]
            if let Some(hook) = &mut self.hook {
                hook(MemoryOp::Renamed(&name))?;
            }
            self.objects.get_mut(&handle).unwrap().0.entry.name = name;
            Ok(())
        }
        .boxed()
    }

    fn upload(&mut self, request: Upload) -> BoxFuture<'_, Result<Handle>> {
        async move {
            let Upload {
                storage,
                parent,
                entry,
                mut data,
                cancel,
            } = request;
            let mut bytes = BytesMut::new();
            while let Some(chunk) = data.next().await {
                if cancel.is_cancelled() {
                    return Err(RemtpError::Cancelled);
                }
                bytes.extend_from_slice(&chunk?);
            }
            delay(self.latency.upload).await;
            if cancel.is_cancelled() {
                return Err(RemtpError::Cancelled);
            }
            if entry.size != bytes.len() as u64 {
                return Err(io::Error::other("source size changed").into());
            }
            #[cfg(test)]
            if let Some(hook) = &mut self.hook {
                hook(MemoryOp::Uploaded(&entry.name))?;
            }
            self.insert(storage, parent, entry, bytes.freeze())
        }
        .boxed()
    }

    fn download(&mut self, request: Download) -> BoxFuture<'_, Result<()>> {
        async move {
            let Download {
                storage,
                handle,
                size: _,
                mut sink,
                progress,
                cancel,
            } = request;
            storage_exists(storage)?;
            let (_, bytes) = self.objects.get(&handle).ok_or_else(|| missing(handle))?;
            let bytes = bytes.clone();
            let mut offset = 0;
            while offset < bytes.len() {
                if cancel.is_cancelled() {
                    return Err(RemtpError::Cancelled);
                }
                let end = (offset + 64 * 1024).min(bytes.len());
                let chunk = bytes.slice(offset..end);
                let len = chunk.len() as u64;
                sink.write_chunk(chunk).await?;
                progress(len);
                offset = end;
            }
            delay(self.latency.download).await;
            if cancel.is_cancelled() {
                return Err(RemtpError::Cancelled);
            }
            sink.flush().await?;
            #[cfg(test)]
            if let Some(hook) = &mut self.hook {
                hook(MemoryOp::Downloaded)?;
            }
            Ok(())
        }
        .boxed()
    }

    /// A file's contents stand in for its thumbnail; folders and empty files have none.
    fn thumbnail(
        &mut self,
        storage: u32,
        handle: Handle,
    ) -> BoxFuture<'_, Result<Option<Vec<u8>>>> {
        async move {
            storage_exists(storage)?;
            let (object, bytes) = self.objects.get(&handle).ok_or_else(|| missing(handle))?;
            #[cfg(test)]
            if let Some(hook) = &mut self.hook {
                hook(MemoryOp::Thumbnail(&object.entry.name))?;
            }
            Ok((!object.entry.is_dir && !bytes.is_empty()).then(|| bytes.to_vec()))
        }
        .boxed()
    }

    fn events(&self) -> BoxStream<'static, Event> {
        no_events().boxed()
    }
    fn close(self: Box<Self>) -> BoxFuture<'static, ()> {
        async {}.boxed()
    }
}
