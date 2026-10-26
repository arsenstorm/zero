# What zerod has to do

The backend requirements, ranked, from how Arsen actually works with agents and from what other tools and their
users show. Researched on 2026-10-26, from three sources:

- **Acme:** 283 Claude Code sessions (2026-09-25 to 10-26) and 1,213 subagent transcripts.
- **Everything else:** 56 personal Claude sessions, Codex rollouts, Zero's inbox log (270 asks, 10-20 to 10-26),
  Solo's projects and scratchpads, and Arsen's workflow skills.
- **The outside view:** the tools in the field, with GitHub issues and posts as evidence.

The numbers below come from those passes; "verified" marks what was checked against the code or a real run.

## How Arsen works, in numbers

- **Parallel, and switching constantly.** Median 1 live session and p90 4, peaking at 11. He types into 3
  sessions an hour (p90 5), and 45% of his consecutive messages go to a different session. About 120 messages a day.
- **A lead and its workers.** 13 lead sessions spawned 88 Solo agents (one lead spawned 30). Each worker is
  briefed with a file (BRIEF, FIX, VERIFY) and waits for its lead (p90 54 min). The coordination happens outside any
  agent runtime:
  - Solo scratchpads: 1,360 calls; 158 scratchpads hold plans and verify reports.
  - Solo idle timers: 250 `fire_when_idle_any`.
  - `send_input`: 303.
  - `bench` ledger: 444.
  - agent-events publishes: 125.
- **Long sessions.** p90 4–5.5 active hours; the longest ran 56 h, and personal sessions run 80–177 h. 78
  resumes came after more than 8 h idle, and there were 73 compactions.
- **Mid-turn steering.** 158 queued messages and 96 interrupts at Acme. 27% of his personal prompts were
  typed while the agent was working.
- **Auto mode, not prompts.** About 29,000 tool calls were accepted by Claude's auto-mode classifier and 58 approved by hand.
  The classifier's 110–170 blocks are the real gate: production reads, shared resources, destructive git and
  external writes.
- **What agents need him for:**
  - Scope and design decisions: 82 AskUserQuestion calls, with a p90 wait of 24 min.
  - His external writes: merge, ready, reviewers, Linear and Slack posts. Unauthorised ones are his most common
    correction.
  - Production reads: run by the agent 114 times, denied 15 times. He ran 73 `!` commands and pasted terminal
    output 81 times.
  - Hands-on chores: unlocking 1Password (19 commit-signing failures), Docker, Chrome, Vault.
- **Zero's inbox works for him.** He answers in 1–1.5 min (median), but 10% of asks wait 20–50 min and 22 expired on
  the 1 h limit. 19% were withdrawn because he answered in the chat. 64% of what agents send are notes.
- **What breaks:**
  - Usage limits: 16 sessions, and 4 of the 5 stalls Zero detected.
  - Model unavailable (20), not logged in (6), network (6).
  - Hangs noticed only when he asked: tests stuck 85 and 52 min, and 92 commands that hit their timeout.
  - Collisions: duplicate PRs, branches already checked out in another worktree (12), two agents fixing the same CI failure.
  - 163 `sleep && gh pr checks` polling loops, despite agent-events.

The wider field agrees on the same pains, in this order (sources in the research):

1. Usage limits.
2. Losing track of who needs you.
3. Review burden.
4. "Always allow" that doesn't stick.
5. Worktree cleanup.
6. Context loss.
7. Ports and dev servers.
8. Agents that conflict.
9. Agents that are stuck.
10. Remote access with privacy.

The providers now ship their own wrapper layer: Claude's agent view and daemon, and the Codex app's worktrees and
mobile control. Three third-party tools closed this year. Zero's room is the layer across providers: one inbox, one
usage view, worktree and port lifecycle, coordination of leads and workers, and native Apple clients.

## Requirements, ranked

Status is against `crates/zerod` today: done, partly, missing.

### A. Make a zerod session work the way his sessions work now

1. **Permission mode per session (done, 2026-10-26).** zerod's Claude sessions run in `default` mode (seen in the
   real end-to-end run), so every write and command would ask. The mode must be a session setting, with Claude
   defaulting to `auto` as his sessions do. Codex's equivalent is its approval policy and sandbox, and OpenCode's is its
   permission config. A classifier block should become "blocked: needs Arsen", not a bare notice.
2. **Zero's agent protocol inside zerod sessions (done: zerod gives the rules itself, through Claude's appended
   system prompt and Codex's developer instructions; OpenCode has no way over ACP).** zerod sets `ZERO_MANAGED=0` so the
   permission hook stands down, which also drops the session-start rules and the stop check. The agent's `zero`
   calls then arrive as `shell-<pid>`. Instead:
   - tell the hooks the session is zerod's: permission prompts go to zerod, while rules and notes stay;
   - give the session its identity (`ZERO_AGENT`, `ZERO_SESSION`), so its notes, asks and runs attach to it.
3. **The provider's own questions as asks (done for Claude and Codex; a real Claude round trip is in e2e.rs).** Claude's AskUserQuestion (82 at Acme and 16
   personal) and `request_user_dialog`, Codex's `requestUserInput`, ACP elicitation. Shape them on ACP elicitation
   plus choice options, so the inbox and the bar treat every provider the same.
4. **An attention state per session, kept on disk (done; the Swift app is held to zerod's table).** Needs you, working, done (ready for review),
   failed, stuck or limited. Every session gets a dot in the bar, not only ones with an ask. This is the field's
   number-two pain and his whole bar.
5. **Failures by kind, with what happens next (done: kinds and usage; resuming at reset is still to do).**
   - Usage limit, with its reset time: Claude reports `rate_limit_event`, verified in the fixtures; Codex has
     `account/rateLimits`; ACP sends `usage_update`.
   - Not signed in, network, model unavailable.
   - Each one offers an action: resume at reset, switch model, sign in with the CLI's own flow.
6. **Stall and hang detection (done: silence, long commands, repeats; a worker idle without reporting comes with step 3).** No progress for N minutes, repeated identical tool calls, a dead process,
   or a worker idle without reporting. Each raises the session to "stuck" in the inbox.

### B. Leads and workers, which is how most of his work runs

7. **Session metadata (missing).** Ticket, branch, bench or worktree, PR, role (lead or worker), parent, and a
   label Arsen sets. This prevents "wrong chat" and names workers by ticket, as Solo does.
8. **Sessions that start sessions (missing).** A lead spawns a worker with a brief, sends it a line or a file
   pointer, and is woken when the worker goes idle or reports. This replaces Solo timers, `send_input` and hf
   publishes for zerod sessions. It is exposed to agents through the `zero` CLI (or MCP), so a lead in any
   provider can use it.
9. **Events into a session (missing).** GitHub, Linear and Slack events from agent-events, queued into the session
   and delivered when it goes idle, plus "wake me when CI finishes" instead of polling loops. Bridge agent-events;
   don't rebuild it.
10. **A usage ledger across providers (missing).** Limits and use per account and provider from what each CLI
    reports, never from calls of Zero's own. Warn before starting more agents into a limit.

### C. The machine the work runs on

11. **Asks owned by the session's host (partly, in Swift).** The run, approve, choice and question asks move into zerod,
    so they execute on the host that owns the session. Run output is capped: 2.5 MB of it is in the log today. Expiry
    suits the ask: approvals wait a day, and an expired ask can be asked again.
12. **Worktrees and their runtime (missing).** Create from a base, run setup and archive scripts, never delete with
    unpushed work, clean up after crashes, and give each workspace its ports and env. Integrate `bench` (444 ledger
    calls) rather than replace it.
13. **Background processes per session (missing).** Tests, dev servers and monitors, with output, exit code and a
    hang timer (502 background runs, 358 completions).
14. **A checkpoint per turn (missing).** A git snapshot zerod owns, since Codex's revert leaves files and ACP has no undo.
    This is the base for review: the diff per turn, then PR and CI.
15. **zerod on other machines (missing).** Benches over SSH (554 workbench commands, drop clients already deployed),
    with an encrypted transport.
16. **A terminal for what has no protocol (missing).** Slash pickers, `!` commands. Terminals move from zero-host.

### Not now

- **Shared memory:** little demand anywhere.
- **What each provider already ships for its own agent:** Claude's agent view and Remote Control, Codex's
  automations.
- **Rebuilding Solo's scratchpads:** agents keep using them; zerod links them through session metadata.

## Risks

- **Terms.** zerod drives each provider's unmodified CLI on the user's own sign-in, which is Anthropic's stated
  exception. Headless `claude -p` is still a grey area for a product given to others: get written confirmation
  before distributing it. OpenAI says app-server sign-in "has never been permitted for commercial or hosted services"
  and calls the app-server experimental. Fine for Arsen's own use; it constrains any paid or hosted version.
- **Protocol churn.** Pin provider versions, generate Codex's schema in CI, keep the recorded-session contract tests,
  and record again on each upgrade. Claude's CLI control protocol has no official page.

## Order of work

Each step test-first, recorded against the real CLIs, and committed alone:

1. Requirements 1–2: permission modes, and Zero's protocol inside sessions.
2. Requirements 3–6: questions, attention state, failures by kind, stall detection.
3. Requirements 7–8: metadata, and leads and workers.
4. Requirements 9–10: events and usage.
5. Requirement 11: the asks store into zerod.
6. Requirements 12–16.
