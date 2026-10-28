//! zerod: runs agent sessions (Codex first) and serves them to Zero's apps over a Unix socket.
//! docs/workspace.md has the layers; this crate is the runtime, adapter, core and host parts of them.

pub mod acp;
pub mod adapter;
pub mod ask;
pub mod board;
pub mod bridge;
pub mod claude;
pub mod cli;
pub mod codex;
pub mod core;
pub mod daemon;
pub mod drops;
pub mod handoff;
pub mod host;
pub mod images;
pub mod inbox;
pub mod mcp;
pub mod integrations;
pub mod model;
pub mod pads;
pub mod process;
pub mod rex;
pub mod server;
pub mod session;
pub mod solo;
pub mod terminal;
