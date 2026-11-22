use std::collections::BTreeSet;
use std::fs::{self, File, OpenOptions};
use std::io::{self, ErrorKind, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use sha2::{Digest, Sha256};

use super::platform;
use crate::Result;

#[derive(Clone)]
pub(super) struct DeviceJournal(String);

impl DeviceJournal {
    pub fn new(serial: &str, storage: u32) -> Self {
        let key = if serial.is_empty() {
            format!("anonymous-{}", super::staging::work_id())
        } else {
            hex(&Sha256::digest(serial.as_bytes()))
        };
        Self(format!("device-{key}-{storage:08x}"))
    }

    pub async fn open(self, folder: &str) -> Result<Journal> {
        let folder = hex(&Sha256::digest(folder.as_bytes()));
        blocking(move || Journal::open(&self.0, folder)).await
    }
}

pub(super) struct Journal {
    path: PathBuf,
    lock: Arc<File>,
    folder: String,
    records: BTreeSet<String>,
    dirty: bool,
}

impl Journal {
    pub fn local_sync(folder: &Path) -> io::Result<Self> {
        let folder = folder.canonicalize()?;
        let volume = hex(&Sha256::digest(platform::volume(&folder)?.as_bytes()));
        let folder = hex(&Sha256::digest(folder.as_os_str().as_encoded_bytes()));
        Self::open(&format!("local-{volume}"), folder)
    }

    pub async fn local(folder: &Path) -> Result<Self> {
        let folder = folder.to_owned();
        blocking(move || Self::local_sync(&folder)).await
    }

    fn open(key: &str, folder: String) -> io::Result<Self> {
        let dir = journal_dir();
        prepare_dir(&dir)?;
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(dir.join(format!("{key}.lock")))?;
        lock.lock()?;
        let path = dir.join(format!("{key}.json"));
        let records = match fs::read_to_string(&path) {
            Ok(json) => parse(&json)?,
            Err(error) if error.kind() == ErrorKind::NotFound => BTreeSet::new(),
            Err(error) => return Err(error),
        };
        Ok(Self {
            path,
            lock: Arc::new(lock),
            folder,
            records,
            dirty: false,
        })
    }

    pub fn names(&self) -> Vec<String> {
        let prefix = format!("{}:", self.folder);
        self.records
            .range(prefix.clone()..)
            .take_while(|record| record.starts_with(&prefix))
            .filter_map(|record| unhex(&record[prefix.len()..]))
            .collect()
    }

    pub fn remember_sync(&mut self, name: &str) -> Result<()> {
        let record = format!("{}:{}", self.folder, hex(name.as_bytes()));
        if !self.records.insert(record.clone()) {
            return Err(
                io::Error::new(ErrorKind::AlreadyExists, "work name already journaled").into(),
            );
        }
        if let Err(error) = self.save_sync(true) {
            self.records.remove(&record);
            return Err(error.into());
        }
        self.dirty = false;
        Ok(())
    }

    pub fn forget_sync(&mut self, name: &str) -> Result<()> {
        let record = format!("{}:{}", self.folder, hex(name.as_bytes()));
        if self.records.remove(&record) {
            if let Err(error) = self.save_sync(false) {
                self.records.insert(record);
                return Err(error.into());
            }
            self.dirty = false;
        }
        Ok(())
    }

    /// Removes `name` from the in-memory journal without writing to disk immediately; the removal
    /// piggybacks onto the next `remember_sync`, explicit `flush_sync`, or `Drop`. Safe on crash
    /// because recovery ignores journaled names that no longer exist on disk.
    pub fn forget_deferred_sync(&mut self, name: &str) {
        let record = format!("{}:{}", self.folder, hex(name.as_bytes()));
        if self.records.remove(&record) {
            self.dirty = true;
        }
    }

    pub fn flush_sync(&mut self) -> Result<()> {
        if self.dirty {
            self.save_sync(false)?;
            self.dirty = false;
        }
        Ok(())
    }

    pub async fn remember(&mut self, name: &str) -> Result<()> {
        let record = format!("{}:{}", self.folder, hex(name.as_bytes()));
        if !self.records.insert(record.clone()) {
            return Err(
                io::Error::new(ErrorKind::AlreadyExists, "work name already journaled").into(),
            );
        }
        if let Err(error) = self.save(true).await {
            self.records.remove(&record);
            return Err(error);
        }
        self.dirty = false;
        Ok(())
    }

    pub async fn forget(&mut self, name: &str) -> Result<()> {
        let record = format!("{}:{}", self.folder, hex(name.as_bytes()));
        if self.records.remove(&record) {
            if let Err(error) = self.save(false).await {
                self.records.insert(record);
                return Err(error);
            }
            self.dirty = false;
        }
        Ok(())
    }

    fn save_sync(&self, barrier: bool) -> io::Result<()> {
        let records = self
            .records
            .iter()
            .map(|r| format!("\"{r}\""))
            .collect::<Vec<_>>();
        write_records(&self.path, &records, barrier)
    }

    async fn save(&self, barrier: bool) -> Result<()> {
        let records = self
            .records
            .iter()
            .map(|r| format!("\"{r}\""))
            .collect::<Vec<_>>();
        let path = self.path.clone();
        let lock = self.lock.clone();
        blocking(move || {
            let _lock = lock;
            write_records(&path, &records, barrier)
        })
        .await
    }
}

impl Drop for Journal {
    fn drop(&mut self) {
        if self.dirty {
            let _ = self.save_sync(false);
            self.dirty = false;
        }
    }
}

fn write_records(path: &Path, records: &[String], barrier: bool) -> io::Result<()> {
    let next = path.with_extension("next");
    let mut file = File::create(&next)?;
    writeln!(file, "[{}]", records.join(","))?;
    if barrier {
        platform::barrier_sync(&file)?;
    }
    drop(file);
    fs::rename(next, path)?;
    Ok(())
}

async fn blocking<T: Send + 'static>(
    f: impl FnOnce() -> io::Result<T> + Send + 'static,
) -> Result<T> {
    Ok(tokio::task::spawn_blocking(f)
        .await
        .map_err(io::Error::other)??)
}

fn journal_dir() -> PathBuf {
    if cfg!(test) {
        return std::env::temp_dir().join(format!("ReMTP-test-journal-{}", std::process::id()));
    }
    #[cfg(target_os = "macos")]
    if let Some(home) = std::env::home_dir().filter(|path| path.is_absolute()) {
        return home.join("Library/Application Support/ReMTP/journal");
    }
    #[cfg(windows)]
    if let Some(appdata) = absolute_env("APPDATA") {
        return appdata.join("ReMTP/journal");
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    if let Some(data) = absolute_env("XDG_DATA_HOME")
        .or_else(|| absolute_env("HOME").map(|home| home.join(".local/share")))
    {
        return data.join("ReMTP/journal");
    }
    #[cfg(unix)]
    return std::env::temp_dir().join(format!("ReMTP-journal-{}", platform::user_id()));
    #[cfg(not(unix))]
    std::env::temp_dir().join("ReMTP/journal")
}

#[cfg(any(all(unix, not(target_os = "macos")), windows))]
fn absolute_env(name: &str) -> Option<PathBuf> {
    std::env::var_os(name)
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
}

fn prepare_dir(path: &Path) -> io::Result<()> {
    fs::create_dir_all(path.parent().unwrap())?;
    let dir = fs::DirBuilder::new();
    #[cfg(unix)]
    let dir = {
        use std::os::unix::fs::DirBuilderExt;
        let mut dir = dir;
        dir.mode(0o700);
        dir
    };
    match dir.create(path) {
        Ok(()) => {}
        Err(error) if error.kind() == ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error),
    }
    let meta = path.symlink_metadata()?;
    if !meta.is_dir() || super::staging::is_link(&meta) {
        return Err(io::Error::other("journal path is not a real directory"));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if meta.uid() != platform::user_id() || meta.mode() & 0o022 != 0 {
            return Err(io::Error::other(
                "journal directory is not controlled by the current user",
            ));
        }
    }
    Ok(())
}

fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write;
    let mut text = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        write!(text, "{byte:02x}").unwrap();
    }
    text
}

fn unhex(text: &str) -> Option<String> {
    if !text.len().is_multiple_of(2) || !text.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return None;
    }
    let bytes = (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&text[i..i + 2], 16).unwrap())
        .collect();
    String::from_utf8(bytes).ok()
}

fn parse(json: &str) -> io::Result<BTreeSet<String>> {
    let invalid = || io::Error::new(ErrorKind::InvalidData, "invalid staging journal");
    let body = json
        .trim()
        .strip_prefix('[')
        .and_then(|s| s.strip_suffix(']'))
        .ok_or_else(invalid)?;
    if body.trim().is_empty() {
        return Ok(BTreeSet::new());
    }
    body.split(',')
        .map(|item| {
            let item = item
                .trim()
                .strip_prefix('"')
                .and_then(|s| s.strip_suffix('"'))
                .ok_or_else(invalid)?;
            let (folder, name) = item.split_once(':').ok_or_else(invalid)?;
            if folder.len() != 64
                || !folder.bytes().all(|b| b.is_ascii_hexdigit())
                || unhex(name).is_none()
            {
                return Err(invalid());
            }
            Ok(item.to_owned())
        })
        .collect()
}
