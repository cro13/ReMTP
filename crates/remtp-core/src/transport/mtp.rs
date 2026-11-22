use std::collections::HashMap;
use std::ops::ControlFlow;
use std::time::{Duration, Instant};

use futures::{FutureExt, StreamExt, future::BoxFuture, stream::BoxStream};
use mtp_rs::mtp::{
    Backend, DateTime, DeviceEvent, DownloadPacing, MtpDevice, MtpDeviceInfo, NewObjectInfo,
    ObjectHandle, ObjectInfo, Storage, StorageId, StorageType, UtcOffset,
};
use mtp_rs::ptp::{PropertyDataType, PropertyValue, PtpDevice, PtpError};
use mtp_rs::{ByteRange, CancelToken, Error, UsbSpeed};

use super::{Download, Event, Handle, Listing, Object, Transport, Upload};
use crate::{
    AccessState, DeviceDetails, DeviceSummary, Entry, RemtpError, Result, StorageInfo, access,
};

pub struct MtpTransport {
    device: MtpDevice,
    summary: DeviceSummary,
    speed: Option<UsbSpeed>,
    download_rate: Option<f64>,
    storages: HashMap<u32, Storage>,
    ids: HashMap<StorageId, u32>,
    unusable: bool,
}

pub(crate) fn device_summary(info: &MtpDeviceInfo, id: String) -> DeviceSummary {
    let serial = info.serial_number.clone().unwrap_or_default();
    let name = display_name(
        None,
        "",
        info.product.as_deref().unwrap_or_default(),
        &serial,
    )
    .unwrap_or_else(|| format!("MTP device {:04x}:{:04x}", info.vendor_id, info.product_id));
    DeviceSummary {
        id,
        manufacturer: info.manufacturer.clone().unwrap_or_default(),
        model: String::new(),
        name,
        serial,
    }
}

fn clean_device_name(name: &str, serial: &str) -> String {
    let name = name.split_whitespace().collect::<Vec<_>>().join(" ");
    let lower = name.to_ascii_lowercase();
    if let Some((base, suffix)) = lower
        .strip_suffix(')')
        .and_then(|name| name.rsplit_once(" ("))
        && (suffix.trim().eq_ignore_ascii_case(serial)
            || suffix
                .split(|c: char| !c.is_ascii_alphanumeric())
                .any(|word| matches!(word, "serial" | "sn")))
    {
        return name[..base.len()].trim_end().into();
    }
    if let Some((base, suffix)) = lower.rsplit_once("sn:")
        && (base.is_empty() || base.ends_with([' ', '_']))
        && !suffix.trim().is_empty()
        && suffix
            .trim()
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_'))
    {
        return name[..base.len()].trim_end_matches([' ', '_']).into();
    }
    name
}

fn display_name(
    friendly: Option<&str>,
    model: &str,
    usb_product: &str,
    serial: &str,
) -> Option<String> {
    friendly
        .into_iter()
        .chain([model, usb_product])
        .map(|name| clean_device_name(name, serial))
        .find(|name| !name.is_empty())
}

async fn read_friendly_name(location: u64) -> Option<String> {
    const DEVICE_FRIENDLY_NAME: u16 = 0xD402;
    let device = PtpDevice::open_by_location_with_timeout(location, Duration::from_secs(2))
        .await
        .ok()?;
    let info = device.get_device_info().await.ok()?;
    if !info
        .device_properties_supported
        .contains(&DEVICE_FRIENDLY_NAME)
    {
        return None;
    }
    let session = device.open_session().await.ok()?;
    let name = session
        .get_device_prop_value_typed(DEVICE_FRIENDLY_NAME.into(), PropertyDataType::String)
        .await;
    if !matches!(name, Err(PtpError::Timeout)) {
        let _ = session.close().await;
    }
    match name {
        Ok(PropertyValue::String(name)) => Some(name),
        _ => None,
    }
}

pub(crate) fn mtp_error(error: Error, path: &str) -> RemtpError {
    if error.is_exclusive_access() {
        return RemtpError::DeviceBusy {
            holder: "another process".into(),
        };
    }
    match error {
        Error::NoDevice => RemtpError::NoDevice,
        Error::Disconnected | Error::DeviceReset => RemtpError::Disconnected,
        Error::Timeout => RemtpError::MtpTimeout,
        Error::Cancelled => RemtpError::Cancelled,
        Error::NotFound => RemtpError::NotFound { path: path.into() },
        Error::AlreadyExists => RemtpError::AlreadyExists { path: path.into() },
        Error::Io { message } => RemtpError::Io { message },
        Error::StorageFull => RemtpError::NoSpace,
        Error::StaleHandle => RemtpError::StaleHandle,
        _ => RemtpError::Protocol {
            message: error.to_string(),
        },
    }
}

impl MtpTransport {
    pub(crate) async fn open(
        info: &MtpDeviceInfo,
        summary: DeviceSummary,
        cached: bool,
        backend: Backend,
    ) -> Result<Self> {
        let friendly = if cached {
            Some(summary.name.clone())
        } else {
            read_friendly_name(info.location_id).await
        };
        let device = MtpDevice::builder()
            .backend(backend)
            .timeout(Duration::from_secs(60))
            .use_object_prop_list(true)
            .open_by_location(info.location_id)
            .await
            .map_err(|e| {
                if e.is_exclusive_access()
                    && let AccessState::HeldBy { process, .. } = access::state(info)
                {
                    return RemtpError::DeviceBusy { holder: process };
                }
                mtp_error(e, &summary.id)
            })?;
        Ok(Self::with_name(
            device,
            summary,
            info.speed,
            friendly.as_deref(),
        ))
    }

    pub fn new(device: MtpDevice, summary: DeviceSummary, speed: Option<UsbSpeed>) -> Self {
        Self::with_name(device, summary, speed, None)
    }

    fn with_name(
        device: MtpDevice,
        mut summary: DeviceSummary,
        speed: Option<UsbSpeed>,
        friendly: Option<&str>,
    ) -> Self {
        let info = device.device_info();
        if !info.manufacturer.is_empty() {
            summary.manufacturer.clone_from(&info.manufacturer);
        }
        summary.model.clone_from(&info.model);
        if !info.serial_number.is_empty() {
            summary.serial.clone_from(&info.serial_number);
        }
        if let Some(name) = display_name(friendly, &summary.model, &summary.name, &summary.serial) {
            summary.name = name;
        }
        Self {
            device,
            summary,
            speed,
            download_rate: None,
            storages: HashMap::new(),
            ids: HashMap::new(),
            unusable: false,
        }
    }

    pub(crate) fn summary(&self) -> &DeviceSummary {
        &self.summary
    }

    fn check_session(&self) -> Result<()> {
        if self.unusable {
            Err(RemtpError::Disconnected)
        } else {
            Ok(())
        }
    }

    fn observe<T>(&mut self, result: Result<T>) -> Result<T> {
        self.unusable |= result.as_ref().is_err_and(RemtpError::is_disconnected);
        result
    }

    fn map_operation<T>(&mut self, result: std::result::Result<T, Error>, path: &str) -> Result<T> {
        self.observe(result.map_err(|error| mtp_error(error, path)))
    }

    async fn refresh(&mut self) -> Result<Vec<StorageInfo>> {
        self.check_session()?;
        let storages = self.device.storages().await;
        let storages = self.map_operation(storages, "/")?;
        self.storages.clear();
        Ok(storages
            .into_iter()
            .map(|storage| {
                let opaque = storage.id();
                let id = match self.ids.get(&opaque) {
                    Some(id) => *id,
                    None => {
                        let unused = |id| !self.ids.values().any(|used| *used == id);
                        let id = u32::try_from(opaque.0)
                            .ok()
                            .filter(|&id| unused(id))
                            .unwrap_or_else(|| {
                                (1..=u32::MAX).rev().find(|&id| unused(id)).unwrap()
                            });
                        self.ids.insert(opaque, id);
                        id
                    }
                };
                let info = storage.info();
                let result = StorageInfo {
                    id,
                    description: info.description.clone(),
                    capacity_bytes: info.total_capacity,
                    free_bytes: info.free_space,
                    removable: matches!(
                        info.storage_type,
                        StorageType::RemovableRom | StorageType::RemovableRam
                    ),
                };
                self.storages.insert(id, storage);
                result
            })
            .collect())
    }

    async fn storage(&mut self, id: u32) -> Result<&Storage> {
        self.check_session()?;
        if !self.storages.contains_key(&id) {
            self.refresh().await?;
        }
        self.storages.get(&id).ok_or_else(|| RemtpError::NotFound {
            path: format!("storage {id}"),
        })
    }

    fn download_pacing(&self, size: u64) -> DownloadPacing {
        choose_download_pacing(self.speed, self.download_rate, size)
    }

    fn record_download_rate(&mut self, bytes: u64, elapsed: Duration) {
        if bytes < 1024 * 1024 || elapsed.is_zero() {
            return;
        }
        let rate = bytes as f64 / elapsed.as_secs_f64();
        self.download_rate = Some(self.download_rate.map_or(rate, |old| (old + rate) / 2.0));
    }
}

fn choose_download_pacing(
    speed: Option<UsbSpeed>,
    measured_rate: Option<f64>,
    size: u64,
) -> DownloadPacing {
    const TARGET_SECS: f64 = 2.0;
    const MIB: u64 = 1024 * 1024;
    const MIN_WINDOW: u64 = 8 * MIB;
    const MAX_WINDOW: u64 = 256 * MIB;
    let fallback_rate = match speed {
        Some(UsbSpeed::Super | UsbSpeed::SuperPlus) => 120_000_000.0,
        Some(UsbSpeed::High) => 35_000_000.0,
        Some(UsbSpeed::Full) => 1_000_000.0,
        Some(UsbSpeed::Low) => 100_000.0,
        _ => 35_000_000.0,
    };
    let rate = measured_rate.unwrap_or(fallback_rate);
    let target = ((rate * TARGET_SECS) as u64).clamp(MIN_WINDOW, MAX_WINDOW);
    if size <= target {
        DownloadPacing::HeldOpen
    } else if measured_rate.is_some() {
        let window = ((target / MIB) * MIB).clamp(MIN_WINDOW, MAX_WINDOW);
        DownloadPacing::FixedWindow(window as u32)
    } else {
        DownloadPacing::default()
    }
}

fn object(info: ObjectInfo, storage: u32) -> Object {
    let is_dir = info.is_folder();
    Object {
        handle: info.handle.0,
        parent: info.parent.0,
        storage,
        entry: Entry {
            name: info.filename,
            is_dir,
            size: info.size,
            modified: info.modified.and_then(|date| date.to_unix_seconds()),
        },
    }
}

fn parent_handle(parent: Handle) -> Option<ObjectHandle> {
    (parent != 0).then_some(ObjectHandle(parent))
}

impl Transport for MtpTransport {
    fn details(&mut self) -> BoxFuture<'_, Result<DeviceDetails>> {
        async {
            let storages = self.refresh().await?;
            let speed = match self.speed {
                Some(UsbSpeed::Low) => Some(("USB 1.0", 1)),
                Some(UsbSpeed::Full) => Some(("USB 1.1", 12)),
                Some(UsbSpeed::High) => Some(("USB 2.0", 480)),
                Some(UsbSpeed::Super) => Some(("USB 3.2 Gen 1", 5000)),
                Some(UsbSpeed::SuperPlus) => Some(("USB 3.2 Gen 2", 10000)),
                _ => None,
            };
            Ok(DeviceDetails {
                summary: self.summary.clone(),
                link_speed: speed.map(|(name, _)| name.into()),
                link_speed_mbps: speed.map(|(_, mbps)| mbps),
                storages,
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
            Ok(self
                .list_with_completeness(storage, parent, cancel)
                .await?
                .objects)
        }
        .boxed()
    }

    fn list_with_completeness(
        &mut self,
        storage: u32,
        parent: Handle,
        cancel: CancelToken,
    ) -> BoxFuture<'_, Result<Listing>> {
        async move {
            let entries = self
                .storage(storage)
                .await?
                .collect_objects_with_cancel(parent_handle(parent), Some(&cancel))
                .await;
            let entries = self.map_operation(entries, &parent.to_string())?;
            Ok(Listing {
                objects: entries
                    .objects
                    .into_iter()
                    .map(|info| object(info, storage))
                    .collect(),
                complete: entries.skipped.is_empty(),
            })
        }
        .boxed()
    }

    fn stat(&mut self, handle: Handle) -> BoxFuture<'_, Result<Object>> {
        async move {
            self.check_session()?;
            if self.storages.is_empty() {
                self.refresh().await?;
            }
            let storage = self
                .storages
                .values()
                .next()
                .ok_or_else(|| RemtpError::NotFound { path: "/".into() })?;
            let info = storage.get_object_info(ObjectHandle(handle)).await;
            let info = self.map_operation(info, &handle.to_string())?;
            let id =
                self.ids
                    .get(&info.storage_id)
                    .copied()
                    .ok_or_else(|| RemtpError::NotFound {
                        path: "storage".into(),
                    })?;
            Ok(object(info, id))
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
            let result = self
                .storage(storage)
                .await?
                .create_folder(parent_handle(parent), &name)
                .await;
            self.map_operation(result, &name).map(|handle| handle.0)
        }
        .boxed()
    }

    fn delete(&mut self, storage: u32, handle: Handle) -> BoxFuture<'_, Result<()>> {
        async move {
            let result = self
                .storage(storage)
                .await?
                .delete(ObjectHandle(handle))
                .await;
            self.map_operation(result, &handle.to_string())
        }
        .boxed()
    }

    fn rename(&mut self, storage: u32, handle: Handle, name: String) -> BoxFuture<'_, Result<()>> {
        async move {
            let result = self
                .storage(storage)
                .await?
                .rename(ObjectHandle(handle), &name)
                .await;
            self.map_operation(result, &name)
        }
        .boxed()
    }

    fn upload(&mut self, request: Upload) -> BoxFuture<'_, Result<Handle>> {
        async move {
            let Upload {
                storage,
                parent,
                entry,
                data,
                cancel,
            } = request;
            if cancel.is_cancelled() {
                return Err(RemtpError::Cancelled);
            }
            let mut info = NewObjectInfo::file(&entry.name, entry.size);
            info.modified = entry
                .modified
                .and_then(|date| DateTime::from_unix_seconds(date, UtcOffset::UTC));
            let sent = self
                .storage(storage)
                .await?
                .upload_with_progress(parent_handle(parent), info, data, |_| {
                    if cancel.is_cancelled() {
                        ControlFlow::Break(())
                    } else {
                        ControlFlow::Continue(())
                    }
                })
                .await;
            match sent {
                Ok(handle) => Ok(handle.0),
                Err(error) => {
                    let mut mapped = mtp_error(error.source, &entry.name);
                    if mapped.is_disconnected() {
                        self.unusable = true;
                        return Err(mapped);
                    }
                    if cancel.is_cancelled() {
                        mapped = RemtpError::Cancelled;
                    }
                    if let Some(handle) = error.partial {
                        let cleanup = self.storage(storage).await?.delete(handle).await;
                        mapped = mapped.with_cleanup(
                            "could not delete the partial upload",
                            self.map_operation(cleanup, &entry.name),
                        );
                    }
                    Err(mapped)
                }
            }
        }
        .boxed()
    }

    fn download(&mut self, request: Download) -> BoxFuture<'_, Result<()>> {
        async move {
            let Download {
                storage,
                handle,
                size,
                mut sink,
                progress,
                cancel,
            } = request;
            if cancel.is_cancelled() {
                return Err(RemtpError::Cancelled);
            }
            let path = handle.to_string();
            let pacing = self.download_pacing(size);
            let download = self
                .storage(storage)
                .await?
                .download_with_pacing(ObjectHandle(handle), ByteRange::Full, pacing)
                .await;
            let mut download = self.map_operation(download, &path)?;
            let mut received = 0u64;
            let mut usb_time = Duration::ZERO;
            let mut sink_error = None;
            let mut read_error = None;
            loop {
                if cancel.is_cancelled() {
                    break;
                }
                let started = Instant::now();
                let next = download.next_chunk().await;
                usb_time += started.elapsed();
                let Some(chunk) = next else {
                    if let Err(error) = sink.flush().await {
                        return self.observe(Err(error));
                    }
                    self.record_download_rate(received, usb_time);
                    return Ok(());
                };
                let chunk = match chunk {
                    Ok(chunk) => chunk,
                    Err(error) => {
                        read_error = Some(mtp_error(error, &path));
                        break;
                    }
                };
                let len = chunk.len() as u64;
                received += len;
                if let Err(error) = sink.write_chunk(chunk).await {
                    sink_error = Some(error);
                    break;
                }
                progress(len);
            }
            if let Some(error) = read_error {
                return self.observe(Err(error));
            }
            let stopped = download
                .cancel(Duration::from_secs(2))
                .await
                .map_err(|e| mtp_error(e, &path));
            let outcome = if let Some(error) = sink_error {
                Err(error.with_cleanup("USB download also failed", stopped))
            } else if cancel.is_cancelled() {
                Err(RemtpError::Cancelled.with_cleanup("could not cancel the download", stopped))
            } else {
                stopped
            };
            self.observe(outcome)
        }
        .boxed()
    }

    fn thumbnail(
        &mut self,
        storage: u32,
        handle: Handle,
    ) -> BoxFuture<'_, Result<Option<Vec<u8>>>> {
        async move {
            self.check_session()?;
            if !self.device.capabilities().supports_thumbnails {
                return Ok(None);
            }
            let result = self
                .storage(storage)
                .await?
                .thumbnail(ObjectHandle(handle))
                .await;
            match result {
                Ok(bytes) => Ok(Some(bytes).filter(|bytes| !bytes.is_empty())),
                Err(Error::Unsupported | Error::NotFound | Error::Other { .. }) => Ok(None),
                Err(error) => self.map_operation(Err(error), &handle.to_string()),
            }
        }
        .boxed()
    }

    fn events(&self) -> BoxStream<'static, Event> {
        futures::stream::unfold(self.device.clone(), |device| async move {
            loop {
                let event = match device.next_event().await {
                    Ok(DeviceEvent::ObjectAdded { handle }) => Event::Added(handle.0),
                    Ok(DeviceEvent::ObjectRemoved { handle }) => Event::Removed(handle.0),
                    Ok(DeviceEvent::ObjectInfoChanged { handle }) => Event::Changed(handle.0),
                    Ok(DeviceEvent::StoreRemoved { .. } | DeviceEvent::StoreAdded { .. }) => {
                        Event::StoragesChanged
                    }
                    Ok(DeviceEvent::DeviceReset) => Event::Reset,
                    Ok(_) => continue,
                    Err(Error::Disconnected | Error::DeviceReset) => Event::Disconnected,
                    Err(_) => return None,
                };
                return Some((event, device));
            }
        })
        .boxed()
    }

    fn close(self: Box<Self>) -> BoxFuture<'static, ()> {
        async move {
            if !self.unusable {
                let _ = self.device.close().await;
            }
        }
        .boxed()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cleans_device_names() {
        assert_eq!(
            clean_device_name("TRINKET-IOT-IDP _SN:10000001", ""),
            "TRINKET-IOT-IDP"
        );
        assert_eq!(
            clean_device_name("  My   player SN:abc12345  ", ""),
            "My player"
        );
        assert_eq!(
            clean_device_name("Player (Serial Number: ABC12345)", ""),
            "Player"
        );
        assert_eq!(clean_device_name("Player (ABC12345)", "ABC12345"), "Player");
        assert_eq!(
            clean_device_name("Player (Second Edition)", ""),
            "Player (Second Edition)"
        );
    }

    #[test]
    fn name_prefers_friendly_then_model_then_usb_product() {
        let model = " SP3000   _SN:10000001 ";
        let usb_product = "TRINKET-IOT-IDP _SN:10000001";
        assert_eq!(
            display_name(Some(" My   Player "), model, usb_product, "").as_deref(),
            Some("My Player")
        );
        assert_eq!(
            display_name(Some(" "), model, usb_product, "").as_deref(),
            Some("SP3000")
        );
        assert_eq!(
            display_name(None, "", usb_product, "").as_deref(),
            Some("TRINKET-IOT-IDP")
        );
    }

    #[test]
    fn download_pacing_uses_held_open_under_cancel_window() {
        assert_eq!(
            choose_download_pacing(Some(UsbSpeed::Super), None, 30_000_000),
            DownloadPacing::HeldOpen
        );
        assert_eq!(
            choose_download_pacing(Some(UsbSpeed::High), None, 30_000_000),
            DownloadPacing::HeldOpen
        );
        assert_eq!(
            choose_download_pacing(Some(UsbSpeed::Super), Some(150_000_000.0), 1_500_000_000),
            DownloadPacing::FixedWindow(256 * 1024 * 1024)
        );
        assert_eq!(
            choose_download_pacing(Some(UsbSpeed::High), None, 1_500_000_000),
            DownloadPacing::default()
        );
    }
}
