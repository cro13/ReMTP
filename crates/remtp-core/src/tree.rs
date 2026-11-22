use std::collections::{BTreeMap, BTreeSet, HashMap};

use crate::transport::{Handle, Object};
use crate::{Entry, RemtpError, Result};

#[derive(Default)]
pub(crate) struct Tree {
    objects: BTreeMap<String, Object>,
    handles: HashMap<Handle, String>,
    children: HashMap<String, BTreeSet<String>>,
    loaded: BTreeMap<String, bool>,
}

pub(crate) fn normalize(path: &str) -> Result<String> {
    let mut normalized = String::new();
    for part in path.split('/').filter(|part| !part.is_empty()) {
        if !valid_component(part) {
            return Err(RemtpError::Protocol {
                message: format!("invalid device path: {path}"),
            });
        }
        normalized.push('/');
        normalized.push_str(part);
    }
    if normalized.is_empty() {
        normalized.push('/');
    }
    Ok(normalized)
}

pub(crate) fn valid_component(name: &str) -> bool {
    !name.is_empty() && !matches!(name, "." | "..") && !name.contains(['/', '\\', '\0'])
}

pub(crate) fn parent(path: &str) -> &str {
    let (parent, _) = path.rsplit_once('/').unwrap_or(("", path));
    if parent.is_empty() { "/" } else { parent }
}

pub(crate) fn basename(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}
pub(crate) fn join(folder: &str, name: &str) -> String {
    format!("{}/{name}", folder.trim_end_matches('/'))
}
fn prefix(path: &str) -> String {
    join(path, "")
}

impl Tree {
    pub fn lookup(&self, path: &str) -> Option<&Object> {
        self.objects.get(path)
    }
    pub fn path(&self, handle: Handle) -> Option<&str> {
        if handle == 0 {
            Some("/")
        } else {
            self.handles.get(&handle).map(String::as_str)
        }
    }
    pub fn contains(&self, path: &str) -> bool {
        self.loaded.contains_key(path)
    }
    pub fn mark_loaded(&mut self, path: String, complete: bool) {
        self.loaded.insert(path, complete);
    }
    pub fn complete(&self, path: &str) -> bool {
        self.loaded.get(path) == Some(&true)
    }
    pub fn mark_incomplete(&mut self, path: &str) {
        if let Some(complete) = self.loaded.get_mut(path) {
            *complete = false;
        }
    }

    pub fn children(&self, path: &str) -> impl Iterator<Item = (&String, &Object)> {
        self.children
            .get(path)
            .into_iter()
            .flat_map(|names| names.iter())
            .filter_map(|child| self.objects.get_key_value(child))
    }

    pub fn entries(&self, path: &str) -> Vec<Entry> {
        self.children(path)
            .map(|(_, object)| object.entry.clone())
            .collect()
    }

    pub fn insert(&mut self, path: String, object: Object) {
        if self
            .objects
            .get(&path)
            .is_some_and(|previous| previous.handle != object.handle)
        {
            self.mark_incomplete(parent(&path));
            self.remove(&path);
        }
        if let Some(previous) = self
            .path(object.handle)
            .filter(|old| *old != path)
            .map(str::to_owned)
        {
            self.remove(&previous);
        }
        self.handles.insert(object.handle, path.clone());
        self.children
            .entry(parent(&path).to_owned())
            .or_default()
            .insert(path.clone());
        self.objects.insert(path, object);
    }

    pub fn remove(&mut self, path: &str) {
        let prefix = prefix(path);
        let paths: Vec<_> = self
            .objects
            .range(prefix.clone()..)
            .take_while(|(p, _)| p.starts_with(&prefix))
            .map(|(p, _)| p.clone())
            .collect();
        for path in paths.iter().map(String::as_str).chain([path]) {
            if let Some(object) = self.objects.remove(path) {
                self.handles.remove(&object.handle);
            }
            self.children.remove(path);
            let parent_path = parent(path);
            if let Some(siblings) = self.children.get_mut(parent_path) {
                siblings.remove(path);
                if siblings.is_empty() {
                    self.children.remove(parent_path);
                }
            }
        }
        let loaded: Vec<_> = self
            .loaded
            .range(prefix.clone()..)
            .take_while(|(p, _)| p.starts_with(&prefix))
            .map(|(p, _)| p.clone())
            .collect();
        for path in loaded.iter().map(String::as_str).chain([path]) {
            self.loaded.remove(path);
        }
    }

    pub fn invalidate(&mut self, path: &str) {
        let node = self.lookup(path).cloned();
        self.remove(path);
        if let Some(node) = node {
            self.insert(path.into(), node);
        }
    }

    pub fn rename(&mut self, path: &str, new_name: &str) {
        if let Some(mut object) = self.lookup(path).cloned() {
            self.remove(path);
            object.entry.name = new_name.into();
            self.insert(join(parent(path), new_name), object);
        }
    }
}
