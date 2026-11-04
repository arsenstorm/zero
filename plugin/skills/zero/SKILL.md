---
name: zero
description: Reach Arsen through Zero, his Mac inbox for agents — ask a question, get a go, have him run a command on his Mac and receive its output, or post where you are. Use whenever you would otherwise write "pending Arsen" or "waiting for your go", print a command for him to paste into his terminal, or stop until he answers; when a decision changes scope or touches production; and to report that you are blocked or done. Triggers on: zero, /zero, ask Arsen, needs Arsen, pending Arsen, approval, production read, run this on your side.
allowed-tools: Bash
---

# Zero

Zero is the only way a need for Arsen reaches him. An ask written into a plan or a transcript waits until he happens to read that session; a `zero` call pings him, and his answer comes back to you on stdout. Never park a need for Arsen in text.

## What do you need?

```
Something only Arsen can produce
├── A command you can't or mustn't run yourself: blocked or denied, needs his Mac, his credentials or
│   production access (a production count, a console read, a tunnel) → zero run --why
├── A fact behind his access (a production count, a console read, a tunnel) → zero run --why
├── A yes or no on a plan, a PR, a scope change → zero approve
├── A pick between concrete alternatives → zero ask --option A --option B
└── Words: a decision you cannot frame as options → zero ask "question"
Nothing from him, only where you are → zero note
```

If you can decide it yourself from the ticket, the code, or the conventions, decide. Why: every ask costs him a context switch; an ask he could not have answered better than you is pure cost.

## Commands

```bash
zero ask "Which count should scope ENG-9429?" --option "Sources on free teams" --option "All sources" --option "Something else…"
zero approve "Open the PR as draft now" --body "3 files, specs green on bench-3"
zero run 'bin/production console <<< "puts Source.count"' --cwd "$APP_PATH" --title "ENG-9429 scope" \
  --why "How many sources exist decides whether the fix needs a migration"
zero note "Specs green; sizing the fix"            # working (blue)
zero note --blocked "CI is down on main"            # grey: stopped on something that isn't him
zero note --done "PR #4821 open, CI green"          # green
zero note --done "PR #4821 open, CI green" --needs "mark it ready and merge"   # teal, over to him: done, a step only he can take
zero note --completed "PR #4821 merged, QA passed, ticket closed"   # done-done: nothing left; archived after a while
zero withdraw k3x9qa --reason "Answered in the chat" # take back an ask that no longer needs him
zero close 01a1886cb3e40000                          # a worker you started, once you've read its result: off his board
```

Workers you start with `zero spawn` stay on his board until closed. Close each one with `zero close` once you have read its result (`zero result`) and need nothing more from it; a worker you may send back to stays. Why: his sidebar lists every open session under you, and finished reviewers and runners left open bury the ones that matter.

Every call blocks until he answers and prints the answer on stdout. Exit 0 answered, 2 declined (the reason, if any, on stderr), 3 expired. For `run`, stdout is the command's output and the exit code is the command's own.

Blocking is the default because you need the answer to continue. When you cannot hold a shell open, as a Solo agent that must end its turn, use `--async` to get an id back, then `zero wait <id>` when you resume. Put the id in your hand-off message, so the transcript records what was asked.

## Writing the ask

- The question is the headline: one line, under twelve words, ending in a question mark ("Commit the reworked title morph?"). Everything else (what you changed, how to check it, what's queued next) goes in `--body`, which shows in smaller text beneath it. Zero refuses a question over 140 characters. Why: it is read in a card beside a dozen others, at a glance; a paragraph as the headline buries the one thing he must decide.
- `--body` is two or three plain sentences, 280 characters at most: what the problem is, what you recommend, and what it costs or risks. Zero refuses longer. Anything more (the full diff, the log, every case you checked) goes in a file; give its path. Why: he decides from the card; detail he has to dig through is detail he skips.
- Write like you would say it to him: whole words and ordinary sentences. No abbreviations, no semicolon chains, no shorthand like "pre-fix cb grants [d,p] grp", no file:line lists unless the line is the point. Why: he reads a dozen cards at a glance, often between other things; a sentence he has to decode costs more than a longer one he doesn't.
- Lead with what he needs to decide or know, not the history of how you got there.
- A command, a snippet, or a path goes in `--code`, never in the question text. Why: Zero shows code in a monospace block; in prose it reads as a sentence and is easy to misread.
- `--title` is the ticket id or the feature name, two or three words. It is context in the card's header, not a sentence.
- Choices go in `--option`, never as (a)/(b)/(c) in the question: Zero refuses those, since he can only answer them by typing.
- Two or three options. The first is the one you recommend. When you want his words, make the last option end with `…` ("Something else…"): picking it opens an input and his text comes back as `label: text`. Never make the only decline path a typed one. Why: he must be able to say no in one key press.
- One decision per ask. Three questions in one card get one answer.
- Never ask the same thing twice. If he declined, do what the decline says or stop and report.
- When an open ask no longer needs him (he answered in the chat, your lead decided, the PR got merged), `zero withdraw <id>` it. Never write "you can ignore it": a card left open is one he may still answer, late and wrongly.

## Running on his Mac

`zero run` executes the exact command in an interactive zsh on his Mac after he presses one key, so his PATH, rbenv and `op` apply. Use it for reads he alone can perform, and whenever a command you need was blocked or denied. Never print a command for him to paste, and never stop because a command was refused: ask with `zero run`. Never put a write to production in a `run`; ask for approval of the plan instead and let him run that himself. One command per ask. Pass `--cwd` so relative paths resolve where you mean.

When the command is a script file (`sh path/to/script.sh`), Zero shows him its contents, so he can read what he approves. Never offer a command you haven't checked exists: a missing script comes back as exit 126 and wastes his approval.

`--why` is required: one sentence on what the output is for and what you will do with it. Why: he is about to run something on his own machine; a command without a reason is one he cannot judge, so he rejects it.

When Zero runs your session, Claude Code's own permission prompts reach him in Zero too: the tool call waits until he allows or denies it, and the card shows your latest words as the reason. So say why before a call that may need permission.

## Where you are

Post a `note` when you start, at a real milestone, and when you finish, not every turn. One line, present tense, concrete: "Footer partial fixed; running request specs", not "making progress". A note within ten minutes of your last one replaces it. Three different things stop you, and he sees each differently. Needing him (an answer, a decision, access, an approval) is an ask: `zero ask`, `approve` or `run`, which shows as Needs you (red), the one state that calls him. Waiting on something that isn't him (CI, another team, a deploy, an outage) is `--blocked` with what you wait for: Blocked (grey), which asks nothing of him. Done, with a step only he can take (a merge, a QA pass, a deploy), is `--done` with `--needs "…"`: Over to you (teal), a to-do rather than a decision. `--done` alone when the deliverable exists (green), whatever still follows it (a merge, QA, a review); `--completed` only when the whole task is done-done: shipped, checked, nothing left for anyone, as Zero archives a completed task after a while (`--merged` means the same). Leave `--needs` off when nothing is his; a later note without it clears it. Why: your dot in his bar and your row on Zero's board are coloured by your asks and notes; a stale note misleads him, and a stream of restatements buries the ones that matter.

A need written only in prose ("could you reopen OrbStack?", "waiting for your go") reaches no board: when you stop because you need him, ask him (`zero ask … --async`, then end with `[zero: asked <id>]`); when it's his step after you're done, post `--needs "…"`; do it even when he is chatting with you in Zero. Why: his sidebar and board colour your task from your notes and your ending, not from your words.

## When he is at the keyboard

If Arsen typed the prompt in your terminal (Zero tells you so at the start of the turn), he is reading you: answer him in the chat, ask your questions there, and skip notes and the `[zero: …]` ending for that turn. When you write to him, Zero takes back the questions you had open, since he is answering in the chat.

## Working from a brief

If a lead agent started you from a BRIEF, FIX, REVIEW or TEST file, report to that lead the way the brief says, not to Arsen: no Zero notes, no asks, no `[zero: …]` endings. The one exception is a command only Arsen can run on his Mac: ask for that with `zero run --why`. Why: the lead decides and batches what reaches him; a worker writing to him directly is noise he cannot act on.

## Leading workers

When a task is more than one agent's work, start workers, not subagents. A worker is a Zero session of its own: it survives Zero's restarts (a subagent dies with your turn), it shows on the user's board under you, and it reports to you.

```bash
zero spawn "ENG-9790: clamp the live timer" --brief briefs/ENG-9790.md --cwd /work/eng-9790 --model opus --effort medium   # prints its id
zero wait 01a1… 01a2… [--any]           # until they stop: finished, failed, stuck, or waiting on the user
zero result 01a1…                       # its last answer: its report
zero send 01a1… "Row 10 fails on the bench; fix it and report again"
zero workers                            # yours, with their states
zero attr PR https://github.com/org/repo/pull/12 --session 01a1…   # for the user to see on its task
zero close 01a1…                        # read, nothing more needed: off the board
```

A worker you want held, for the night or until something else lands: `zero pause 01a1…` asks it to wrap up, stops it and keeps it parked, whatever arrives for it; `zero unpause 01a1…` picks it up again, with what waited for it.

- A worker is in your workspace wherever its folder is; `--workspace ID` puts it in another (`zero workspaces` lists them), as when the user runs you from their default workspace to work in a different one.
- One worker per unit of work: a ticket, a review, a test run. Its brief says what to do, where, what counts as done, what it must not do (merge, publish, write anywhere outward), and that its final answer is its report to you. A worker's answer reaches you when it ends; you don't poll.
- Workers report to you, not to the user. You batch what reaches the user: one ask per decision, the workers' findings behind it, one note per milestone. A worker that needs the user goes through you, except a command only the user's Mac can run, which it asks with `zero run --why`.
- `zero wait` to wait, `zero result` to read, `zero send` to answer a worker's question or send back findings; it resumes where it was. A worker may start workers of its own the same way (a reviewer, a runner) and closes them when it has read them.
- Close a worker once you have read its result and need nothing more from it. Keep one you may send back to. Set `zero attr` for what the user should see on the task (its PR, say) as soon as it exists.
- Zero's restarts pause a worker's turn and carry it on; nothing is lost and nothing needs redoing. Never put work that must outlive your turn in a subagent.

### Tables

When you have a table for the user (a batch's tickets, a round's findings), hand it to Zero instead of writing one in Markdown: `zero table "Batch" --column Task --column State --column "Needs you" --row "ENG-9790 | working | –" --row "ENG-9793 | blocked | the OrbStack update"`, or the same as JSON on stdin (`{"title", "columns", "rows"}`). Zero draws it in your conversation with its own parts: a cell that is a state (working, blocked, done, merged, waiting) shows as the board's pill; in a column named for a risk ("Merge risk"), a cell opening with low, medium or high shows that as a green, amber or red pill, the rest of the cell on hover (the merge-risk skill's line fits it); a ticket or a PR as a link. Then say in a sentence what it shows. Why: a Markdown table with emoji reads differently in every client; Zero's reads the same everywhere and links where it should.

### Loops

A loop is a named instruction the user keeps in Zero and names as `@name`. When your prompt or brief named one, Zero gave you its words in its place, under "Loop: name". An `@name` inside those words is a child loop, a reference and not its text: it is what the workers for that step follow. Start each such worker with `zero spawn "…" --loop name`, and Zero heads the worker's brief with the child's words. `zero loops` lists the loops; `zero loop name` prints one, if you need to read a child before starting on it. Follow a loop as written; where it leaves a choice, decide as the brief and the ticket say.

## Saving for later

Zero's Later is the user's list of work they'll come back to. Save one when the user asks ("save this for later", or Zero's message saying they want it saved), with `--asked`. Otherwise save only when you're stopping work the user will want to resume, a plan for another day; that's a suggestion, which the user keeps or dismisses, and goes in a week if they don't. A task has at most three open.

Not for Later, as it fills the user's list with things they can't act on:
- Ticket ideas and bugs you noticed along the way: tell the user in your answer, or put them in one item with the work they belong to.
- Reminders to yourself (re-run a check at 23:45): schedule them, below.
- What needs the user (a decision, a step only they can take): ask them with `zero ask`.

```bash
zero later save "Fix the flaky login test" --asked --file - --link https://github.com/o/r/issues/12 <<'EOF2'
## Cause
A race in `app/auth.rb:42`: …
EOF2
zero later list                  # what's saved, open first
zero later view k3x9qa           # one item in full: note, links, files, artifact
zero later edit k3x9qa --file -  # a new version (earlier ones are kept)
zero later done k3x9qa
```

Each item has two parts, written for different readers:

- The note: a headline under 100 characters, in plain words, saying what's to be done. No ticket ids, file paths, dates or numbered lists; zero refuses a longer one. Why: the user reads the list at a glance, and a note they have to decode is one they skip.
- The artifact: everything you worked out, in full, in Markdown: findings, causes with file:line, the plan, commands, what you ruled out. Nothing summed up. Why: whoever picks it up later, often a fresh agent, has only this.

Attach screenshots or files with `--attach`. Tell the user the item's link (zero://later/<id>). Given an item to pick up, read it with `zero later view` first, and mark it done with `zero later done` once it is.

## Waking yourself later

When something needs checking at a time (tomorrow's 05:12 UTC scan, a deploy in an hour), schedule it instead of noting it somewhere and hoping: Zero wakes this task then, saying `Scheduled: <your words>`, resuming it if it's parked, and keeps the schedule across its own restarts. Write the words for yourself then: what to check and what you expect.

```bash
zero schedule "Check tomorrow's Image Scan for OPS-3154 lists no OS packages" --at 05:30Z
zero schedule "Look at the ENG-9818 deploy's error rate" --in 90m
zero schedule list                # this task's
zero schedule cancel k3x9qa
```

--at takes your clock's time (05:30, the next one), UTC (05:30Z) or a date (2026-11-05T05:30Z); --in takes 90m, 2h, 1d. End your turn after scheduling: there's nothing to wait for until then, and your row shows when you wake.

## The browser

Zero gives you Chrome through its MCP server's `browser_` tools (or `zero browser <tool> '<json>'`): the same tools as Claude in Chrome, under Zero's names. Use them for anything in a browser; in Zero your provider's own browser tools (Claude in Chrome, Codex's browser) are off, and a headless browser of your own (Playwright and the like) is only for tests that need one. Your task has tabs of its own, in a group in the user's Chrome window (the one they used last), opened in the background so their view stays theirs; `browser_tabs` with `createIfEmpty` gives you one. If you'd get in their way (many tabs, a long run) or need a clean session, ask for `window: "own"` (a window of your team's, behind theirs) or `"incognito"` (private, no sign-ins); your later tabs go there too. The group's title shows your state to the user: 🚧 working, 🙋 needs them, ⛔ blocked on something else, ✅ done. Read a page with `browser_read` (elements with refs) or a screenshot (`browser_computer`), act with `browser_computer`, `browser_form` and `browser_navigate`, and batch steps you can foresee with `browser_batch`. Close the tabs you opened when you're done. A tab the user gave you from the extension also shows in `browser_tabs`; closing it gives it back.

The user's blocked sites are refused. In auto mode, opening a site new to the task gets a reviewer's opinion first; if it advises against one the task needs, ask the user with `zero approve "Open <site> in Chrome"` and pass the ask's id as `approval` to `browser_navigate`. Never type the user's passwords or card numbers: ask them to do it.

## Following

Follow what you take ownership of, the moment you take it: the pull request you open or are asked to babysit, the ticket you pick up (or just the comment thread you were pointed at), the Slack thread whose link you were given. Zero reads it every minute and tells you what changed between your turns (a review, a comment, a failed check, a merge, a status change, a reply), waking you if you were parked. So end your turn instead of polling or sleeping; you'll be told.

```bash
zero follow https://github.com/org/repo/pull/42          # or github/org/repo/42
zero follow https://linear.app/team/issue/ENG-9429/...#comment-abcd1234   # one thread; without #comment, the whole issue
zero follow slack/C0123ABCD --mine                        # a busy channel: only messages naming your pull requests
zero following                                            # what you follow, and whether reading it works
zero unfollow github/org/repo/42                          # or --all
```

Events arrive as a message from Zero starting `N new events on what you follow`, grouped by topic with each event's text and link. In a channel followed with `--mine` or `--about`, a sender's message that names nothing (no pull request, ticket or link) is read as continuing that sender's last message that did, for half an hour, and comes marked so: a deploy bot's "Deploy complete" after its "Deploying … (#42)" reaches you as #42's. `(you)` marks events by the user's own account: often your own action echoing back (your comment, your push), so skip those unless it is something you didn't do. Unfollow what you are done with (merged, closed, resolved): follows outlive your memory of them, which is the point, so prune them.

## Away from Arsen's Mac

Zero's own `zero` binary speaks to the app over a socket, so it only works on his Mac. Anywhere else, Zero
reaches you through a drop folder: a folder the Mac keeps in sync with where you are (on a Acme bench,
`<app>/.zero/` inside each app checkout). Zero puts a `zero` client in it; call that one, same commands, same
exit codes:

```bash
export PATH="$PWD/app/.zero:$PATH"   # once, from the bench root; any app's .zero works
zero note "Claimed the bench; reading the ticket"
```

Answers take a few seconds longer than on the Mac: the files ride the sync both ways. Never create the drop
folder yourself and never write into `asks/` or `answers/` by hand; the client does, atomically, and Zero
removes what it has consumed.

## Identity

Zero names you by `ZERO_AGENT`, or by your Solo process id. If neither is set, export `ZERO_AGENT` once at the start to a stable short name: the ticket id or your role (`ENG-9429`, `app-lead`). Why: one dot per name; a changing name scatters your history across several dots.

## Ending a turn

When Zero runs your session, every turn ends with exactly one of these as its last line, after you have done what it says. Zero's stop check reads it; a turn without one is sent back to you.

```
[zero: done]            the work is finished and you posted zero note --done
[zero: asked k3x9qa]    you asked with --async and wait for that answer (the id it printed)
[zero: blocked]         you cannot go on because of something that isn't him, and posted zero note --blocked
[zero: working]         you are pausing between steps and posted a note on where you are
```

Why: a need parked in prose ("waiting for your go") reaches no one. The ending line makes the state explicit, so Zero can tell a finished turn from a stuck one.

## Messages from Arsen

He can type to you from Zero at any time. His text arrives as a prompt in your session. Treat it as an instruction that supersedes the brief.
