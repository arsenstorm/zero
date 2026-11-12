//! Settings › Shared build cache: agents' worktrees of one repo share compiled output through the compiler caches the
//! user has installed, so a second checkout doesn't build from cold. Off unless the user turns it on; Zero never
//! installs the tools. The caches keep their own default folders (sccache's and ccache's in ~/Library/Caches), which
//! every process shares, the user's own builds too.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

use crate::process::Variables;

static ON: AtomicBool = AtomicBool::new(false);

/// Read as each process starts.
pub fn set(on: bool) {
    ON.store(on, Ordering::Relaxed)
}

/// The tools Zero passes, what they cache, and the variables that route a build through them. ccache through CMake's
/// launcher variables only: setting CC for every build would change what plain Makefiles and autoconf pick.
const TOOLS: [(&str, &str, &[&str]); 2] = [
    ("sccache", "Rust", &["RUSTC_WRAPPER"]),
    ("ccache", "C and C++ (CMake)", &["CMAKE_C_COMPILER_LAUNCHER", "CMAKE_CXX_COMPILER_LAUNCHER"]),
];

/// The variables for the tools `find` finds, when `on`.
pub fn variables(on: bool, find: impl Fn(&str) -> Option<PathBuf>) -> Variables {
    if !on {
        return Vec::new();
    }
    TOOLS
        .iter()
        .filter_map(|(tool, _, keys)| find(tool).map(|path| keys.iter().map(move |k| (k.to_string(), path.display().to_string()))))
        .flatten()
        .collect()
}

/// Each supported tool, what it's for, and whether `find` finds it: for the settings.
pub fn tools(find: impl Fn(&str) -> Option<PathBuf>) -> serde_json::Value {
    TOOLS.iter().map(|(tool, used, _)| serde_json::json!({"tool": tool, "for": used, "found": find(tool).is_some()})).collect()
}

/// The variables for a session's processes, as the setting and this Mac have them.
pub fn environment() -> Variables {
    variables(ON.load(Ordering::Relaxed), installed)
}

/// `tool` on the user's login PATH.
pub fn installed(tool: &str) -> Option<PathBuf> {
    crate::adapter::login_path().split(':').map(|dir| Path::new(dir).join(tool)).find(|path| path.is_file())
}
