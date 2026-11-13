//! zerod's own state, for the app's Health checks (ZeroCore Health.swift judges it): who started it, whether the
//! files it makes are quarantined, its descriptors against their limit, and whether its build was replaced on disk.

use std::path::Path;
use std::sync::LazyLock;
use std::time::SystemTime;

use serde_json::{Value, json};

unsafe extern "C" {
    fn getrlimit(resource: i32, limits: *mut [u64; 2]) -> i32;
    fn proc_pidpath(pid: i32, buffer: *mut u8, size: u32) -> i32;
    fn getxattr(
        path: *const std::ffi::c_char, name: *const std::ffi::c_char, value: *mut u8, size: usize, position: u32, options: i32,
    ) -> isize;
}

/// The build on disk when zerod started: another one there means an install that didn't restart it.
static BUILT: LazyLock<Option<(SystemTime, u64)>> = LazyLock::new(|| fingerprint(&std::env::current_exe().ok()?));

/// A build's date and a digest of it: an install copies an unchanged build again with a newer date, and signs it again
/// (a new signing time in its bytes), so a Mach-O's build is its LC_UUID, which the linker sets and codesign keeps.
pub fn fingerprint(path: &Path) -> Option<(SystemTime, u64)> {
    use std::hash::Hasher;
    let modified = std::fs::metadata(path).and_then(|m| m.modified()).ok()?;
    let bytes = std::fs::read(path).ok()?;
    let mut hasher = std::hash::DefaultHasher::new();
    hasher.write(mach_o_uuid(&bytes).unwrap_or(&bytes));
    Some((modified, hasher.finish()))
}

/// A 64-bit little-endian Mach-O's LC_UUID, read from its load commands.
fn mach_o_uuid(bytes: &[u8]) -> Option<&[u8]> {
    const LC_UUID: u32 = 0x1b;
    let word = |at: usize| Some(u32::from_le_bytes(bytes.get(at..at + 4)?.try_into().ok()?));
    if word(0)? != 0xfeed_facf {
        return None;
    }
    let mut at = 32;
    for _ in 0..word(16)? {
        let (command, size) = (word(at)?, word(at + 4)? as usize);
        if command == LC_UUID {
            return bytes.get(at + 8..at + 24);
        }
        at += size.max(8);
    }
    None
}

/// Whether the build at `path` is no longer the one fingerprinted: its bytes are read again only when its date moved.
pub fn replaced(path: &Path, was: Option<(SystemTime, u64)>) -> bool {
    let Some((modified, digest)) = was else { return false };
    if std::fs::metadata(path).and_then(|m| m.modified()).ok() == Some(modified) {
        return false;
    }
    fingerprint(path).map(|(_, now)| now) != Some(digest)
}

/// At start: the build noted, and a quarantined zerod said loudly in its log.
pub fn at_start(home: &Path) {
    LazyLock::force(&BUILT);
    if quarantined(home) {
        eprintln!(
            "zerod: QUARANTINED: started under a quarantining process (parent pid {}), so every file agents make is \
             quarantined and programs they build are blocked. Quit zerod and let Zero start it again.",
            std::os::unix::process::parent_id()
        );
    }
}

pub fn report(home: &Path) -> Value {
    let parent = std::os::unix::process::parent_id();
    // /dev/fd lists this process's descriptors, the one reading it among them.
    let open = std::fs::read_dir("/dev/fd").map(|d| d.count().saturating_sub(1)).unwrap_or(0);
    json!({
        "pid": std::process::id(),
        "parent": {"pid": parent, "path": path_of(parent)},
        "quarantined": quarantined(home),
        "descriptors": {"open": open, "limit": descriptor_limit()},
        "exe": std::env::current_exe().ok(),
        "replaced": std::env::current_exe().is_ok_and(|exe| replaced(&exe, *BUILT)),
    })
}

/// Started under a process that quarantines the files it makes (Chrome, for its native host), zerod and every agent
/// under it do too, and macOS blocks every program they build. macOS has no way for a process to drop it: the way out
/// is starting zerod again from Zero.
pub fn quarantined(home: &Path) -> bool {
    use std::os::unix::ffi::OsStrExt;
    let probe = home.join("quarantine-probe");
    if std::fs::write(&probe, b"").is_err() {
        return false;
    }
    let path = std::ffi::CString::new(probe.as_os_str().as_bytes()).unwrap_or_default();
    // Safety: two NUL-terminated strings and no buffer: the size of the attribute, or -1 when the file has none.
    let quarantined = unsafe { getxattr(path.as_ptr(), c"com.apple.quarantine".as_ptr(), std::ptr::null_mut(), 0, 0, 0) } >= 0;
    let _ = std::fs::remove_file(&probe);
    quarantined
}

fn descriptor_limit() -> u64 {
    const RLIMIT_NOFILE: i32 = 8;
    let mut limits = [0u64; 2];
    // Safety: reads the two u64s of an rlimit, which `limits` is.
    if unsafe { getrlimit(RLIMIT_NOFILE, &mut limits) } == 0 { limits[0] } else { 0 }
}

/// A process's program, or none when it's gone or not ours to see.
fn path_of(pid: u32) -> Option<String> {
    let mut buffer = [0u8; 4096];
    // Safety: writes at most `size` bytes into `buffer`, giving how many.
    let length = unsafe { proc_pidpath(pid as i32, buffer.as_mut_ptr(), buffer.len() as u32) };
    (length > 0).then(|| String::from_utf8_lossy(&buffer[..length as usize]).into_owned())
}
