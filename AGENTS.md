# Zero

A Mac workspace for coding agents (Codex, Claude Code, OpenCode): a Rust daemon, `zerod`, owns the sessions; a Swift app
is their UI and the inbox where agents reach the user. `docs/workspace.md` has the architecture.

## Layout

- `crates/zerod`: the daemon on `~/.zero/zerod.sock`. Sessions and their adapters (`claude.rs`, `codex.rs`, `acp.rs`),
  the board, the inbox, scratchpads (`pads.rs`, `mcp.rs`), folder snapshots for rewind (`snapshots.rs`), graceful restart.
- `apps/macos/Sources/ZeroCore`: the app's model and its client of zerod (`Zerod.swift`, `Workspace.swift`).
- `apps/macos/Sources/ZeroApp`: the UI, a file per topic. The window: `WorkspaceView.swift` (window, rail),
  `TasksSidebar.swift`, `TaskView.swift`, `ConversationView.swift`, `Composer.swift`, `TaskDetails.swift` (details
  pane); `Timeline.swift` (a conversation's blocks, rail, scrollbar). The control bar: `PillView.swift` (the bar),
  `InboxView.swift` (its panel), `InboxController.swift`, `CardView.swift` (the ask cards). The app: `ZeroApp.swift`
  (entry point), `AppDelegate.swift` (launch, menus, hot key), `InboxPanel.swift`, `WorkspaceWindow.swift`,
  `SelectorPanel.swift`, `Settings.swift`.
- `apps/macos/Sources/zero`: the CLI agents use (the `zero-full` program): `main.swift` parses the arguments and
  dispatches, one file per topic (Asks, Hooks, Sessions, Board, Follow, Later, Watch). `apps/macos/Sources/ZeroFront`:
  `zero` itself, Darwin only, so the commands called most (note, done, withdraw, status, prompt, issue, send) start in
  a third of the time; it runs zero-full for everything else, and a change to one of those commands is made in both.
  `plugin/`: Claude Code's plugin for Zero.

## Working on it

- Work on `main`; no branches. Commit only when the user says, one line each: `type(scope): message` under 72
  characters, no body or trailers (scopes in use: `zerod`, `app`). Pushing also needs their word.
- zerod is test first: write the failing test in `crates/zerod/tests/integration/` (one test program: a new file
  there is a `mod` in its `main.rs`, never a test file of its own, as each program costs seconds to start), then the
  code. A test that waits out one of zerod's timers runs on paused time (`#[tokio::test(start_paused = true)]`):
  the whole program runs in seconds, and one real 4-minute wait once made it 4 minutes. Swift UI isn't unit tested;
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
  evidence for general mechanisms (places commands, attributes), not features. Agent-facing text says "the user".
- Zero keeps the CLIs' sign-ins (`signins.rs`: values in the Keychain, a Codex account's in the home Codex keeps it
  in) and hands each CLI the chosen one as it starts, in the form that CLI reads. It never calls providers' services
  itself (the CLIs make every call), and never logs, prints or sends a sign-in anywhere but to its CLI. Use the
  `claude` CLI (stream-json), never the Agent SDK with a subscription.
- Integrations' tokens (and their write switches) live in zerod's own Keychain item (`vault.rs`), never in a file.
  An op only the user makes (answering, settings, sign-ins, connections) goes in `APP_ONLY` (server.rs): zerod
  makes it only for Zero.app, by its signature (`peer.rs`).
- Never commit `~/.zero/asks.jsonl` or anything from `~/.zero`; never print secrets.
- Don't change the user's OpenCode permission config unasked.

## How the user likes the UI

- Codex and the control bar are the references. One of everything: one scrollbar (`thinScrollbar()`), one selector
  (Zero's own, `SelectorView`), one card for an ask (`CardView`; `flat` inside other surfaces, never a card in a card).
- Zero's own popovers and cards, not native ones (slow, animated): drawn in place, instant.
- Nucleo icons only (the UI family at 18 px; fetch missing ones with the Nucleo tools). The apps' live in the private
  `zero-private` repo (`icons/macos`, `icons/ios`; `make` and `apps/ios/icons.sh` take them from `../zero-private`),
  never in this one; builds without it draw Lucide's. A new icon goes into zero-private and gets its closest Lucide
  icon in `apps/macos/scripts/lucide.txt` (then `sh apps/macos/scripts/lucide.sh`). The site's are in this repo:
  Nucleo's licence caps it at 100 distinct icons (listed in THIRD_PARTY_LICENSES).
- Concentric corners: an inner radius plus its inset equals the outer radius. `compositingGroup()` before `shadow`
  on a stack (otherwise every row in it casts a shadow).
- Links in properties: medium weight on a dashed underline, no icon, no blue. States as pills.
- Nothing jumps: fixed heights for live rows, placeholders that keep their space.
