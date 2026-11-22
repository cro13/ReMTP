use std::collections::{HashMap, HashSet};
use std::io::{self, ErrorKind};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
use std::time::{SystemTime, UNIX_EPOCH};

use futures::FutureExt;
use mtp_rs::CancelToken;
use tokio::fs;
use tokio::sync::Mutex;

use super::journal::{DeviceJournal, Journal};
use super::platform;
use crate::{Device, Entry, RemtpError, Result, names, tree};

const TEMP: &str = ".remtp-tmp-";
const BACKUP: &str = ".remtp-bak-";
static STAMP: AtomicU64 = AtomicU64::new(0);
pub(super) static LOCAL_WORK: Mutex<()> = Mutex::const_new(());

pub(super) struct WorkNames {
    pub temp: String,
    pub backup: String,
}

impl WorkNames {
    pub fn new(name: &str) -> Self {
        let id = work_id();
        let mut temp = format!("{TEMP}{id}");
        if let Some((_, extension)) = name.rsplit_once('.')
            && !extension.is_empty()
            && extension.len() <= 32
        {
            temp.push('.');
            temp.push_str(extension);
        }
        Self {
            temp,
            backup: format!("{BACKUP}{id}-{name}"),
        }
    }

    pub fn check_backup(&self, units: usize, bytes: usize) -> Result<()> {
        if self.backup.encode_utf16().count() > units || self.backup.len() > bytes {
            return Err(RemtpError::Io {
                message: "filename is too long to back up safely".into(),
            });
        }
        Ok(())
    }
}

pub(super) fn work_id() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos() as u64;
    let previous = STAMP
        .fetch_update(Relaxed, Relaxed, |old| Some(now.max(old + 1)))
        .unwrap();
    format!("{:08x}{:016x}", std::process::id(), now.max(previous + 1))
}

enum Work<'a> {
    Temp,
    Backup(&'a str),
}

fn work(name: &str) -> Option<Work<'_>> {
    if !tree::valid_component(name) {
        return None;
    }
    let valid_id = |id: &str| id.len() == 24 && id.bytes().all(|c| c.is_ascii_hexdigit());
    if let Some(tag) = name.strip_prefix(TEMP)
        && valid_id(tag.split('.').next().unwrap())
    {
        return Some(Work::Temp);
    }
    let (id, name) = name.strip_prefix(BACKUP)?.split_once('-')?;
    if valid_id(id) && tree::valid_component(name) && !reserved_name(name) {
        Some(Work::Backup(name))
    } else {
        None
    }
}

pub(super) fn reserved_name(name: &str) -> bool {
    [TEMP, BACKUP].into_iter().any(|prefix| {
        name.get(..prefix.len())
            .is_some_and(|start| start.eq_ignore_ascii_case(prefix))
    })
}

pub(super) async fn planned_list(
    device: &Device,
    journal: DeviceJournal,
    storage: u32,
    folder: &str,
    cancel: CancelToken,
) -> Result<Vec<Entry>> {
    let folder = folder.to_owned();
    device
        .call(move |session| {
            async move {
                let mut journal = journal.open(&folder).await?;
                let leftovers = journal.names();
                if !leftovers.is_empty() {
                    session.tree(storage).invalidate(&folder);
                }
                let entries = session.list(storage, &folder, cancel.clone()).await?;
                if leftovers.is_empty() {
                    return Ok(entries);
                }
                let mut occupied: HashSet<_> = entries
                    .iter()
                    .map(|entry| names::insensitive_key(&entry.name))
                    .collect();
                for work_name in leftovers {
                    if cancel.is_cancelled() {
                        return Err(RemtpError::Cancelled);
                    }
                    let path = tree::join(&folder, &work_name);
                    let handle = session
                        .tree(storage)
                        .lookup(&path)
                        .filter(|object| !object.entry.is_dir)
                        .map(|object| object.handle);
                    match (work(&work_name), handle) {
                        (Some(Work::Temp), Some(handle)) => {
                            session.delete_known(storage, &path, handle).await?;
                        }
                        (Some(Work::Backup(name)), Some(handle)) => {
                            if !occupied.insert(names::insensitive_key(name)) {
                                continue;
                            }
                            session.rename_known(storage, &path, handle, name).await?;
                        }
                        _ => {}
                    }
                    journal.forget(&work_name).await?;
                }
                Ok(session.tree(storage).entries(&folder))
            }
            .boxed()
        })
        .await
}

pub(super) async fn local_folder(root: &Path, folder: &Path, create: bool) -> io::Result<()> {
    let root = root.to_owned();
    let folder = folder.to_owned();
    tokio::task::spawn_blocking(move || check_local_folder(&root, &folder, create))
        .await
        .map_err(io::Error::other)?
}

pub(super) fn check_local_folder(root: &Path, folder: &Path, create: bool) -> io::Result<()> {
    let relative = folder.strip_prefix(root).map_err(io::Error::other)?;
    if create {
        std::fs::create_dir_all(root)?;
    }
    if !std::fs::metadata(root)?.is_dir() {
        return Err(io::Error::other(format!(
            "not a destination directory: {}",
            root.display()
        )));
    }
    let mut path = root.to_path_buf();
    for component in relative.components() {
        let Component::Normal(name) = component else {
            return Err(io::Error::other("invalid destination folder component"));
        };
        path.push(name);
        let metadata = match std::fs::symlink_metadata(&path) {
            Err(error) if create && error.kind() == ErrorKind::NotFound => {
                match std::fs::create_dir(&path) {
                    Ok(()) => {}
                    Err(error) if error.kind() == ErrorKind::AlreadyExists => {}
                    Err(error) => return Err(error),
                }
                std::fs::symlink_metadata(&path)?
            }
            result => result?,
        };
        check_directory(&path, &metadata)?;
    }
    Ok(())
}

fn check_directory(path: &Path, metadata: &std::fs::Metadata) -> io::Result<()> {
    if !metadata.is_dir() || is_link(metadata) {
        return Err(io::Error::other(format!(
            "not a real destination directory: {}",
            path.display()
        )));
    }
    Ok(())
}

pub(super) fn is_link(metadata: &std::fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
        metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
    }
    #[cfg(not(windows))]
    metadata.file_type().is_symlink()
}

pub(super) async fn local_listing(
    root: &Path,
    folder: &Path,
    cancel: &CancelToken,
) -> Result<HashMap<String, std::fs::Metadata>> {
    let _guard = LOCAL_WORK.lock().await;
    match local_folder(root, folder, false).await {
        Err(error) if error.kind() == ErrorKind::NotFound => {
            return Err(RemtpError::NotFound {
                path: folder.display().to_string(),
            });
        }
        result => result?,
    }
    let mut journal = Journal::local(folder).await?;
    let mut list = fs::read_dir(folder).await?;
    let mut entries = HashMap::new();
    while let Some(entry) = list.next_entry().await? {
        let Ok(name) = entry.file_name().into_string() else {
            continue;
        };
        let meta = fs::symlink_metadata(entry.path()).await?;
        entries.insert(name, meta);
    }
    let mut occupied: HashSet<_> = entries
        .keys()
        .map(|name| names::insensitive_key(name))
        .collect();
    for work_name in journal.names() {
        if cancel.is_cancelled() {
            return Err(RemtpError::Cancelled);
        }
        local_folder(root, folder, false).await?;
        let path = folder.join(&work_name);
        if entries
            .get(&work_name)
            .is_some_and(|meta| meta.is_file() && !is_link(meta))
        {
            match work(&work_name) {
                Some(Work::Temp) => {
                    fs::remove_file(path).await?;
                    entries.remove(&work_name);
                }
                Some(Work::Backup(name)) if local_name(name) => {
                    if !occupied.insert(names::insensitive_key(name)) {
                        continue;
                    }
                    move_noclobber(&path, &folder.join(name)).await?;
                    let meta = entries.remove(&work_name).unwrap();
                    entries.insert(name.into(), meta);
                }
                _ => {}
            }
        }
        journal.forget(&work_name).await?;
    }
    Ok(entries)
}

pub(super) fn local_name(name: &str) -> bool {
    if !tree::valid_component(name) {
        return false;
    }
    #[cfg(windows)]
    {
        if name.ends_with(['.', ' ']) || name.chars().any(names::unsafe_char) {
            return false;
        }
        let stem = name
            .split('.')
            .next()
            .unwrap()
            .trim_end()
            .to_ascii_uppercase();
        if matches!(
            stem.as_str(),
            "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$"
        ) || stem
            .strip_prefix("COM")
            .or_else(|| stem.strip_prefix("LPT"))
            .is_some_and(|n| {
                matches!(
                    n,
                    "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" | "¹" | "²" | "³"
                )
            })
        {
            return false;
        }
    }
    true
}

pub(super) fn move_noclobber_sync(source: &Path, target: &Path) -> Result<()> {
    match platform::rename_exclusive(source, target) {
        Err(error) if error.kind() == ErrorKind::AlreadyExists => Err(RemtpError::AlreadyExists {
            path: target.display().to_string(),
        }),
        result => Ok(result?),
    }
}

pub(super) async fn move_noclobber(source: &Path, target: &Path) -> Result<()> {
    let source = source.to_owned();
    let target = target.to_owned();
    tokio::task::spawn_blocking(move || move_noclobber_sync(&source, &target))
        .await
        .map_err(io::Error::other)?
}

pub(super) struct LocalTemp<'a> {
    root: &'a Path,
    path: Option<PathBuf>,
}

impl<'a> LocalTemp<'a> {
    pub fn new(root: &'a Path, path: PathBuf) -> Self {
        Self {
            root,
            path: Some(path),
        }
    }

    pub fn disarm(&mut self) {
        self.path = None;
    }

    pub fn remove_sync(&mut self) -> Result<()> {
        if let Some(path) = &self.path {
            check_local_folder(self.root, path.parent().unwrap(), false)?;
            match std::fs::remove_file(path) {
                Ok(()) => {}
                Err(error) if error.kind() == ErrorKind::NotFound => {}
                Err(error) => return Err(error.into()),
            }
            self.disarm();
        }
        Ok(())
    }
}

impl Drop for LocalTemp<'_> {
    fn drop(&mut self) {
        let Some(path) = &self.path else { return };
        let result = check_local_folder(self.root, path.parent().unwrap(), false)
            .and_then(|()| std::fs::remove_file(path));
        if let Err(error) = result
            && error.kind() != ErrorKind::NotFound
        {
            eprintln!("ReMTP: could not remove {}: {error}", path.display());
        }
    }
}
