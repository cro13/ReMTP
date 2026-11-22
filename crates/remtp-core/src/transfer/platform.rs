use std::fs::File;
use std::io;
use std::path::Path;

/// Lightweight write-ordering barrier: orders prior writes before a subsequent rename without
/// triggering macOS's slow `F_FULLFSYNC` drive-cache flush.
#[cfg(target_os = "macos")]
pub(super) fn barrier_sync(file: &File) -> io::Result<()> {
    use std::ffi::c_int;
    use std::os::fd::AsRawFd;

    unsafe extern "C" {
        fn fcntl(fd: c_int, cmd: c_int, ...) -> c_int;
        fn fsync(fd: c_int) -> c_int;
    }
    const F_BARRIERFSYNC: c_int = 85;
    let fd = file.as_raw_fd();
    if unsafe { fcntl(fd, F_BARRIERFSYNC) } == 0 {
        return Ok(());
    }
    let error = io::Error::last_os_error();
    if matches!(
        error.kind(),
        io::ErrorKind::Unsupported | io::ErrorKind::InvalidInput
    ) {
        if unsafe { fsync(fd) } == 0 {
            return Ok(());
        }
        return Err(io::Error::last_os_error());
    }
    Err(error)
}

#[cfg(not(target_os = "macos"))]
pub(super) fn barrier_sync(file: &File) -> io::Result<()> {
    file.sync_data()
}

#[cfg(unix)]
pub(super) fn volume(path: &Path) -> io::Result<String> {
    use std::os::unix::fs::MetadataExt;
    Ok(path.metadata()?.dev().to_string())
}

#[cfg(unix)]
pub(super) fn user_id() -> u32 {
    unsafe extern "C" {
        fn geteuid() -> u32;
    }
    unsafe { geteuid() }
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
fn c_path(path: &Path) -> io::Result<std::ffi::CString> {
    use std::os::unix::ffi::OsStrExt;
    Ok(std::ffi::CString::new(path.as_os_str().as_bytes())?)
}

#[cfg(target_os = "macos")]
pub(super) fn rename_exclusive(source: &Path, target: &Path) -> io::Result<()> {
    use std::ffi::{c_char, c_int, c_uint};

    unsafe extern "C" {
        fn renamex_np(old: *const c_char, new: *const c_char, flags: c_uint) -> c_int;
    }
    const RENAME_EXCL: c_uint = 0x0000_0004;
    let source = c_path(source)?;
    let target = c_path(target)?;
    if unsafe { renamex_np(source.as_ptr(), target.as_ptr(), RENAME_EXCL) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

#[cfg(target_os = "linux")]
pub(super) fn rename_exclusive(source: &Path, target: &Path) -> io::Result<()> {
    use std::ffi::{c_char, c_int, c_uint, c_void};

    #[link(name = "dl")]
    unsafe extern "C" {
        fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
    }
    type RenameAt2 =
        unsafe extern "C" fn(c_int, *const c_char, c_int, *const c_char, c_uint) -> c_int;
    const AT_FDCWD: c_int = -100;
    const RENAME_NOREPLACE: c_uint = 1;
    let symbol = unsafe { dlsym(std::ptr::null_mut(), c"renameat2".as_ptr()) };
    if symbol.is_null() {
        return Err(no_exclusive_rename());
    }
    let renameat2 = unsafe { std::mem::transmute::<*mut c_void, RenameAt2>(symbol) };
    let source = c_path(source)?;
    let target = c_path(target)?;
    if unsafe {
        renameat2(
            AT_FDCWD,
            source.as_ptr(),
            AT_FDCWD,
            target.as_ptr(),
            RENAME_NOREPLACE,
        )
    } == 0
    {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

#[cfg(windows)]
#[link(name = "kernel32")]
unsafe extern "system" {
    fn MoveFileExW(existing: *const u16, new: *const u16, flags: u32) -> i32;
    fn GetVolumePathNameW(path: *const u16, volume: *mut u16, len: u32) -> i32;
    fn GetVolumeNameForVolumeMountPointW(mount: *const u16, volume: *mut u16, len: u32) -> i32;
}

#[cfg(windows)]
fn wide_path(path: &Path) -> io::Result<Vec<u16>> {
    use std::os::windows::ffi::OsStrExt;
    let mut wide: Vec<_> = path.as_os_str().encode_wide().collect();
    if wide.contains(&0) {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "NUL in path"));
    }
    wide.push(0);
    Ok(wide)
}

#[cfg(windows)]
pub(super) fn rename_exclusive(source: &Path, target: &Path) -> io::Result<()> {
    let wide = |path: &Path| {
        let parent = path.parent().unwrap().canonicalize()?;
        wide_path(&parent.join(path.file_name().unwrap()))
    };
    let source = wide(source)?;
    let target = wide(target)?;
    if unsafe { MoveFileExW(source.as_ptr(), target.as_ptr(), 0) } != 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

#[cfg(windows)]
pub(super) fn volume(path: &Path) -> io::Result<String> {
    let path = wide_path(path)?;
    let mut mount = vec![0; 32_768];
    if unsafe { GetVolumePathNameW(path.as_ptr(), mount.as_mut_ptr(), mount.len() as u32) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let mut volume = [0; 50];
    let id = if unsafe {
        GetVolumeNameForVolumeMountPointW(mount.as_ptr(), volume.as_mut_ptr(), volume.len() as u32)
    } != 0
    {
        &volume[..]
    } else {
        &mount[..]
    };
    Ok(String::from_utf16_lossy(id.split(|&c| c == 0).next().unwrap()).to_lowercase())
}

#[cfg(not(any(unix, windows)))]
pub(super) fn volume(_path: &Path) -> io::Result<String> {
    Err(no_exclusive_rename())
}

#[cfg(not(any(target_os = "macos", target_os = "linux", windows)))]
pub(super) fn rename_exclusive(_source: &Path, _target: &Path) -> io::Result<()> {
    Err(no_exclusive_rename())
}

#[cfg(not(any(target_os = "macos", windows)))]
fn no_exclusive_rename() -> io::Error {
    io::Error::new(
        io::ErrorKind::Unsupported,
        "exclusive rename is unavailable",
    )
}
