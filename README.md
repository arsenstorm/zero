# Zero

A native workspace for coding agents: start them, talk to them, approve what they do, and see their work, across
Codex, Claude Code and OpenCode. The Rust daemon does the work; the Swift apps show it. docs/workspace.md has the
architecture and the order of work.

## Where things are

| Path | What | Language |
|---|---|---|
| `crates/zerod/` | The daemon: agent sessions on Codex, Claude Code and OpenCode, transcripts on disk, the socket the apps talk to | Rust |
| `crates/zero-drop/` | The static client placed in drop folders, so agents on other machines reach Zero over files | Rust |
| `apps/macos/` | The Mac app (bar, inbox, Settings), the `zero` CLI, and zero-host (Zero's own terminals, Ghostty's engine) | Swift |
| `plugin/` | The Claude Code plugin Zero installs: hooks and the zero skill. Bundled into Zero.app as-is | Shell, Markdown |
| `docs/` | Architecture and decisions | |

Swift is moving to UI only: zero-host's terminals and the asks store move into zerod next (docs/workspace.md).

## Build and test

```sh
make test     # cargo test --workspace, then swift test
make zerod    # the daemon, at target/release/zerod
make run      # build, sign, install /Applications/Zero.app and start it
cargo test -p zerod --test e2e -- --ignored   # the daemon against the real Codex, Claude Code and OpenCode
                                              # (two short turns on each one's own sign-in; add a name for one)
```

Needs Rust (with the `x86_64-` and `aarch64-unknown-linux-musl` targets for the drop clients), Xcode, and Zig
for Ghostty's engine the first time (`brew install zig`).

## Working on the daemon

Test first. A change to zerod starts with a failing test in `crates/zerod/tests/`:

- `codex.rs`, `claude.rs`, `opencode.rs`: what each provider's messages become in Zero's model, on real sessions
  recorded in `tests/fixtures/` as zerod transcripts (paths and names scrubbed). New provider behaviour gets a new
  recording.
- `mirror.rs`: a client applying the changes ends with the daemon's conversation, for every fixture.
- `session.rs`: live sessions against `tests/common`'s `play`, which stands in for the runtime by playing a fixture
  and checking that Zero speaks the protocol in the recorded order.
- `process.rs`: runtime processes, their environment and their end.
- `server.rs`: the socket protocol as the apps use it, restarts included.
- `e2e.rs`: the real CLIs, ignored unless asked for.
