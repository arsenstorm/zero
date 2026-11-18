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

## Testing a UI change yourself: Zero Dev

Zero Dev is Zero built for testing beside the user's own, in `build-dev/`: its own bundle id (`com.arsen.zero.dev`),
zerod (`--features dev`, its HOME in `~/.zero-dev/home`), state (`~/.zero-dev`) and Zero Browser. It has no Keychain,
LaunchAgent, control bar, hot key or phones, opens no link outside itself, and never takes focus. It can't reach the
user's Zero or zerod, nor they it.

- `make e2e`: builds Zero Dev, runs its checks (`DevE2E.swift`), stops it and prints `build-dev/e2e/results.md`. The
  checks drive Zero Dev's own window with events posted to its own queue, never the user's mouse or keyboard. For a UI
  change, add a check there that clicks or types where the user would, and reads back what changed.
- `make dev` builds and starts it in the background; `make dev-stop` stops it and its zerod.
- Nothing may appear on the user's screen. Menus, panels, sheets and popovers are windows of their own and show over
  every app, whatever window they belong to. Check them by their model, never by opening them: a page's menu gives its
  items to `PageQuestions.devMenuPick`, and no selector opens while the harness drives. Zero Dev's window stays off
  every display under `--e2e` (`DevWindow`), and the last check fails if any of its windows was on one. If something
  can only be checked on screen, leave that check to the user.
- A one-off probe that touches AppKit (a window, accessibility, window order) runs through
  `apps/macos/scripts/probe.sh file.swift`, never on its own: it keeps every window the probe makes off every display
  and stops it activating. macOS moves a window placed off-screen back onto a display, so placing it away isn't enough.
- What leaves Zero is caught in a dev build: a link opened (`LinearLinks.left`), the open panel (`PageQuestions.devFiles`),
  downloads (`~/.zero-dev/downloads`). Keep new ways out behind `DevBuild.on` the same way.
- Never build a dev zerod or app into the shared build folders: `make install` copies from them into the user's Zero.
  The scripts use `build-dev/cargo` and `build-dev/swift`.
- Still ask the user to look at how it renders: the checks prove behaviour, not looks.

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
- Lines an agent is responsible for (a worker's report, another task's message, its own steps through `zero` and its
  wake-ups) take Nucleo's pixel family instead, and only they: one mapping (ZeroCore's `AgentIcons`), each icon
  `px-<name>` with its Lucide fallback. `PixelIcon` draws one at its own 24 px grid, rasterized once and never
  smoothed: 12 pt on the Mac, 16 pt on 3x iPhones. Zero's own lines, asks and approvals keep the UI family.
- Concentric corners: an inner radius plus its inset equals the outer radius. `compositingGroup()` before `shadow`
  on a stack (otherwise every row in it casts a shadow).
- Links in properties: medium weight on a dashed underline, no icon, no blue. States as pills.
- Nothing jumps: fixed heights for live rows, placeholders that keep their space.
