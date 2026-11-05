# Zero as a workspace for coding agents

Zero began as one inbox for every agent's asks. It is becoming the place where agents are started, talked to and
supervised, across providers, with the terminal as an escape hatch. This file records what exists, what changes,
and the order of work. Verified against the installed tools on 2026-10-26 (Codex CLI 0.160.1, Claude Code 2.1.310,
OpenCode 2.1.4).

## What exists

| Part | Where (under `apps/macos/Sources`) | Keep as is? |
|---|---|---|
| Asks: question, choice, approve, run, note, message, permission; one state machine with a 2 s take-back, a JSONL log, open asks surviving a relaunch | `ZeroCore/Model.swift`, `Store.swift` | Yes. It is the attention layer for every provider. |
| `zero` CLI and the Unix socket it talks over; Claude Code plugin hooks (permission, question, prompt, stop) | `zero/main.swift`, `ZeroApp/Server.swift`, `hooks/` | Yes. |
| Drop folders for agents on other machines (static `zero-drop` clients) | `DropWatcher.swift`, `crates/zero-drop/` | Yes. |
| `AgentAdapter`: deliver text, read a reply, start, stop, resume, liveness | `ZeroCore/Adapters.swift` | Yes; structured runtimes implement it too. |
| Solo, Rex and Zero's own terminals as runtimes; every one drives a TUI by typing into it and scraping its screen | `SoloAdapter`, `RexAdapter`, `HostAdapter`, `TerminalAdapter.swift` | Yes, as the terminal path. Screen scraping is their ceiling. |
| zero-host: a detached helper that keeps pty terminals (Ghostty's engine) alive when Zero quits; `zero attach` | `ZeroHost/`, `Host.swift` | For now; its terminals move into zerod. |
| The bar (one dot per agent) and the floating inbox, composer, model selector | `ZeroApp/Inbox.swift`, `Selector.swift` | Yes. |

What is missing for the new direction: Zero only sees an agent through its screen. It cannot show tool calls,
command output, diffs or reasoning, and a reply is whatever text follows the echo of the last prompt.

## Layers

The work happens in **zerod**, a Rust daemon (`crates/zerod`). The Swift apps are clients of it: they show what it
sends and ask it to act. Rust because the daemon has to run where the apps can't: on Linux benches and other
machines as one static binary, and on the Mac whether or not any app is open, serving the Mac app now and iOS and
visionOS clients later over the same socket protocol. Codex is written in Rust and ACP has a Rust crate, so the
providers' own types are close at hand.

1. **Runtime**: the provider's own process (`codex app-server`, later `claude --print --input-format stream-json`,
   `opencode acp`), started by zerod through the login shell in the session's folder with a clean environment.
   Zero never re-implements a provider. It keeps the CLIs' sign-ins (`signins.rs`) and gives each process the one
   chosen for its task, as that CLI reads one (a token or key in its environment, a Codex account's home).
2. **Adapter** (`zerod/src/codex.rs`): one provider's protocol in, `Change`s to Zero's model out, with no I/O, so
   a live session and a replay of its transcript run the same code.
3. **Core** (`zerod/src/model.rs`, `session.rs`, `daemon.rs`): the provider-neutral conversation, its sessions and
   their lifecycle. Each session keeps a transcript of every line each way under `~/.zero/zerod/sessions/<id>/`;
   after a restart the daemon replays it, the session comes back offline with its history, and the next message
   resumes the provider's thread in a new process.
4. **Host** (`zerod/src/server.rs`): `~/.zero/zerod.sock`, owner-only, JSON lines. Requests answer by id;
   `subscribe` sends each session's snapshot, then every change numbered by a per-session `seq`, so a client's copy
   has no gaps or repeats and a client that falls behind gets a fresh snapshot.
5. **UI** (`apps/macos`): the bar, the inbox and the workspace window. They read `Conversation`s and never see a
   provider's protocol. An approval also becomes an `Ask` of kind `permission` in the inbox, so the bar's orange dot
   and the inbox work for every provider.

## The model

`Conversation` (`zerod/src/model.rs`, mirrored in Swift): one agent session. Its agent name (the same key the Store uses), provider, thread id, folder,
title, model, effort, status (`idle`, `working`, `waiting` for an approval, `offline`, `failed`), the active turn,
its items, and its open approvals.

`ConversationItem` kinds: user message, agent message (streamed), reasoning summary, plan, command (command, folder,
streamed output, exit code), file change (per file: path, kind, unified diff), tool call (MCP and others), notice
(errors, warnings, and any provider item Zero does not model yet, named by its provider type so nothing vanishes).
Each item has a status: running, done, failed, declined.

Provider-specific data stays available two ways: the session's transcript of every raw line, and `notice` items for
item types Zero does not model. Capabilities differ by provider; the UI shows what a conversation has rather than
assuming every provider has everything.

## Providers

Each provider has an adapter in `crates/zerod/src` behind one trait (`adapter.rs`): its protocol in, `Change`s out,
and the command line that starts it. Everything else (sessions, transcripts, replay, the socket) is shared. Each
runtime is the provider's own CLI, unmodified, signed in with the sign-in Zero hands it (`signins.rs`); zerod makes
no calls to any provider's service itself.

| | Runtime | Approvals | Mid-turn message | Resume |
|---|---|---|---|---|
| Codex (`codex.rs`) | `codex app-server`: JSON-RPC over stdio | `item/*/requestApproval`, with the decisions Codex lists (allow, always allow this command, allow for the session, deny, deny and stop) | `turn/steer` | `thread/resume` |
| Claude Code (`claude.rs`) | `claude -p` with stream-json both ways and `--permission-prompt-tool stdio`, as Anthropic's Agent SDK starts it | `can_use_tool` control requests: allow, Claude's suggested rule ("always allow Bash(make)", or edits for the session), deny, deny and stop | queued by Claude | `claude --resume <the session id Zero chose>` |
| OpenCode (`acp.rs`) | `opencode acp`: the Agent Client Protocol, handing the work to OpenCode's background service | `session/request_permission`, with OpenCode's options | refused: ACP takes one prompt at a time | `session/resume` |

Verified on 2026-10-26 by recording real sessions of each (tests/fixtures) and by `tests/e2e.rs` against the real CLIs.
What each one taught:

- **Codex** lists the decisions each request takes; for a command they were allow, always allow, and cancel, not
  the generic set.
- **Claude Code** routes permission prompts to Zero only with `--permission-prompt-tool stdio` (what the SDK passes);
  `--permission-prompts host` alone denied the write unasked. Its terms allow driving the unmodified `claude` with
  the user's own sign-in, and rule out the Agent SDK with a Claude subscription in someone else's product
  (code.claude.com/docs/en/legal-and-compliance). It doesn't echo the user's message, so Zero records what it sent.
  Effort is set at start; the model can change mid-session (`set_model`).
- **OpenCode** allows everything unless its config says `"permission": {"bash": "ask", "edit": "ask"}`; that config is
  read by its background service, so an environment variable set for `opencode acp` doesn't reach it. Zero leaves
  OpenCode's permissions as the user set them. Free models from the `opencode` provider need free endpoints allowed
  in the workspace's privacy settings; `opencode-go/beam-free` works as configured. Models and effort are session
  config options.

## Order of work

1. **Done.** The monorepo layout (README.md). zerod with Codex, Claude Code and OpenCode behind one adapter trait:
   start, stream, approvals with exactly the choices each provider offers, steer or queue, interrupt, stop,
   resume, transcripts replayed after a restart, the socket and its subscription. Tested on recorded sessions of
   each provider and against all three real CLIs.
2. The Mac app as a zerod client: start zerod from the app, a Swift mirror of `Conversation` fed by `subscribe`,
   every provider's approvals as permission asks in the inbox, and the workspace window (projects and sessions, the
   conversation with commands, diffs and reasoning, the composer with model and effort, steer and stop).
3. Move zero-host's terminals (Ghostty's engine has a C API) and then the asks store and the CLI socket into zerod,
   leaving Swift with the UI and a client.
4. The providers' own questions (Codex's `requestUserInput`, Claude's `request_user_dialog`) and MCP elicitations
   as Zero questions; zerod refuses them for now, with a notice in the conversation.
5. Other machines: zerod on the remote machine, reached through an SSH-forwarded socket, with commands and
   approvals only ever executed by the daemon that owns the session.
6. iOS and visionOS clients on the same protocol; one window per conversation on visionOS.
