# Zero

[![CI](https://github.com/arsenstorm/zero/actions/workflows/ci.yml/badge.svg)](https://github.com/arsenstorm/zero/actions/workflows/ci.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/arsenstorm/zero/badge)](https://scorecard.dev/viewer/?uri=github.com/arsenstorm/zero)

A native workspace for coding agents: start them, talk to them, approve what they do, and see their work, across
Codex, Claude Code and OpenCode. The Rust daemon does the work; the Swift apps show it. docs/workspace.md has the
architecture and the order of work.

## Where things are

| Path | What | Language |
|---|---|---|
| `crates/zerod/` | The daemon: agent sessions on Codex, Claude Code and OpenCode, transcripts on disk, the socket the apps talk to | Rust |
| `apps/macos/` | The Mac app (bar, inbox, Settings) and the `zero` CLI | Swift |
| `plugin/` | The Claude Code plugin Zero installs: hooks and the zero skill. Bundled into Zero.app as-is | Shell, Markdown |
| `docs/` | Architecture and decisions | |

Swift is moving to UI only: the asks store moves into zerod next (docs/workspace.md).

## Build and test

```sh
make setup    # once per clone: the pre-commit hook that formats what you stage
make test     # cargo test --workspace, then swift test
make lint     # formatting (rustfmt, swift-format, Biome) and clippy, as CI checks them
make zerod    # the daemon, at target/release/zerod
make run      # build, sign, install /Applications/Zero.app and start it
cargo test -p zerod --test integration e2e -- --ignored   # the daemon against the real Codex, Claude Code and
                                                         # OpenCode (two short turns on each one's own sign-in;
                                                         # e2e::codex for one)
```

Needs Rust and Xcode.

### Building from source

Official builds draw licensed [Nucleo](https://nucleoapp.com) icons, kept in a private repository that `make` picks
up when it's checked out beside this one. Without it, Zero builds with the closest [Lucide](https://lucide.dev) icons
(ISC) instead. That's the only difference: Settings shows which you have ("Icons: Lucide (open-source build)"). For the
iPhone app, run `sh apps/ios/icons.sh` once before building in Xcode; it does the same.

## Working on the daemon

Test first. A change to zerod starts with a failing test in `crates/zerod/tests/integration/`:

- `codex.rs`, `claude.rs`, `opencode.rs`: what each provider's messages become in Zero's model, on real sessions
  recorded in `tests/fixtures/` as zerod transcripts (paths and names scrubbed). New provider behaviour gets a new
  recording.
- `mirror.rs`: a client applying the changes ends with the daemon's conversation, for every fixture.
- `session.rs`: live sessions against `tests/common`'s `play`, which stands in for the runtime by playing a fixture
  and checking that Zero speaks the protocol in the recorded order.
- `process.rs`: runtime processes, their environment and their end.
- `server.rs`: the socket protocol as the apps use it, restarts included.
- `e2e.rs`: the real CLIs, ignored unless asked for.

## License

Zero is free software under the [GNU General Public License, version 3](LICENSE) or (at your option) any later
version. [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES) lists the works it includes and their licences. Contributions are welcome: see [CONTRIBUTING.md](CONTRIBUTING.md), which asks you to sign the
[Contributor License Agreement](CLA.md) once, on your first pull request.
