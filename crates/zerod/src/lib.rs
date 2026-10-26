//! zerod: runs agent sessions (Codex first) and serves them to Zero's apps over a Unix socket.
//! docs/workspace.md has the layers; this crate is the runtime, adapter, core and host parts of them.

pub mod acp;
pub mod adapter;
pub mod claude;
pub mod codex;
pub mod core;
pub mod daemon;
pub mod model;
pub mod process;
pub mod server;
pub mod session;
