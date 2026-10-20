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
├── A fact behind his access (a production count, a console read, a tunnel) → zero run
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
zero run 'bin/production console <<< "puts Source.count"' --cwd "$APP_PATH" --title "ENG-9429 scope"
zero note "Specs green; sizing the fix"            # working (blue)
zero note --blocked "Vault certificate expired"     # red
zero note --done "PR #4821 open, CI green"          # green
```

Every call blocks until he answers and prints the answer on stdout. Exit 0 answered, 2 declined (the reason, if any, on stderr), 3 expired. For `run`, stdout is the command's output and the exit code is the command's own.

Blocking is the default because you need the answer to continue. When you cannot hold a shell open, as a Solo agent that must end its turn, use `--async` to get an id back, then `zero wait <id>` when you resume. Put the id in your hand-off message, so the transcript records what was asked.

## Writing the ask

- The question is the headline, under twelve words, ending in a question mark. Why: it is read in a card beside a dozen others, at a glance.
- A command, a snippet, or a path goes in `--code`, never in the question text. Why: Zero shows code in a monospace block; in prose it reads as a sentence and is easy to misread.
- `--title` is the ticket id or the feature name, two or three words. It is context in the card's header, not a sentence.
- Two or three options. The first is the one you recommend. When you want his words, make the last option end with `…` ("Something else…"): picking it opens an input and his text comes back as `label: text`. Never make the only decline path a typed one. Why: he must be able to say no in one key press.
- One decision per ask. Three questions in one card get one answer.
- Never ask the same thing twice. If he declined, do what the decline says or stop and report.

## Running on his Mac

`zero run` executes the exact command in an interactive zsh on his Mac after he presses one key, so his PATH, rbenv and `op` apply. Use it for reads he alone can perform. Never put a write to production in a `run`; ask for approval of the plan instead and let him run that himself. One command per ask. Pass `--cwd` so relative paths resolve where you mean.

## Where you are

Post a `note` when you start, at each milestone, and when you finish. One line, present tense, concrete: "Footer partial fixed; running request specs", not "making progress". `--blocked` the moment you cannot continue without something; `--done` when the deliverable exists. Why: your dot in his bar is coloured by your last note; a stale note misleads him.

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
[zero: blocked]         you cannot go on and posted zero note --blocked
[zero: working]         you are pausing between steps and posted a note on where you are
```

Why: a need parked in prose ("waiting for your go") reaches no one. The ending line makes the state explicit, so Zero can tell a finished turn from a stuck one.

## Messages from Arsen

He can type to you from Zero at any time. His text arrives as a prompt in your session. Treat it as an instruction that supersedes the brief.
