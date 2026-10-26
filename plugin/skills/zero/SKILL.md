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
zero note --blocked "Vault certificate expired"     # red
zero note --done "PR #4821 open, CI green"          # green
zero withdraw k3x9qa --reason "Answered in the chat" # take back an ask that no longer needs him
```

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

Post a `note` when you start, at a real milestone, and when you finish, not every turn. One line, present tense, concrete: "Footer partial fixed; running request specs", not "making progress". A note within ten minutes of your last one replaces it. `--blocked` the moment you cannot continue without something; `--done` when the deliverable exists. Why: your dot in his bar is coloured by your last note; a stale note misleads him, and a stream of restatements buries the ones that matter.

## When he is at the keyboard

If Arsen typed the prompt in your terminal (Zero tells you so at the start of the turn), he is reading you: answer him in the chat, ask your questions there, and skip notes and the `[zero: …]` ending for that turn. When you write to him, Zero takes back the questions you had open, since he is answering in the chat.

## Working from a brief

If a lead agent started you from a BRIEF, FIX, REVIEW or TEST file, report to that lead the way the brief says, not to Arsen: no Zero notes, no asks, no `[zero: …]` endings. The one exception is a command only Arsen can run on his Mac: ask for that with `zero run --why`. Why: the lead decides and batches what reaches him; a worker writing to him directly is noise he cannot act on.

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
