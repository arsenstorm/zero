# Zero

A Mac workspace for coding agents (Codex, Claude Code, OpenCode): a Rust daemon, `zerod`, owns the sessions; a Swift app
is their UI and the inbox where agents reach the user. `docs/workspace.md` has the architecture.

## Layout

- `crates/zerod`: the daemon on `~/.zero/zerod.sock`. Sessions and their adapters (`claude.rs`, `codex.rs`, `acp.rs`),
  the board, the inbox, scratchpads (`pads.rs`, `mcp.rs`), folder snapshots for rewind (`snapshots.rs`), graceful restart.
- `apps/macos/Sources/ZeroCore`: the app's model and its client of zerod (`Zerod.swift`, `Workspace.swift`).
- `apps/macos/Sources/ZeroApp`: the UI. `WorkspaceView.swift` (window, sidebar, conversation, composer, details pane),
  `Timeline.swift` (a conversation's blocks, rail, scrollbar), `Inbox.swift` (the bar, its panel and the ask cards).
- `apps/macos/Sources/zero`: the `zero` CLI agents use. `plugin/`: Claude Code's plugin for Zero.

## Working on it

- Work on `main`; no branches. Commit only when the user says, one line each: `type(scope): message` under 72
  characters, no body or trailers (scopes in use: `zerod`, `app`). Pushing also needs their word.
- zerod is test first: write the failing test in `crates/zerod/tests/integration/` (one test program: a new file
  there is a `mod` in its `main.rs`, never a test file of its own, as each program costs seconds to start), then the
  code. Swift UI isn't unit tested;
  `ZeroCore` is (`apps/macos/Tests/ZeroCoreTests`).
- Before installing: `cargo test -p zerod`, `cargo clippy -p zerod --all-targets` (clean), `swift test --package-path apps/macos`.
- `make install` builds, installs `/Applications/Zero.app` and reopens it where the user was (their drafts are kept).
  When zerod changed, it restarts zerod gracefully: turns under way finish their running command, pause, and carry on
  under the new zerod. You run inside zerod, so after installing a zerod change your own turn is paused and you're
  told to carry on: that's expected.
- The UI can't be seen from here: say what changed and ask the user to look. Never drive their mouse or keyboard.
- Unsure how something renders or behaves? Log to a file (not `NSLog`: the system log redacts it as `<private>`), have
  the user reproduce it, read the file, then take the logging out.

## Rules

- Zero is a general tool: no one team's specifics in code, prompts or docs. A team's workflow is
  evidence for general mechanisms (places commands, attributes, drops), not features. Agent-facing text says "the user".
- Zero keeps the CLIs' sign-ins (`signins.rs`: values in the Keychain, a Codex account's in the home Codex keeps it
  in) and hands each CLI the chosen one as it starts, in the form that CLI reads. It never calls providers' services
  itself (the CLIs make every call), and never logs, prints or sends a sign-in anywhere but to its CLI. Use the
  `claude` CLI (stream-json), never the Agent SDK with a subscription.
- Never commit `~/.zero/asks.jsonl` or anything from `~/.zero`; never print secrets.
- Don't change the user's OpenCode permission config unasked.

## How the user likes the UI

- Codex and the control bar are the references. One of everything: one scrollbar (`thinScrollbar()`), one selector
  (Zero's own, `SelectorView`), one card for an ask (`CardView`; `flat` inside other surfaces, never a card in a card).
- Zero's own popovers and cards, not native ones (slow, animated): drawn in place, instant.
- Nucleo icons only (`apps/macos/Resources/nucleo`, the UI family at 18 px; fetch missing ones with the Nucleo tools).
- Concentric corners: an inner radius plus its inset equals the outer radius. `compositingGroup()` before `shadow`
  on a stack (otherwise every row in it casts a shadow).
- Links in properties: medium weight on a dashed underline, no icon, no blue. States as pills.
- Nothing jumps: fixed heights for live rows, placeholders that keep their space.
