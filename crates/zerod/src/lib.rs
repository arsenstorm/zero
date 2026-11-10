//! zerod: runs agent sessions (Codex first) and serves them to Zero's apps over a Unix socket.
//! docs/workspace.md has the layers; this crate is the runtime, adapter, core and host parts of them.

pub mod acp;
pub mod adapter;
pub mod ask;
pub mod board;
pub mod bridge;
pub mod browser;
pub mod claude;
pub mod claude_login;
pub mod cli;
pub mod codex;
pub mod codex_login;
pub mod core;
pub mod daemon;
pub mod drops;
pub mod firefox;
pub mod following;
pub mod git;
pub mod handoff;
pub mod host;
pub mod images;
pub mod inbox;
pub mod integrations;
pub mod later;
pub mod loops;
pub mod mcp;
pub mod mcp_servers;
pub mod model;
pub mod naming;
pub mod pads;
pub mod process;
pub mod recap;
pub mod runs;
pub mod safari;
pub mod schedules;
pub mod server;
pub mod session;
pub mod signins;
pub mod snapshots;
pub mod terminal;
pub mod watches;
pub mod websocket;
pub mod workspaces;

/// Now, in seconds since 1970.
pub fn now() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

/// Now, in milliseconds since 1970.
pub fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}
