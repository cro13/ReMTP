use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use mtp_rs::CancelToken;
use tokio::fs;

use super::journal::DeviceJournal;
use super::staging::{is_link, local_listing, local_name, planned_list, reserved_name};
use super::{
    ConflictPolicy, Direction, IssueKind, IssueRetry, RenamedFile, TransferIssue, TransferJob,
};
use crate::{Device, Entry, RemtpError, Result, names, tree};

#[derive(Clone)]
pub(super) enum Decision {
    Copy { replace: bool },
    CheckSame,
    Ask(Box<TransferIssue>),
    Skip,
}

#[derive(Clone)]
pub(super) struct PlannedFile {
    pub source: String,
    pub target: String,
    pub size: u64,
    pub modified: Option<i64>,
    pub existing_size: Option<u64>,
    pub replaceable: bool,
    pub failure_id: u64,
    pub decision: Decision,
}

pub(super) struct Plan {
    pub files: Vec<PlannedFile>,
    pub folders: Vec<String>,
    pub renamed: Vec<RenamedFile>,
    pub issues: Vec<TransferIssue>,
    pub subtree_skipped: u32,
    pub planning: Planning,
}

#[derive(Default)]
pub(super) struct Planning {
    pub device_journal: Option<DeviceJournal>,
    next_id: u64,
    destinations: HashMap<String, HashMap<String, Destination>>,
    planned_folders: HashSet<String>,
    from_device: bool,
}

#[derive(Clone)]
struct Destination {
    name: String,
    size: u64,
    modified: Option<i64>,
    is_dir: bool,
    reserved: bool,
    special: bool,
}

impl From<Entry> for Destination {
    fn from(entry: Entry) -> Self {
        Self {
            name: entry.name,
            size: entry.size,
            modified: entry.modified,
            is_dir: entry.is_dir,
            reserved: false,
            special: false,
        }
    }
}

struct Source {
    path: String,
    entry: Entry,
}

impl Plan {
    pub async fn build(
        device: &Device,
        job: &TransferJob,
        pending_sources: Option<Vec<String>>,
        cancel: CancelToken,
    ) -> Result<Self> {
        let from_device = job.direction == Direction::FromDevice;
        let pending: Option<BTreeSet<_>> = pending_sources.map(|paths| paths.into_iter().collect());
        let separator = if from_device {
            '/'
        } else {
            std::path::MAIN_SEPARATOR
        };
        let mut space = u64::MAX;
        let mut capacity = u64::MAX;
        let mut device_journal = None;
        if !from_device {
            let details = device.details().await?;
            device_journal = Some(DeviceJournal::new(&details.summary.serial, job.storage_id));
            let info = details
                .storages
                .into_iter()
                .find(|info| info.id == job.storage_id)
                .ok_or_else(|| RemtpError::NotFound {
                    path: format!("storage {}", job.storage_id),
                })?;
            if info.free_bytes != 0 || !matches!(info.capacity_bytes, 0 | u64::MAX) {
                space = info.free_bytes;
            }
            if info.capacity_bytes != 0 {
                capacity = info.capacity_bytes;
            }
        }
        let mut plan = Self {
            files: Vec::new(),
            folders: vec![job.destination.clone()],
            renamed: Vec::new(),
            issues: Vec::new(),
            subtree_skipped: 0,
            planning: Planning {
                from_device,
                device_journal,
                ..Planning::default()
            },
        };
        let mut stack = Vec::new();
        let mut listed = HashSet::new();
        for path in job.sources.iter().rev() {
            if pending
                .as_ref()
                .is_some_and(|paths| !in_scope(paths, path, true, separator))
            {
                continue;
            }
            if cancel.is_cancelled() {
                return Err(RemtpError::Cancelled);
            }
            let result = if from_device {
                async {
                    let parent = tree::parent(path);
                    if path != "/" && !listed.contains(parent) {
                        device
                            .list_cancel(job.storage_id, parent, cancel.clone())
                            .await?;
                        listed.insert(parent.to_owned());
                    }
                    device.stat(job.storage_id, path).await
                }
                .await
            } else {
                local_entry(Path::new(path)).await
            };
            match result {
                Ok(entry) => stack.push((
                    Source {
                        path: path.clone(),
                        entry,
                    },
                    job.destination.clone(),
                )),
                Err(e) if e.stops_transfer() => return Err(e),
                Err(e) => plan.fail(
                    (path, &job.destination),
                    IssueKind::Failed,
                    &e.to_string(),
                    None,
                    None,
                    retry(path, &job.destination, false),
                ),
            }
        }
        plan.planning
            .load(device, job, &job.destination, &cancel)
            .await?;
        let mut visited = HashSet::new();
        while let Some((source, folder)) = stack.pop() {
            if cancel.is_cancelled() {
                return Err(RemtpError::Cancelled);
            }
            if pending
                .as_ref()
                .is_some_and(|paths| !in_scope(paths, &source.path, source.entry.is_dir, separator))
            {
                continue;
            }
            if !visited.insert((source.path.clone(), folder.clone())) {
                continue;
            }
            let original = &source.entry.name;
            if from_device && source.path == "/" {
                for child in device_children(device, job.storage_id, &source.path, cancel.clone())
                    .await?
                    .into_iter()
                    .rev()
                {
                    stack.push((child, folder.clone()));
                }
                continue;
            }
            if original == "." || original == ".." || original.contains(['/', '\0']) {
                plan.fail(
                    (&source.path, &folder),
                    IssueKind::InvalidName,
                    "invalid path component",
                    None,
                    Some(source.entry.size),
                    card_safe_retry(job, &source, &folder),
                );
                continue;
            }
            let mut name = original.clone();
            let max_units = if from_device {
                names::MAX_UNITS
            } else {
                mtp_rs::mtp::MAX_NAME_UNITS
            };
            if job.card_safe_names {
                name = names::card_safe_name_to(original, !from_device);
            } else if name.encode_utf16().count() > max_units
                || from_device && cfg!(unix) && name.len() > 255
            {
                plan.fail(
                    (&source.path, &folder),
                    IssueKind::NameTooLong,
                    "name exceeds the destination limit",
                    None,
                    Some(source.entry.size),
                    card_safe_retry(job, &source, &folder),
                );
                continue;
            }
            if reserved_name(&name)
                || !tree::valid_component(&name)
                || from_device && !local_name(&name)
            {
                plan.fail(
                    (&source.path, &folder),
                    IssueKind::InvalidName,
                    "invalid or reserved destination name",
                    None,
                    Some(source.entry.size),
                    card_safe_retry(job, &source, &folder),
                );
                continue;
            }
            if let Err(error) = plan.planning.load(device, job, &folder, &cancel).await {
                if !from_device || error.stops_transfer() {
                    return Err(error);
                }
                plan.fail(
                    (&source.path, &folder),
                    IssueKind::Failed,
                    &error.to_string(),
                    None,
                    Some(source.entry.size),
                    retry(&source.path, &folder, false),
                );
                continue;
            }
            let found = plan.planning.lookup(&folder, &name).cloned();
            let original_target = target_join(from_device, &folder, original);
            let mut target = target_join(from_device, &folder, &name);
            if source.entry.is_dir {
                let mut create = false;
                match found {
                    Some(dest) if dest.is_dir => {
                        target = target_join(from_device, &folder, &dest.name)
                    }
                    Some(_) if job.conflict == ConflictPolicy::KeepBoth => {
                        target = plan.planning.keep_both(&target, true);
                        create = true;
                    }
                    Some(_) if job.conflict == ConflictPolicy::Skip => {
                        match count_skipped(device, job, &source.path, &cancel).await {
                            Ok(skipped) => {
                                plan.subtree_skipped = plan.subtree_skipped.saturating_add(skipped);
                            }
                            Err(error) if error.stops_transfer() => return Err(error),
                            Err(error) => plan.fail(
                                (&source.path, &folder),
                                IssueKind::Failed,
                                &format!("could not count files in the skipped folder: {error}"),
                                None,
                                None,
                                None,
                            ),
                        }
                        continue;
                    }
                    Some(_) => {
                        plan.fail(
                            (&target, &folder),
                            IssueKind::Failed,
                            "cannot copy a folder here: the destination name is not a directory; use Keep Both to copy under a different name",
                            None,
                            None,
                            retry(&source.path, &folder, true),
                        );
                        continue;
                    }
                    None => {
                        plan.planning.reserve(&folder, &name, 0, true);
                        create = true;
                    }
                }
                if create && plan.planning.planned_folders.insert(target.clone()) {
                    plan.folders.push(target.clone());
                }
                if target != original_target {
                    plan.renamed.push(RenamedFile {
                        from: original_target,
                        to: target.clone(),
                    });
                }
                let children = if from_device {
                    device_children(device, job.storage_id, &source.path, cancel.clone()).await?
                } else {
                    let mut entries = fs::read_dir(&source.path).await?;
                    let mut children = Vec::new();
                    while let Some(entry) = entries.next_entry().await? {
                        let path = entry.path();
                        let Some(text) = path.to_str() else {
                            plan.fail(
                                (&source.path, &target),
                                IssueKind::InvalidName,
                                "filename is not UTF-8",
                                None,
                                None,
                                None,
                            );
                            continue;
                        };
                        match local_entry(&path).await {
                            Ok(entry) => children.push(Source {
                                path: text.into(),
                                entry,
                            }),
                            Err(error) => plan.fail(
                                (text, &target),
                                IssueKind::Failed,
                                &error.to_string(),
                                None,
                                None,
                                retry(text, &target, false),
                            ),
                        }
                    }
                    children.sort_unstable_by(|a, b| a.entry.name.cmp(&b.entry.name));
                    children
                };
                for child in children.into_iter().rev() {
                    stack.push((child, target.clone()));
                }
                continue;
            }
            let size = source.entry.size;
            let mut existing_size = None;
            let mut replaceable = false;
            let decision = match found {
                Some(dest) => {
                    target = target_join(from_device, &folder, &dest.name);
                    existing_size = (!dest.is_dir).then_some(dest.size);
                    replaceable = !dest.is_dir && !dest.special && !dest.reserved;
                    match job.conflict {
                        ConflictPolicy::KeepBoth => {
                            target = plan.planning.keep_both(&target, false);
                            Decision::Copy { replace: false }
                        }
                        ConflictPolicy::Skip => Decision::Skip,
                        _ if dest.reserved => {
                            plan.fail(
                                (&target, &folder),
                                IssueKind::Failed,
                                "another source in this job uses the same destination name; use Keep Both to copy both files",
                                existing_size,
                                Some(size),
                                retry(&source.path, &folder, true),
                            );
                            continue;
                        }
                        ConflictPolicy::SkipIfSame if replaceable && dest.size == size => {
                            Decision::CheckSame
                        }
                        ConflictPolicy::Replace | ConflictPolicy::SkipIfSame if replaceable => {
                            Decision::Copy { replace: true }
                        }
                        ConflictPolicy::Ask => {
                            let mut issue = plan.planning.issue(
                                (&target, &folder),
                                IssueKind::Conflict,
                                "destination name already exists",
                                existing_size,
                                Some(size),
                                None,
                            );
                            issue.existing_modified = dest.modified;
                            issue.incoming_modified = source.entry.modified;
                            issue.conflict_source = Some(source.path.clone());
                            Decision::Ask(Box::new(issue))
                        }
                        _ => {
                            plan.fail(
                                (&target, &folder),
                                IssueKind::Failed,
                                "cannot replace a directory or special file; use Keep Both to copy under a different name",
                                existing_size,
                                Some(size),
                                retry(&source.path, &folder, true),
                            );
                            continue;
                        }
                    }
                }
                None => Decision::Copy { replace: false },
            };
            if !matches!(decision, Decision::Skip) && size > capacity {
                plan.fail(
                    (&target, &folder),
                    IssueKind::TooLargeForStorage,
                    "file exceeds storage capacity",
                    existing_size,
                    Some(size),
                    None,
                );
                continue;
            }
            if matches!(decision, Decision::Copy { .. }) {
                if size > space {
                    plan.fail(
                        (&target, &folder),
                        IssueKind::NoSpace,
                        "insufficient space for the incoming file",
                        existing_size,
                        Some(size),
                        retry(&source.path, &folder, false),
                    );
                    continue;
                }
                space -= size;
                if matches!(decision, Decision::Copy { replace: true }) {
                    space = space.saturating_add(existing_size.unwrap_or(0));
                }
            }
            if !matches!(decision, Decision::Skip) {
                let name = if from_device {
                    Path::new(&target).file_name().unwrap().to_str().unwrap()
                } else {
                    tree::basename(&target)
                };
                plan.planning.reserve(&folder, name, size, false);
            }
            if target != original_target {
                plan.renamed.push(RenamedFile {
                    from: original_target,
                    to: target.clone(),
                });
            }
            let failure_id = plan.planning.next();
            plan.files.push(PlannedFile {
                source: source.path,
                target,
                size,
                modified: source.entry.modified,
                existing_size,
                replaceable,
                failure_id,
                decision,
            });
        }
        Ok(plan)
    }

    fn fail(
        &mut self,
        location: (&str, &str),
        kind: IssueKind,
        message: &str,
        existing_size: Option<u64>,
        incoming_size: Option<u64>,
        retry: Option<IssueRetry>,
    ) {
        self.issues.push(self.planning.issue(
            location,
            kind,
            message,
            existing_size,
            incoming_size,
            retry,
        ));
    }
}

fn in_scope(paths: &BTreeSet<String>, path: &str, might_be_folder: bool, separator: char) -> bool {
    if paths.contains(path) {
        return true;
    }
    if !might_be_folder {
        return false;
    }
    let prefix = format!("{}{separator}", path.trim_end_matches(separator));
    paths
        .range(prefix.clone()..)
        .next()
        .is_some_and(|next| next.starts_with(&prefix))
}

impl Planning {
    fn next(&mut self) -> u64 {
        self.next_id += 1;
        self.next_id
    }

    pub fn issue(
        &mut self,
        (path, folder): (&str, &str),
        kind: IssueKind,
        message: &str,
        existing_size: Option<u64>,
        incoming_size: Option<u64>,
        retry: Option<IssueRetry>,
    ) -> TransferIssue {
        TransferIssue {
            id: self.next(),
            path: path.into(),
            destination_folder: folder.into(),
            kind,
            message: message.into(),
            existing_size,
            incoming_size,
            existing_modified: None,
            incoming_modified: None,
            retry,
            conflict_source: None,
        }
    }

    async fn load(
        &mut self,
        device: &Device,
        job: &TransferJob,
        folder: &str,
        cancel: &CancelToken,
    ) -> Result<()> {
        if self.destinations.contains_key(folder) {
            return Ok(());
        }
        let mut entries = HashMap::new();
        if !self.planned_folders.contains(folder) {
            if self.from_device {
                match local_listing(Path::new(&job.destination), Path::new(folder), cancel).await {
                    Ok(list) => {
                        for (name, meta) in list {
                            let special = is_link(&meta) || !meta.is_file() && !meta.is_dir();
                            entries.insert(
                                names::insensitive_key(&name),
                                Destination {
                                    name,
                                    size: meta.len(),
                                    modified: meta.modified().ok().and_then(seconds),
                                    is_dir: meta.is_dir() && !special,
                                    reserved: false,
                                    special,
                                },
                            );
                        }
                    }
                    Err(RemtpError::NotFound { .. }) => {}
                    Err(error) => return Err(error),
                }
            } else {
                match planned_list(
                    device,
                    self.device_journal.clone().unwrap(),
                    job.storage_id,
                    folder,
                    cancel.clone(),
                )
                .await
                {
                    Ok(list) => {
                        for entry in list {
                            entries.insert(names::insensitive_key(&entry.name), entry.into());
                        }
                    }
                    Err(RemtpError::NotFound { .. }) => {}
                    Err(e) => return Err(e),
                }
            }
        }
        self.destinations.insert(folder.into(), entries);
        Ok(())
    }

    fn lookup(&self, folder: &str, name: &str) -> Option<&Destination> {
        self.destinations
            .get(folder)?
            .get(&names::insensitive_key(name))
    }

    fn reserve(&mut self, folder: &str, name: &str, size: u64, is_dir: bool) {
        self.destinations.entry(folder.into()).or_default().insert(
            names::insensitive_key(name),
            Destination {
                name: name.into(),
                size,
                modified: None,
                is_dir,
                reserved: true,
                special: false,
            },
        );
    }

    pub fn keep_both(&mut self, path: &str, is_dir: bool) -> String {
        let (folder, name) = if self.from_device {
            let path = Path::new(path);
            (
                path.parent().unwrap().to_str().unwrap(),
                path.file_name().unwrap().to_str().unwrap(),
            )
        } else {
            (tree::parent(path), tree::basename(path))
        };
        for index in 2.. {
            let (units, bytes) = if self.from_device {
                (names::MAX_UNITS, if cfg!(unix) { 255 } else { usize::MAX })
            } else {
                (mtp_rs::mtp::MAX_NAME_UNITS, usize::MAX)
            };
            let name = names::numbered_bounded(name, index, units, bytes);
            if self.lookup(folder, &name).is_none() {
                self.reserve(folder, &name, 0, is_dir);
                return target_join(self.from_device, folder, &name);
            }
        }
        unreachable!()
    }
}

fn target_join(from_device: bool, folder: &str, name: &str) -> String {
    if from_device {
        Path::new(folder).join(name).to_string_lossy().into_owned()
    } else {
        tree::join(folder, name)
    }
}

async fn device_children(
    device: &Device,
    storage: u32,
    path: &str,
    cancel: CancelToken,
) -> Result<Vec<Source>> {
    Ok(device
        .list_cancel(storage, path, cancel)
        .await?
        .into_iter()
        .map(|entry| Source {
            path: tree::join(path, &entry.name),
            entry,
        })
        .collect())
}

async fn count_skipped(
    device: &Device,
    job: &TransferJob,
    path: &str,
    cancel: &CancelToken,
) -> Result<u32> {
    let mut pending = vec![PathBuf::from(path)];
    let mut files = 0u32;
    while let Some(path) = pending.pop() {
        if cancel.is_cancelled() {
            return Err(RemtpError::Cancelled);
        }
        if job.direction == Direction::FromDevice {
            let path = path.to_str().unwrap();
            for entry in device
                .list_cancel(job.storage_id, path, cancel.clone())
                .await?
            {
                if entry.is_dir {
                    pending.push(PathBuf::from(tree::join(path, &entry.name)));
                } else {
                    files = files.saturating_add(1);
                }
            }
        } else {
            let mut entries = fs::read_dir(path).await?;
            while let Some(entry) = entries.next_entry().await? {
                if cancel.is_cancelled() {
                    return Err(RemtpError::Cancelled);
                }
                let kind = entry.file_type().await?;
                if kind.is_dir() {
                    pending.push(entry.path());
                } else if kind.is_file() {
                    files = files.saturating_add(1);
                }
            }
        }
    }
    Ok(files)
}

async fn local_entry(path: &Path) -> Result<Entry> {
    let metadata = fs::symlink_metadata(path).await?;
    if !metadata.is_file() && !metadata.is_dir() {
        return Err(RemtpError::Io {
            message: "not a regular file or folder".into(),
        });
    }
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| RemtpError::Io {
            message: "cannot determine source filename".into(),
        })?;
    let modified = metadata.modified().ok().and_then(seconds);
    Ok(Entry {
        name: name.into(),
        is_dir: metadata.is_dir(),
        size: if metadata.is_dir() { 0 } else { metadata.len() },
        modified,
    })
}

fn seconds(time: SystemTime) -> Option<i64> {
    match time.duration_since(UNIX_EPOCH) {
        Ok(delta) => i64::try_from(delta.as_secs()).ok(),
        Err(error) => {
            let delta = error.duration();
            let whole = delta.as_secs() + u64::from(delta.subsec_nanos() != 0);
            i64::try_from(whole).ok()?.checked_neg()
        }
    }
}

fn retry(source: &str, folder: &str, keep_both: bool) -> Option<IssueRetry> {
    Some(IssueRetry {
        source: source.into(),
        folder: folder.into(),
        card_safe_name: None,
        keep_both,
    })
}

/// A retry under the card-safe name, when the source's own name failed and that name would be accepted.
fn card_safe_retry(job: &TransferJob, source: &Source, folder: &str) -> Option<IssueRetry> {
    let from_device = job.direction == Direction::FromDevice;
    let name = names::card_safe_name_to(&source.entry.name, !from_device);
    let usable = !job.card_safe_names
        && name != source.entry.name
        && !reserved_name(&name)
        && tree::valid_component(&name)
        && (!from_device || local_name(&name));
    usable.then(|| IssueRetry {
        source: source.path.clone(),
        folder: folder.into(),
        card_safe_name: Some(name),
        keep_both: false,
    })
}
