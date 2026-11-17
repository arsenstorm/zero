//! Zero Browser: Chromium in an app of its own inside Zero.app (Contents/Helpers/Zero Browser.app), started by zerod
//! the first time Zero.app's side panel or a task needs it. zerod keeps one end of a socket pair and hands the app the
//! other as its stdin: no name to find or squat, no port. That end is one more connection to zerod, which the app's
//! tools page uses as Zero for Chrome uses its native host. Each side checks the other's signature: zerod the bundle
//! before it starts it, the app its socket's creator (zerod) before it takes a call. Frames and input go between the
//! app and Zero.app over Mach, not through zerod; Zero.app finds the app by the pid zerod answers with.
//!
//! When zerod goes, the app's socket closes and it quits cleanly (cookies written out); Zero.app asks the next zerod
//! to start it again.

use std::ffi::{CString, c_char, c_void};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

/// Zero Browser's identifier in this build: Zero Dev's own in a dev build, so a dev zerod never starts the user's.
#[cfg(not(feature = "dev"))]
pub const IDENTIFIER: &str = "com.arsen.zero.browser";
#[cfg(feature = "dev")]
pub const IDENTIFIER: &str = "com.arsen.zero.dev.browser";

pub struct ZeroBrowser {
    app: PathBuf,
    log: PathBuf,
    /// Whether the bundle's signature is checked before it's started: off in tests, whose stand-in isn't signed.
    check: bool,
    pid: Mutex<Option<i32>>,
}

impl ZeroBrowser {
    pub fn new(app: PathBuf, log: PathBuf, check: bool) -> Arc<ZeroBrowser> {
        Arc::new(ZeroBrowser { app, log, check, pid: Mutex::new(None) })
    }

    /// The one in the Zero.app this zerod runs from; none for a zerod outside an app (built and run by hand).
    pub fn bundled(log: PathBuf) -> Option<Arc<ZeroBrowser>> {
        let exe = std::env::current_exe().ok()?;
        let app = exe.parent()?.parent()?.join("Helpers/Zero Browser.app");
        app.exists().then(|| ZeroBrowser::new(app, log, true))
    }

    /// Its pid, started first if it isn't running; `serve` takes zerod's end of its socket.
    pub fn ensure(self: &Arc<Self>, serve: impl FnOnce(UnixStream)) -> Result<i32, String> {
        let mut running = self.pid.lock().unwrap();
        if let Some(pid) = *running {
            return Ok(pid);
        }
        if self.check && !crate::peer::is_signed_app(&self.app, IDENTIFIER) {
            return Err(format!("{} isn't signed as Zero's", self.app.display()));
        }
        let (ours, theirs) = UnixStream::pair().map_err(|e| e.to_string())?;
        let pid = spawn(&self.app.join("Contents/MacOS/Zero Browser"), theirs.as_raw_fd(), &self.log)?;
        drop(theirs);
        *running = Some(pid);
        serve(ours);
        // Reaped on a thread of its own: gone (quit, crashed, killed), the next ensure starts another.
        let me = Arc::downgrade(self);
        std::thread::spawn(move || {
            let mut status = 0;
            waitpid(pid, &mut status, 0);
            if let Some(me) = me.upgrade() {
                let mut running = me.pid.lock().unwrap();
                if *running == Some(pid) {
                    *running = None
                }
            }
        });
        Ok(pid)
    }
}

/// Starts `exe` with `socket` as its stdin and its output to `log`, answering for itself: camera, microphone and
/// location prompts name Zero Browser, not zerod (`responsibility_spawnattrs_setdisclaim`, libsystem's, private; without
/// it zerod stays responsible).
fn spawn(exe: &Path, socket: i32, log: &Path) -> Result<i32, String> {
    const O_WRONLY: i32 = 0x1;
    const O_APPEND: i32 = 0x8;
    const O_CREAT: i32 = 0x200;
    const POSIX_SPAWN_CLOEXEC_DEFAULT: i16 = 0x4000;
    let path = CString::new(exe.as_os_str().as_encoded_bytes()).map_err(|e| e.to_string())?;
    let log = CString::new(log.as_os_str().as_encoded_bytes()).map_err(|e| e.to_string())?;
    let argv = [path.as_ptr(), std::ptr::null()];
    let mut pid = 0;
    let rc = unsafe {
        let mut actions: *mut c_void = std::ptr::null_mut();
        let mut attrs: *mut c_void = std::ptr::null_mut();
        posix_spawn_file_actions_init(&mut actions);
        posix_spawn_file_actions_adddup2(&mut actions, socket, 0);
        posix_spawn_file_actions_addopen(&mut actions, 1, log.as_ptr(), O_WRONLY | O_CREAT | O_APPEND, 0o600);
        posix_spawn_file_actions_adddup2(&mut actions, 1, 2);
        posix_spawnattr_init(&mut attrs);
        posix_spawnattr_setflags(&mut attrs, POSIX_SPAWN_CLOEXEC_DEFAULT);
        let disclaim = dlsym(-2isize as *mut c_void, c"responsibility_spawnattrs_setdisclaim".as_ptr());
        if !disclaim.is_null() {
            let disclaim: unsafe extern "C" fn(*mut *mut c_void, i32) -> i32 = std::mem::transmute(disclaim);
            disclaim(&mut attrs, 1);
        }
        let rc = posix_spawn(&mut pid, path.as_ptr(), &actions, &attrs, argv.as_ptr(), *_NSGetEnviron());
        posix_spawn_file_actions_destroy(&mut actions);
        posix_spawnattr_destroy(&mut attrs);
        rc
    };
    if rc != 0 { Err(format!("Couldn't start Zero Browser: {}", std::io::Error::from_raw_os_error(rc))) } else { Ok(pid) }
}

unsafe extern "C" {
    fn posix_spawn(
        pid: *mut i32, path: *const c_char, actions: *const *mut c_void, attrs: *const *mut c_void, argv: *const *const c_char,
        envp: *const *const c_char,
    ) -> i32;
    fn posix_spawn_file_actions_init(actions: *mut *mut c_void) -> i32;
    fn posix_spawn_file_actions_adddup2(actions: *mut *mut c_void, fd: i32, to: i32) -> i32;
    fn posix_spawn_file_actions_addopen(actions: *mut *mut c_void, fd: i32, path: *const c_char, flags: i32, mode: u16) -> i32;
    fn posix_spawn_file_actions_destroy(actions: *mut *mut c_void) -> i32;
    fn posix_spawnattr_init(attrs: *mut *mut c_void) -> i32;
    fn posix_spawnattr_setflags(attrs: *mut *mut c_void, flags: i16) -> i32;
    fn posix_spawnattr_destroy(attrs: *mut *mut c_void) -> i32;
    fn dlsym(handle: *mut c_void, name: *const c_char) -> *mut c_void;
    safe fn waitpid(pid: i32, status: *mut i32, options: i32) -> i32;
    fn _NSGetEnviron() -> *const *const *const c_char;
}
