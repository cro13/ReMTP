use std::collections::{HashMap, HashSet, VecDeque};
use std::panic::AssertUnwindSafe;
use std::sync::{Arc, Mutex as StdMutex, Weak};
#[cfg(target_os = "macos")]
use std::time::Duration;
use std::time::Instant;

use futures::{FutureExt, StreamExt, future::BoxFuture, stream};
use mtp_rs::CancelToken;
use mtp_rs::mtp::{Backend, MtpDevice, MtpDeviceInfo};
use tokio::sync::{Mutex, mpsc, oneshot, watch};

use crate::adb::AdbState;
use crate::transfer::Transfer;
use crate::transport::{Event, Handle, MtpTransport, Object, Transport, device_summary, mtp_error};
use crate::tree::{self, Tree};
use crate::{AccessState, DeviceDetails, DeviceSummary, Entry, RemtpError, Result, access};

const TINY_DELETE_DESCENDANTS: usize = 32;

#[derive(Default)]
pub struct Engine {
    sessions: Mutex<HashMap<DeviceKey, (String, Arc<Device>)>>,
    discovery: StdMutex<Discovery>,
    pub(crate) adb: AdbState,
}

pub enum DeviceEvent {
    Added(DeviceSummary),
    Removed(String),
}

impl Engine {
    pub fn new() -> Self {
        let _ = access::restore(true);
        Self::default()
    }

    pub fn list_devices(&self) -> Result<Vec<DeviceSummary>> {
        Ok(self.discover()?.into_iter().map(|d| d.summary).collect())
    }

    pub fn device_events(
        self: &Arc<Self>,
    ) -> Result<impl futures::Stream<Item = DeviceEvent> + use<>> {
        let engine = Arc::downgrade(self);
        let mut known = HashMap::new();
        Ok(mtp_rs::mtp::watch_devices()
            .map_err(|e| mtp_error(e, ""))?
            .then(move |_| {
                let changes = engine.upgrade().and_then(|engine| {
                    let devices = engine.discover().ok()?;
                    let mut current = HashMap::new();
                    let added = devices
                        .into_iter()
                        .filter_map(|device| {
                            let is_new = known.get(&device.key) != Some(&device.summary.id);
                            current.insert(device.key, device.summary.id.clone());
                            is_new.then_some(DeviceEvent::Added(device.summary))
                        })
                        .collect::<Vec<_>>();
                    let removed = std::mem::replace(&mut known, current)
                        .into_iter()
                        .filter(|(key, id)| known.get(key) != Some(id))
                        .collect::<Vec<_>>();
                    Some((engine, removed, added))
                });
                async move {
                    let Some((engine, removed, added)) = changes else {
                        return Vec::new();
                    };
                    if !removed.is_empty() {
                        let sessions = engine.sessions.lock().await;
                        for (key, id) in &removed {
                            if let Some((session_id, device)) = sessions.get(key)
                                && session_id == id
                            {
                                device.closing.send_replace(true);
                            }
                        }
                    }
                    removed
                        .into_iter()
                        .map(|(_, id)| DeviceEvent::Removed(id))
                        .chain(added)
                        .collect()
                }
            })
            .flat_map(stream::iter))
    }

    pub async fn open(&self, id: &str) -> Result<Arc<Device>> {
        let mut sessions = self.sessions.lock().await;
        let found = self.find(id)?;
        if self.adb.is_switching(&found.key) {
            return Err(RemtpError::DeviceBusy {
                holder: "USB mode switch".into(),
            });
        }
        if let Some((session_id, device)) = sessions.get(&found.key) {
            if session_id == id && !device.is_closed() {
                return Ok(device.clone());
            }
            device.close().await;
        }
        let transport =
            MtpTransport::open(&found.info, found.summary, found.cached, found.backend).await?;
        self.discovery
            .lock()
            .unwrap()
            .opened
            .insert(found.key.clone(), transport.summary().clone());
        let device = Device::from_transport(transport);
        sessions.retain(|_, (_, device)| !device.is_closed());
        sessions.insert(found.key, (id.into(), device.clone()));
        Ok(device)
    }

    pub fn access_state(&self, id: &str) -> AccessState {
        self.find(id)
            .map_or(AccessState::Unknown, |d| access::state(&d.info))
    }

    pub(crate) async fn close_for_usb_switch(&self, key: &DeviceKey) {
        let mut sessions = self.sessions.lock().await;
        if let Some((_, device)) = sessions.remove(key) {
            device.close().await;
        }
    }

    pub async fn release_system_hold(&self, id: &str) -> Result<()> {
        #[cfg(not(target_os = "macos"))]
        {
            let _ = id;
            Ok(())
        }
        #[cfg(target_os = "macos")]
        {
            match self.open(id).await {
                Ok(_) => return Ok(()),
                Err(RemtpError::DeviceBusy { holder }) if holder == "ptpcamerad" => {}
                Err(error) => return Err(error),
            }
            let suppression = tokio::task::spawn_blocking(access::suppress)
                .await
                .map_err(|error| RemtpError::TaskFailed {
                    message: format!("ptpcamerad suppression task failed: {error}"),
                })??;
            let result = tokio::time::timeout(Duration::from_secs(2), async {
                loop {
                    match self.open(id).await {
                        Ok(_) => return Ok(()),
                        Err(RemtpError::DeviceBusy { .. }) => {
                            tokio::time::sleep(Duration::from_millis(20)).await
                        }
                        Err(error) => return Err(error),
                    }
                }
            })
            .await
            .unwrap_or_else(|_| {
                Err(RemtpError::DeviceBusy {
                    holder: "ptpcamerad".into(),
                })
            });
            match result {
                Ok(()) => Ok(()),
                Err(error) => Err(error.with_cleanup(
                    "could not restore ptpcamerad",
                    tokio::task::spawn_blocking(move || suppression.restore())
                        .await
                        .map_err(|error| RemtpError::TaskFailed {
                            message: format!("ptpcamerad restore task failed: {error}"),
                        })
                        .and_then(|result| result),
                )),
            }
        }
    }

    pub fn restore_system_hold(&self) -> Result<()> {
        access::restore(false)
    }
}

#[derive(Default)]
struct Discovery {
    opened: HashMap<DeviceKey, DeviceSummary>,
    duplicate_ids: HashSet<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub(crate) struct DeviceKey {
    pub(crate) vendor: u16,
    pub(crate) product: u16,
    pub(crate) location: u64,
    pub(crate) serial: String,
}

impl From<&MtpDeviceInfo> for DeviceKey {
    fn from(info: &MtpDeviceInfo) -> Self {
        Self {
            vendor: info.vendor_id,
            product: info.product_id,
            location: info.location_id,
            serial: info.serial_number.clone().unwrap_or_default(),
        }
    }
}

impl DeviceKey {
    pub(crate) fn serial_id(&self) -> Option<String> {
        let serial = self.serial.trim();
        let repeated_digit = serial.bytes().next().is_some_and(|first| {
            first.is_ascii_digit() && serial.bytes().all(|byte| byte == first)
        });
        let reserved = serial
            .strip_prefix("loc")
            .is_some_and(|loc| loc.len() == 16 && loc.bytes().all(|byte| byte.is_ascii_hexdigit()));
        (serial.chars().count() >= 6
            && !repeated_digit
            && !reserved
            && !["1234567", "0123456789ABCDEF"]
                .iter()
                .any(|s| serial.eq_ignore_ascii_case(s)))
        .then(|| format!("{:04x}:{:04x}:{serial}", self.vendor, self.product))
    }

    fn location_id(&self) -> String {
        format!(
            "{:04x}:{:04x}:loc{:016x}",
            self.vendor, self.product, self.location
        )
    }

    fn backend(&self, devices: &[Self]) -> Backend {
        if cfg!(windows)
            && devices.iter().any(|other| {
                self.location != other.location
                    && self.vendor == other.vendor
                    && self.product == other.product
                    && (self.serial.trim().is_empty()
                        || self.serial.trim().eq_ignore_ascii_case(other.serial.trim()))
            })
        {
            Backend::Usb
        } else {
            Backend::Auto
        }
    }
}

pub(crate) fn device_ids(devices: &[DeviceKey], duplicates: &mut HashSet<String>) -> Vec<String> {
    let mut seen = HashSet::new();
    let candidates = devices
        .iter()
        .map(|key| {
            let id = key.serial_id()?;
            if !seen.insert(id.clone()) {
                duplicates.insert(id.clone());
            }
            Some(id)
        })
        .collect::<Vec<_>>();
    devices
        .iter()
        .zip(candidates)
        .map(|(key, candidate)| {
            candidate
                .filter(|id| !duplicates.contains(id))
                .unwrap_or_else(|| key.location_id())
        })
        .collect()
}

struct DiscoveredDevice {
    info: MtpDeviceInfo,
    key: DeviceKey,
    summary: DeviceSummary,
    cached: bool,
    backend: Backend,
}

impl Engine {
    pub(crate) fn mtp_ids(&self) -> Result<HashMap<DeviceKey, String>> {
        Ok(self
            .discover()?
            .into_iter()
            .map(|device| (device.key, device.summary.id))
            .collect())
    }

    fn discover(&self) -> Result<Vec<DiscoveredDevice>> {
        let mut state = self.discovery.lock().unwrap();
        let devices = MtpDevice::list_devices().map_err(|e| mtp_error(e, ""))?;
        let keys = devices.iter().map(DeviceKey::from).collect::<Vec<_>>();
        let ids = device_ids(&keys, &mut state.duplicate_ids);
        state.opened.retain(|key, _| keys.contains(key));
        Ok(devices
            .into_iter()
            .zip(&keys)
            .zip(ids)
            .map(|((info, key), id)| {
                let cached = state.opened.get(key);
                let summary = if let Some(cached) = cached {
                    DeviceSummary {
                        id,
                        ..cached.clone()
                    }
                } else {
                    device_summary(&info, id)
                };
                DiscoveredDevice {
                    info,
                    key: key.clone(),
                    summary,
                    cached: cached.is_some(),
                    backend: key.backend(&keys),
                }
            })
            .collect())
    }

    fn find(&self, id: &str) -> Result<DiscoveredDevice> {
        self.discover()?
            .into_iter()
            .find(|device| device.summary.id == id)
            .ok_or(RemtpError::NoDevice)
    }
}

type Request = Box<dyn for<'a> FnOnce(&'a mut Session) -> BoxFuture<'a, ()> + Send>;

pub struct Device {
    tx: mpsc::Sender<Request>,
    closing: watch::Sender<bool>,
    closed: watch::Receiver<bool>,
    pub(crate) queue: StdMutex<Option<oneshot::Receiver<()>>>,
    transfers: StdMutex<Vec<Weak<Transfer>>>,
}

impl Device {
    pub fn from_transport(transport: impl Transport) -> Arc<Self> {
        let (tx, mut requests) = mpsc::channel::<Request>(64);
        let (closing, mut shutdown) = watch::channel(false);
        let (exited, closed) = watch::channel(false);
        let mut events = transport.events();
        let (event_tx, mut updates) = mpsc::channel(256);
        let event_task = tokio::spawn(async move {
            while let Some(event) = events.next().await {
                if event_tx.send(event).await.is_err() {
                    break;
                }
            }
        });
        let mut session = Session {
            transport: Box::new(transport),
            trees: HashMap::new(),
            last_file: None,
            dead: false,
        };
        let actor_closing = closing.clone();
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    biased;
                    _ = shutdown.changed() => break,
                    Some(event) = updates.recv() => session.event(event).await,
                    request = requests.recv() => match request {
                        Some(request) => request(&mut session).await,
                        None => break,
                    },
                }
                if session.dead {
                    break;
                }
            }
            actor_closing.send_replace(true);
            drop(requests);
            event_task.abort();
            let _ = event_task.await;
            session.transport.close().await;
            exited.send_replace(true);
        });
        Arc::new(Self {
            tx,
            closing,
            closed,
            queue: StdMutex::new(None),
            transfers: StdMutex::new(Vec::new()),
        })
    }

    pub(crate) async fn call<T: Send + 'static>(
        &self,
        run: impl for<'a> FnOnce(&'a mut Session) -> BoxFuture<'a, Result<T>> + Send + 'static,
    ) -> Result<T> {
        if self.is_closed() {
            return Err(RemtpError::Disconnected);
        }
        let (tx, rx) = oneshot::channel();
        self.tx
            .send(Box::new(move |session| {
                async move {
                    let result = AssertUnwindSafe(async { run(session).await })
                        .catch_unwind()
                        .await;
                    let result = match result {
                        Ok(result) => {
                            session.dead |= result.as_ref().is_err_and(|e| e.is_disconnected());
                            result
                        }
                        Err(_) => {
                            session.dead = true;
                            Err(RemtpError::TaskFailed {
                                message: "device request panicked".into(),
                            })
                        }
                    };
                    let _ = tx.send(result);
                }
                .boxed()
            }))
            .await
            .map_err(|_| RemtpError::Disconnected)?;
        rx.await.map_err(|_| {
            if *self.closing.borrow() || *self.closed.borrow() {
                RemtpError::Disconnected
            } else {
                RemtpError::TaskFailed {
                    message: "device request ended without a result".into(),
                }
            }
        })?
    }

    pub(crate) fn register_transfer(&self, transfer: &Arc<Transfer>) -> Result<()> {
        let mut transfers = self.transfers.lock().unwrap();
        if self.is_closed() {
            return Err(RemtpError::Disconnected);
        }
        transfers.retain(|entry| entry.strong_count() != 0);
        transfers.push(Arc::downgrade(transfer));
        Ok(())
    }

    fn is_closed(&self) -> bool {
        *self.closing.borrow() || *self.closed.borrow() || self.tx.is_closed()
    }

    pub(crate) async fn disconnected(&self) {
        self.tx.closed().await;
    }

    pub async fn close(&self) {
        self.closing.send_replace(true);
        for entry in self.transfers.lock().unwrap().drain(..) {
            if let Some(transfer) = entry.upgrade() {
                transfer.cancel();
            }
        }
        let mut closed = self.closed.clone();
        let _ = closed.wait_for(|closed| *closed).await;
    }

    pub async fn details(&self) -> Result<DeviceDetails> {
        self.call(|s| s.transport.details()).await
    }

    pub async fn list(&self, storage: u32, path: &str) -> Result<Vec<Entry>> {
        self.list_cancel(storage, path, CancelToken::new()).await
    }

    pub(crate) async fn list_cancel(
        &self,
        storage: u32,
        path: &str,
        cancel: CancelToken,
    ) -> Result<Vec<Entry>> {
        let path = tree::normalize(path)?;
        self.call(move |s| async move { s.list(storage, &path, cancel).await }.boxed())
            .await
    }

    pub async fn stat(&self, storage: u32, path: &str) -> Result<Entry> {
        let path = tree::normalize(path)?;
        self.call(move |s| {
            async move { Ok(s.resolve(storage, &path, &CancelToken::new()).await?.entry) }.boxed()
        })
        .await
    }

    pub async fn create_folder(&self, storage: u32, path: &str) -> Result<()> {
        let path = tree::normalize(path)?;
        self.call(move |s| async move { s.create_folders(storage, &path).await }.boxed())
            .await
    }

    pub async fn delete(&self, storage: u32, path: &str) -> Result<()> {
        self.delete_cancel(storage, path, CancelToken::new()).await
    }

    pub async fn delete_cancel(&self, storage: u32, path: &str, cancel: CancelToken) -> Result<()> {
        let path = tree::normalize(path)?;
        self.call(move |s| async move { s.delete(storage, &path, &cancel).await }.boxed())
            .await
    }

    pub async fn rename(&self, storage: u32, path: &str, new_name: &str) -> Result<()> {
        let path = tree::normalize(path)?;
        let new_name = new_name.to_owned();
        self.call(move |s| async move { s.rename(storage, &path, &new_name).await }.boxed())
            .await
    }

    /// The device's thumbnail of an image or video at `path`, found through the cached tree. `None` for
    /// anything else, and when the device has no thumbnail for it or doesn't do thumbnails at all.
    pub async fn thumbnail(&self, storage: u32, path: &str) -> Result<Option<Vec<u8>>> {
        let path = tree::normalize(path)?;
        if !has_thumbnail(&path) {
            return Ok(None);
        }
        self.call(move |s| async move { s.thumbnail(storage, &path).await }.boxed())
            .await
    }

    pub async fn invalidate(&self, storage: u32, path: &str) -> Result<()> {
        let path = tree::normalize(path)?;
        self.call(move |s| {
            async move {
                s.tree(storage).invalidate(&path);
                Ok(())
            }
            .boxed()
        })
        .await
    }
}

pub(crate) struct Session {
    pub transport: Box<dyn Transport>,
    trees: HashMap<u32, Tree>,
    pub last_file: Option<Instant>,
    dead: bool,
}

impl Session {
    pub fn tree(&mut self, storage: u32) -> &mut Tree {
        self.trees.entry(storage).or_default()
    }

    pub(crate) async fn fill(
        &mut self,
        storage: u32,
        path: &str,
        handle: Handle,
        cancel: &CancelToken,
    ) -> Result<()> {
        if cancel.is_cancelled() {
            return Err(RemtpError::Cancelled);
        }
        if self.tree(storage).contains(path) {
            return Ok(());
        }
        let listing = self
            .transport
            .list_with_completeness(storage, handle, cancel.clone())
            .await?;
        let tree = self.tree(storage);
        let mut complete = listing.complete;
        for object in listing.objects {
            if !valid_device_entry(&object) {
                complete = false;
                continue;
            }
            let child = tree::join(path, &object.entry.name);
            if tree
                .lookup(&child)
                .is_some_and(|old| old.handle != object.handle)
                || tree.path(object.handle).is_some_and(|old| old != child)
            {
                complete = false;
            }
            tree.insert(child, object);
        }
        tree.mark_loaded(path.into(), complete);
        Ok(())
    }

    pub async fn resolve(
        &mut self,
        storage: u32,
        path: &str,
        cancel: &CancelToken,
    ) -> Result<Object> {
        if path == "/" {
            if !self.trees.contains_key(&storage) {
                self.fill(storage, "/", 0, cancel).await?;
            }
            return Ok(root(storage));
        }
        let mut current = root(storage);
        let mut prefix = "/".to_owned();
        for part in path.split('/').skip(1) {
            if !current.entry.is_dir {
                return Err(missing(path));
            }
            if let Err(error) = self.fill(storage, &prefix, current.handle, cancel).await {
                if matches!(error, RemtpError::StaleHandle) {
                    self.tree(storage).invalidate(tree::parent(&prefix));
                }
                return Err(error);
            }
            prefix = tree::join(&prefix, part);
            current = self
                .tree(storage)
                .lookup(&prefix)
                .cloned()
                .ok_or_else(|| missing(path))?;
        }
        Ok(current)
    }

    pub(crate) async fn list(
        &mut self,
        storage: u32,
        path: &str,
        cancel: CancelToken,
    ) -> Result<Vec<Entry>> {
        for attempt in 0..2 {
            let result = async {
                let object = self.resolve(storage, path, &cancel).await?;
                if !object.entry.is_dir {
                    return Err(missing(path));
                }
                self.fill(storage, path, object.handle, &cancel).await?;
                Ok(self.tree(storage).entries(path))
            }
            .await;
            if !matches!(result, Err(RemtpError::StaleHandle)) || attempt == 1 {
                return result;
            }
            self.tree(storage).invalidate(tree::parent(path));
        }
        unreachable!()
    }

    async fn create_folders(&mut self, storage: u32, path: &str) -> Result<()> {
        let mut current = root(storage);
        let mut prefix = "/".to_owned();
        for part in path.split('/').filter(|part| !part.is_empty()) {
            if !tree::valid_component(part)
                || part.encode_utf16().count() > mtp_rs::mtp::MAX_NAME_UNITS
            {
                return Err(RemtpError::Protocol {
                    message: format!("invalid folder name: {part}"),
                });
            }
            self.fill(storage, &prefix, current.handle, &CancelToken::new())
                .await?;
            prefix = tree::join(&prefix, part);
            if let Some(object) = self.tree(storage).lookup(&prefix).cloned() {
                if !object.entry.is_dir {
                    return Err(RemtpError::AlreadyExists { path: prefix });
                }
                current = object;
            } else {
                let handle = self
                    .transport
                    .mkdir(storage, current.handle, part.into())
                    .await?;
                current = Object {
                    storage,
                    handle,
                    parent: current.handle,
                    entry: Entry {
                        name: part.into(),
                        is_dir: true,
                        size: 0,
                        modified: None,
                    },
                };
                let tree = self.tree(storage);
                tree.insert(prefix.clone(), current.clone());
                tree.mark_loaded(prefix.clone(), true);
            }
        }
        Ok(())
    }

    async fn delete(&mut self, storage: u32, path: &str, cancel: &CancelToken) -> Result<()> {
        if path == "/" {
            return Err(RemtpError::Protocol {
                message: "cannot delete a storage root".into(),
            });
        }
        let first = self.resolve(storage, path, cancel).await?;
        match self.delete_object(storage, path, &first, cancel).await {
            Err(RemtpError::StaleHandle) => {
                // The cached handle is gone. Only delete what is at the path now if it is still the
                // same object (type, size and date); never delete a different file that took its place.
                let again = self.resolve(storage, path, cancel).await?;
                let (a, b) = (&first.entry, &again.entry);
                if a.modified.is_none()
                    || a.is_dir != b.is_dir
                    || a.size != b.size
                    || a.modified != b.modified
                {
                    return Err(RemtpError::Protocol {
                        message: format!("{path} changed on the device, so it wasn't deleted"),
                    });
                }
                self.delete_object(storage, path, &again, cancel).await
            }
            result => result,
        }
    }

    async fn delete_object(
        &mut self,
        storage: u32,
        path: &str,
        object: &Object,
        cancel: &CancelToken,
    ) -> Result<()> {
        if !object.entry.is_dir {
            return self.delete_one(storage, path, object.handle, cancel).await;
        }
        let mut pending = VecDeque::from([(path.to_owned(), object.handle)]);
        let mut folders = Vec::new();
        let mut files = Vec::new();
        while let Some((folder, handle)) = pending.pop_front() {
            if let Err(error) = self.fill(storage, &folder, handle, cancel).await {
                if matches!(error, RemtpError::StaleHandle) {
                    self.tree(storage).invalidate(tree::parent(&folder));
                    if folder != path {
                        return Err(RemtpError::Protocol {
                            message: format!(
                                "{folder} changed on the device, so {path} wasn't deleted"
                            ),
                        });
                    }
                }
                return Err(error);
            }
            let tree = self.tree(storage);
            if !tree.complete(&folder) {
                tree.invalidate(&folder);
                return Err(RemtpError::Protocol {
                    message: format!(
                        "cannot safely delete {path}: the listing for {folder} is incomplete"
                    ),
                });
            }
            for (child, object) in tree.children(&folder) {
                let target = (child.clone(), object.handle);
                if object.entry.is_dir {
                    pending.push_back(target);
                } else {
                    files.push(target);
                }
            }
            folders.push((folder, handle));
        }
        let count = files.len() + folders.len();
        let incomplete = |next: &str, remaining, source| RemtpError::DeleteIncomplete {
            path: path.into(),
            next: next.into(),
            remaining,
            source: Box::new(source),
        };
        if count - 1 <= TINY_DELETE_DESCENDANTS {
            return self
                .delete_one(storage, path, object.handle, cancel)
                .await
                .map_err(|error| match error {
                    RemtpError::StaleHandle | RemtpError::Cancelled => error,
                    error => incomplete(path, count, error),
                });
        }
        files.extend(folders.into_iter().rev());
        for (index, (child, handle)) in files.into_iter().enumerate() {
            if let Err(error) = self.delete_one(storage, &child, handle, cancel).await {
                return Err(if index == 0 && matches!(error, RemtpError::Cancelled) {
                    error
                } else {
                    incomplete(&child, count - index, error)
                });
            }
        }
        Ok(())
    }

    async fn delete_one(
        &mut self,
        storage: u32,
        path: &str,
        handle: Handle,
        cancel: &CancelToken,
    ) -> Result<()> {
        if cancel.is_cancelled() {
            return Err(RemtpError::Cancelled);
        }
        let result = self.delete_known(storage, path, handle).await;
        if result.is_err() {
            self.tree(storage).invalidate(tree::parent(path));
        }
        result
    }

    pub(crate) async fn delete_known(
        &mut self,
        storage: u32,
        path: &str,
        handle: Handle,
    ) -> Result<()> {
        self.transport.delete(storage, handle).await?;
        self.tree(storage).remove(path);
        Ok(())
    }

    pub async fn rename(&mut self, storage: u32, path: &str, name: &str) -> Result<()> {
        let target = tree::join(tree::parent(path), name);
        if path == "/"
            || !tree::valid_component(name)
            || name.encode_utf16().count() > mtp_rs::mtp::MAX_NAME_UNITS
        {
            return Err(RemtpError::Protocol {
                message: format!("invalid rename: {target}"),
            });
        }
        if path == target {
            return Ok(());
        }
        for attempt in 0..2 {
            let result = async {
                let object = self.resolve(storage, path, &CancelToken::new()).await?;
                self.rename_known(storage, path, object.handle, name).await
            }
            .await;
            if matches!(result, Err(RemtpError::StaleHandle)) && attempt == 0 {
                self.tree(storage).invalidate(tree::parent(path));
                continue;
            }
            return result;
        }
        unreachable!()
    }

    pub(crate) async fn rename_known(
        &mut self,
        storage: u32,
        path: &str,
        handle: Handle,
        name: &str,
    ) -> Result<()> {
        let target = tree::join(tree::parent(path), name);
        if self.tree(storage).lookup(&target).is_some() {
            return Err(RemtpError::AlreadyExists { path: target });
        }
        self.transport.rename(storage, handle, name.into()).await?;
        self.tree(storage).rename(path, name);
        Ok(())
    }

    async fn thumbnail(&mut self, storage: u32, path: &str) -> Result<Option<Vec<u8>>> {
        for attempt in 0..2 {
            let result = async {
                let object = self.resolve(storage, path, &CancelToken::new()).await?;
                if object.entry.is_dir {
                    return Ok(None);
                }
                self.transport.thumbnail(storage, object.handle).await
            }
            .await;
            if matches!(result, Err(RemtpError::StaleHandle)) && attempt == 0 {
                self.tree(storage).invalidate(tree::parent(path));
                continue;
            }
            return result;
        }
        unreachable!()
    }

    async fn event(&mut self, event: Event) {
        let locate = |trees: &HashMap<u32, Tree>, handle| {
            trees
                .iter()
                .find_map(|(&id, tree)| tree.path(handle).map(|path| (id, path.to_owned())))
        };
        match event {
            Event::Added(handle) | Event::Changed(handle) => {
                let previous = locate(&self.trees, handle);
                if matches!(event, Event::Added(_)) && previous.is_some() {
                    return;
                }
                let object = match self.transport.stat(handle).await {
                    Ok(object) => object,
                    Err(error) => {
                        self.dead |= error.is_disconnected();
                        return;
                    }
                };
                let tree = self.tree(object.storage);
                let valid = valid_device_entry(&object);
                let new_path = tree
                    .path(object.parent)
                    .filter(|path| tree.contains(path))
                    .map(str::to_owned)
                    .and_then(|parent| {
                        if valid {
                            Some(tree::join(&parent, &object.entry.name))
                        } else {
                            tree.mark_incomplete(&parent);
                            None
                        }
                    });
                if let Some((id, path)) = previous
                    && (id != object.storage || new_path.as_ref() != Some(&path))
                {
                    self.tree(id).remove(&path);
                }
                if let Some(path) = new_path {
                    self.tree(object.storage).insert(path, object);
                }
            }
            Event::Removed(handle) => {
                if let Some((id, path)) = locate(&self.trees, handle) {
                    self.tree(id).remove(&path);
                }
            }
            Event::StoragesChanged => {
                self.trees.clear();
                self.dead |= self
                    .transport
                    .storages()
                    .await
                    .as_ref()
                    .is_err_and(RemtpError::is_disconnected);
            }
            Event::Reset | Event::Disconnected => {
                self.dead = true;
            }
        }
    }
}

fn valid_device_entry(object: &Object) -> bool {
    if tree::valid_component(&object.entry.name) {
        true
    } else {
        eprintln!(
            "ReMTP: skipping object {} with invalid name {:?}",
            object.handle, object.entry.name
        );
        false
    }
}

const THUMBNAIL_EXTENSIONS: &[&str] = &[
    "jpg", "jpeg", "jpe", "jfif", "png", "gif", "bmp", "webp", "heic", "heif", "avif", "tif",
    "tiff", "dng", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf", "srw", "pef", "mp4", "m4v",
    "mov", "3gp", "3g2", "mkv", "webm", "avi", "wmv", "mpg", "mpeg", "mts", "m2ts",
];

/// Images and videos, by extension (Android's MTP server picks object formats the same way).
fn has_thumbnail(path: &str) -> bool {
    path.rsplit('/')
        .next()
        .and_then(|name| name.rsplit_once('.'))
        .is_some_and(|(stem, extension)| {
            !stem.is_empty()
                && THUMBNAIL_EXTENSIONS
                    .iter()
                    .any(|known| known.eq_ignore_ascii_case(extension))
        })
}

fn missing(path: &str) -> RemtpError {
    RemtpError::NotFound { path: path.into() }
}
fn root(storage: u32) -> Object {
    Object {
        handle: 0,
        parent: 0,
        storage,
        entry: Entry {
            name: "/".into(),
            is_dir: true,
            size: 0,
            modified: None,
        },
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering::Relaxed};

    use super::*;
    use crate::transport::{MemoryOp, MemoryTransport, Upload};

    fn usb(serial: &str, location: u64) -> DeviceKey {
        DeviceKey {
            vendor: 0x4102,
            product: 0x1232,
            location,
            serial: serial.into(),
        }
    }

    #[test]
    fn ids_use_vid_pid_and_real_serial_or_location_for_placeholders() {
        let mut duplicates = HashSet::new();
        let ids = |serial, duplicates: &mut _| device_ids(&[usb(serial, 1)], duplicates);
        assert_eq!(ids("SP3A9876", &mut duplicates), ["4102:1232:SP3A9876"]);
        for serial in [
            "",
            "  ",
            "abc12",
            "000000",
            "99999999",
            "1234567",
            "0123456789abcdef",
            "loc0000000000000002",
        ] {
            assert_eq!(
                ids(serial, &mut duplicates),
                ["4102:1232:loc0000000000000001"]
            );
        }
    }

    #[test]
    fn duplicate_serials_use_distinct_location_ids() {
        let mut duplicates = HashSet::new();
        let first = usb("SP3A9876", 1);
        let second = usb("SP3A9876", 2);
        let other_model = DeviceKey {
            product: 0x1233,
            ..first.clone()
        };
        assert_eq!(
            device_ids(&[first, second.clone(), other_model], &mut duplicates),
            [
                "4102:1232:loc0000000000000001",
                "4102:1232:loc0000000000000002",
                "4102:1233:SP3A9876"
            ]
        );
        assert_eq!(
            device_ids(&[second], &mut duplicates),
            ["4102:1232:loc0000000000000002"]
        );
    }

    async fn bundle(files: usize) -> MemoryTransport {
        let mut memory = MemoryTransport::default();
        let bundle = memory.mkdir(1, 0, "bundle".into()).await.unwrap();
        let a = memory.mkdir(1, bundle, "a".into()).await.unwrap();
        let leaf = memory.mkdir(1, a, "leaf".into()).await.unwrap();
        memory.mkdir(1, bundle, "z".into()).await.unwrap();
        for index in 0..files {
            let name = format!("file-{index:03}");
            memory
                .upload(Upload {
                    storage: 1,
                    parent: if index % 2 == 0 { bundle } else { leaf },
                    entry: Entry {
                        name,
                        is_dir: false,
                        size: 0,
                        modified: Some(1),
                    },
                    data: stream::empty().boxed(),
                    cancel: CancelToken::new(),
                })
                .await
                .unwrap();
        }
        memory
    }

    #[tokio::test]
    async fn large_delete_uses_cached_bulk_listings_and_deletes_bottom_up() {
        let mut memory = bundle(300).await;
        memory.mkdir(1, 0, "keep".into()).await.unwrap();
        let log = Arc::new(StdMutex::new((Vec::new(), Vec::new())));
        let observed = log.clone();
        memory.hook = Some(Box::new(move |op| {
            match op {
                MemoryOp::List(handle) => observed.lock().unwrap().0.push(handle),
                MemoryOp::Delete(name) => observed.lock().unwrap().1.push(name.to_owned()),
                _ => {}
            }
            Ok(())
        }));
        let device = Device::from_transport(memory);
        device.list(1, "/bundle/a/leaf").await.unwrap();
        device.delete(1, "/bundle").await.unwrap();
        assert!(matches!(
            device.stat(1, "/bundle/a/leaf").await,
            Err(RemtpError::NotFound { .. })
        ));
        assert_eq!(device.list(1, "/").await.unwrap()[0].name, "keep");
        device.close().await;
        let (listings, deletes) = &*log.lock().unwrap();
        assert_eq!(listings.len(), 5);
        assert_eq!(listings.iter().collect::<HashSet<_>>().len(), 5);
        assert_eq!(deletes.len(), 304);
        assert_eq!(deletes[..300].iter().collect::<HashSet<_>>().len(), 300);
        assert!(deletes[..300].iter().all(|name| name.starts_with("file-")));
        assert_eq!(deletes[300..], ["leaf", "z", "a", "bundle"]);
    }

    #[tokio::test]
    async fn folder_with_32_descendants_uses_one_delete() {
        let mut memory = bundle(29).await;
        let deletes = Arc::new(AtomicUsize::new(0));
        let observed = deletes.clone();
        memory.hook = Some(Box::new(move |op| {
            if let MemoryOp::Delete(name) = op {
                assert_eq!(name, "bundle");
                observed.fetch_add(1, Relaxed);
            }
            Ok(())
        }));
        let device = Device::from_transport(memory);
        device.delete(1, "/bundle").await.unwrap();
        assert_eq!(deletes.load(Relaxed), 1);
        assert!(device.list(1, "/").await.unwrap().is_empty());
        device.close().await;
    }

    #[tokio::test]
    async fn recursive_delete_checks_cancellation_between_objects() {
        let mut memory = bundle(30).await;
        let cancel = CancelToken::new();
        let signal = cancel.clone();
        memory.hook = Some(Box::new(move |op| {
            if let MemoryOp::Delete(name) = op {
                assert_eq!(name, "file-000");
                signal.cancel();
            }
            Ok(())
        }));
        let device = Device::from_transport(memory);
        assert!(matches!(
            device.delete_cancel(1, "/bundle", cancel).await,
            Err(RemtpError::DeleteIncomplete { next, remaining: 33, source, .. })
                if next == "/bundle/file-002" && matches!(*source, RemtpError::Cancelled)
        ));
        let entries = device.list(1, "/bundle").await.unwrap();
        assert_eq!(entries.len(), 16);
        assert!(!entries.iter().any(|entry| entry.name == "file-000"));
        assert!(device.stat(1, "/bundle/a/leaf/file-001").await.is_ok());
        device.close().await;
    }

    #[tokio::test]
    async fn recursive_delete_does_not_retry_a_stale_child() {
        let mut memory = bundle(30).await;
        let mut stale = true;
        memory.hook = Some(Box::new(move |op| {
            if let MemoryOp::Delete(name) = op {
                assert!(matches!(name, "file-000" | "file-002"));
                if name == "file-002" && std::mem::take(&mut stale) {
                    return Err(RemtpError::StaleHandle);
                }
            }
            Ok(())
        }));
        let device = Device::from_transport(memory);
        assert!(matches!(
            device.delete(1, "/bundle").await,
            Err(RemtpError::DeleteIncomplete { next, remaining: 33, source, .. })
                if next == "/bundle/file-002" && matches!(*source, RemtpError::StaleHandle)
        ));
        assert!(matches!(
            device.stat(1, "/bundle/file-000").await,
            Err(RemtpError::NotFound { .. })
        ));
        assert!(device.stat(1, "/bundle/file-002").await.is_ok());
        device.close().await;
    }

    #[tokio::test]
    async fn incomplete_subtree_is_not_deleted() {
        let mut memory = MemoryTransport::default();
        let bundle = memory.mkdir(1, 0, "bundle".into()).await.unwrap();
        memory
            .mkdir(1, bundle, "invalid/name".into())
            .await
            .unwrap();
        let device = Device::from_transport(memory);
        assert!(device.list(1, "/bundle").await.unwrap().is_empty());
        assert!(matches!(
            device.delete(1, "/bundle").await,
            Err(RemtpError::Protocol { message }) if message.contains("listing for /bundle is incomplete")
        ));
        assert!(device.stat(1, "/bundle").await.is_ok());
        device.close().await;
    }

    #[tokio::test]
    async fn timeout_during_recursive_delete_disconnects_session() {
        let mut memory = bundle(30).await;
        memory.hook = Some(Box::new(|op| {
            if matches!(op, MemoryOp::Delete("file-002")) {
                return Err(mtp_error(mtp_rs::Error::Timeout, "file-002"));
            }
            Ok(())
        }));
        let device = Device::from_transport(memory);
        let error = device.delete(1, "/bundle").await.unwrap_err();
        assert!(error.to_string().contains("reopen the device"));
        assert!(matches!(
            device.list(1, "/").await,
            Err(RemtpError::Disconnected)
        ));
        device.close().await;
    }

    async fn camera_roll() -> (MemoryTransport, Handle) {
        let mut memory = MemoryTransport::default();
        let dcim = memory.mkdir(1, 0, "DCIM".into()).await.unwrap();
        memory.mkdir(1, dcim, "Edited.jpg".into()).await.unwrap();
        for (name, bytes) in [
            ("IMG_1.JPG", &b"jpeg"[..]),
            ("notes.txt", b"text"),
            ("VID_1.mp4", b""),
        ] {
            memory
                .upload(Upload {
                    storage: 1,
                    parent: dcim,
                    entry: Entry {
                        name: name.into(),
                        is_dir: false,
                        size: bytes.len() as u64,
                        modified: Some(1),
                    },
                    data: stream::iter([Ok(bytes::Bytes::from_static(bytes))]).boxed(),
                    cancel: CancelToken::new(),
                })
                .await
                .unwrap();
        }
        (memory, dcim)
    }

    #[tokio::test]
    async fn thumbnails_use_the_cached_tree_and_only_ask_for_images_and_videos() {
        let (mut memory, _) = camera_roll().await;
        let log = Arc::new(StdMutex::new(Vec::new()));
        let observed = log.clone();
        memory.hook = Some(Box::new(move |op| {
            match op {
                MemoryOp::List(handle) => observed.lock().unwrap().push(format!("list {handle}")),
                MemoryOp::Thumbnail(name) => observed.lock().unwrap().push(name.to_owned()),
                _ => {}
            }
            Ok(())
        }));
        let device = Device::from_transport(memory);
        device.list(1, "/DCIM").await.unwrap();
        log.lock().unwrap().clear();
        let thumbnail = |path: &'static str| device.thumbnail(1, path);
        assert_eq!(
            thumbnail("/DCIM/IMG_1.JPG").await.unwrap().unwrap(),
            b"jpeg"
        );
        assert_eq!(thumbnail("/DCIM/VID_1.mp4").await.unwrap(), None);
        assert_eq!(thumbnail("/DCIM/notes.txt").await.unwrap(), None);
        assert_eq!(thumbnail("/DCIM/Edited.jpg").await.unwrap(), None);
        assert!(matches!(
            thumbnail("/DCIM/gone.jpg").await,
            Err(RemtpError::NotFound { .. })
        ));
        assert_eq!(*log.lock().unwrap(), ["IMG_1.JPG", "VID_1.mp4"]);
        device.close().await;
    }

    #[tokio::test]
    async fn stale_thumbnail_handle_relists_the_folder_once() {
        let (mut memory, dcim) = camera_roll().await;
        let log = Arc::new(StdMutex::new(Vec::new()));
        let observed = log.clone();
        let mut stale = true;
        memory.hook = Some(Box::new(move |op| {
            match op {
                MemoryOp::List(handle) => observed.lock().unwrap().push(format!("list {handle}")),
                MemoryOp::Thumbnail(name) => {
                    observed.lock().unwrap().push(name.to_owned());
                    if std::mem::take(&mut stale) {
                        return Err(RemtpError::StaleHandle);
                    }
                }
                _ => {}
            }
            Ok(())
        }));
        let device = Device::from_transport(memory);
        device.list(1, "/DCIM").await.unwrap();
        log.lock().unwrap().clear();
        assert_eq!(
            device
                .thumbnail(1, "/DCIM/IMG_1.JPG")
                .await
                .unwrap()
                .unwrap(),
            b"jpeg"
        );
        assert_eq!(
            *log.lock().unwrap(),
            [
                "IMG_1.JPG".into(),
                format!("list {dcim}"),
                "IMG_1.JPG".into()
            ]
        );
        device.close().await;
    }

    #[test]
    fn thumbnails_are_for_images_and_videos() {
        for path in ["/DCIM/IMG_1.HEIC", "/a/b.jpeg", "/VID.Mp4", "/raw.dng"] {
            assert!(has_thumbnail(path), "{path}");
        }
        for path in ["/", "/DCIM", "/.jpg", "/notes.txt", "/jpg", "/song.flac"] {
            assert!(!has_thumbnail(path), "{path}");
        }
    }

    #[tokio::test]
    async fn events_never_insert_invalid_names() {
        let mut memory = MemoryTransport::default();
        let valid = memory.mkdir(1, 0, "valid".into()).await.unwrap();
        let invalid = memory.mkdir(1, 0, "not/a/component".into()).await.unwrap();
        let device = Device::from_transport(memory);
        assert_eq!(device.list(1, "/").await.unwrap().len(), 1);
        device
            .call(move |session| {
                async move {
                    session.event(Event::Added(invalid)).await;
                    assert!(session.tree(1).path(invalid).is_none());
                    session.transport.rename(1, valid, "..".into()).await?;
                    session.event(Event::Changed(valid)).await;
                    assert!(session.tree(1).path(valid).is_none());
                    Ok(())
                }
                .boxed()
            })
            .await
            .unwrap();
        assert!(device.list(1, "/").await.unwrap().is_empty());
        device.close().await;
    }
}
