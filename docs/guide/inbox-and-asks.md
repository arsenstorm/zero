---
title: The inbox and asks
description: Everything your agents ask you, in one place, and how to answer.
order: 3
---

When an agent needs something from you, it sends an ask: a question, a choice, an approval or a command to run on your Mac. Every ask lands in the inbox, from tasks in Zero and from agents outside Zero, such as Claude Code in a terminal. You answer it once, wherever you see it first.

<!-- figure: ask -->

## Open the inbox

Your asks show in two places:

- **The inbox panel**, beside the control bar on the right edge of your screen. Point at the tray icon at the top of the bar to peek at the panel, or click the icon to keep it open. A blue dot on the icon means at least one ask is waiting. See [The control bar](/docs/control-bar).
- **The Inbox page** in Zero's window. Click the tray icon in the window's left rail. Its tip reads **Inbox**. A red badge on the icon shows how many asks are waiting on you.

The **Inbox hotkey** works from any app: <kbd>⌥</kbd> <kbd>Space</kbd> unless you've changed it. It opens the inbox panel. To change it, see [Keyboard shortcuts](/docs/keyboard-shortcuts).

When **Bar in the window** puts the control bar in Zero's window, clicking the bar's inbox icon opens the Inbox page instead of the panel. Pointing at it still peeks at the panel.

## Read the inbox panel

The panel lists the asks waiting on you as cards, oldest at the top. Answers you've given since you opened the panel stay in the list until you open it again. When nothing waits, the panel shows **Inbox empty**.

Each card has:

- **The question** in bold. For a command, it reads **Allow this command?**
- **Who asked** under it: the agent's name, and the title it gave the ask.
- **About**, for an ask from a task in Zero: what the ask is about. It's the agent's words just before the ask, or a heading the agent named. Click it to open the task at those words, which light up for a moment. **Back to the ask**, at the top of the task's page, takes you back to the ask in the inbox. It shows only when the ask isn't docked on that page.
- **Why**, in the agent's words. Zero folds long text to three lines. Click it to read it all, and click again to fold it.
- **A command box**, when the ask is about a command. **Copy** copies the command. A long command shows **Show all** and **Show less**. When the command runs a script, the script shows under the command, with **Show the whole script** for a long one. When the command runs in a folder other than the agent's own, that folder shows under it.
- **The answers** as numbered rows, or a box for your reply.

Pull requests, commits, issues and Slack channels named in the question or the why are links, as they are in a conversation. See [Following and integrations](/docs/following-and-integrations).

Point at a card or click it to select it. When more than one ask is waiting, Zero dims the cards you haven't selected, so you can see which one your keys answer.

Pointing at an agent's mark on the bar instead shows just that agent. See [Read one agent's history](#read-one-agents-history).

## Answer an ask

Click an answer's row, or type its number.

- **Number keys.** In the panel, <kbd>1</kbd>, <kbd>2</kbd> and <kbd>3</kbd> pick the first three answers of the selected card. Every row shows its number, but only the first three answer from the keyboard. Click any row after the third.
- **Arrows.** <kbd>↑</kbd> and <kbd>↓</kbd> select the card above or below.
- **Typing.** Start typing and your words go into the selected card's reply box. When the card has an answer that ends in "…", such as **Suggest something else…**, that answer opens into a box and takes your words. When the card has neither, your words go into the message box of the agent you're looking at. <kbd>Return</kbd> puts the cursor in that box without typing anything.
- **Sending.** Press <kbd>Return</kbd> in a reply box to send, or click the paper plane at its right. Paste an image with <kbd>⌘</kbd> <kbd>V</kbd> and its file path goes into your reply, for the agent to open.

Once you pick an answer:

1. The row turns orange with a spinner. For a moment, you can take it back. See [Take an answer back](#take-an-answer-back).
2. The row turns green with a tick once the agent has it. The other rows fade.
3. When Zero can't reach the agent, the row turns red with a cross. Point at it to read **Couldn't reach the agent. Click to try again.**, and click it to send the answer again.

Three seconds after your answer lands, the panel selects the next waiting ask.

Press <kbd>Delete</kbd> to remove a finished card from the panel.

## Take an answer back

Picked the wrong answer? Press <kbd>Esc</kbd> in the inbox panel while the row is still orange. The card goes back to waiting, with nothing chosen, and you can answer again.

You have 2 seconds unless you change it. Set the time in **Settings › Inbox and bar › Answers › Undo an answer**: **Off**, **1 s**, **2 s**, **3 s** or **5 s**. At **Off**, every answer goes at once.

Taking back works only in the inbox panel. Once the row turns green, the agent has your answer.

## The kinds of ask

### A question

The agent asks something and waits for your words. The card shows the question and a box that reads **Reply to** and the agent's name. Type your answer and press <kbd>Return</kbd>.

### A choice

The agent asks a question with answers to pick from, each a numbered row. Picking an answer that ends in "…" opens a box so you can say more, and the agent gets the answer and your words together.

One choice has its own look: **Is this task done?**, in purple, with **Done** and **Not yet…**. An agent asks it when it isn't sure its work is finished. **Done** marks the task done. **Not yet…** opens a box to say what's left.

### An approval

The agent asks whether it can do something, such as "Delete the old build folder?". The answers are **Yes**, **No** and **Suggest something else…**. Both **No** and **Suggest something else…** count as declining.

Zero sends one approval of its own: **Sign in to** and an MCP server's name, when a task needs you to sign in to that server. Click **Open the sign-in page** and sign in on this Mac, or **Not now**. See [Browsers and MCP servers](/docs/browsers-and-mcp).

### A command to run

The agent wants to run a command on your Mac and see its output. The card reads **Allow this command?**, with the command in a box and why the agent needs it above. The answers are:

| Answer | What it does |
|---|---|
| **Run** | Runs the command on your Mac. |
| **Run, and allow the same for this task** | Shows only when the agent offers it. Runs the command, and later commands of the same kind from the same task, in the same folder, run without asking. "The same kind" means the same command with a different file path after it. |
| **Reject** | The command doesn't run. |
| **Suggest something else…** | Opens a box to tell the agent what to do instead. The command doesn't run. |

While the command runs, the card reads **Running command…** and its output scrolls in the box. **Stop**, in red, stops it. **Terminal** follows its output in your terminal app.

Then the card reads **Ran command**, **Command failed (exit** and its exit code **)**, or **Command rejected**. When Zero lost track of the command while it ran, the card reads **Lost track of the command**, with **Lost: check what it did before running it again** under it.

When several agents ask for the same command in the same folder, they share one card. Its byline reads, for example, "and 2 other agents". One answer goes to all of them.

### A command for you to run yourself

Sometimes the agent can't run a command itself, for example because it has to run on another machine. The card then shows two steps:

1. **Run this**, with the command. Click **Copy**, run it where it needs to run, and copy what it printed.
2. **Then tell** and the agent's name. Click **Paste output** to put what you copied into the reply, then press <kbd>Return</kbd> to send.

### A note

A note tells you where an agent stands. It needs no answer and never shows in the inbox's list. Notes show in the agent's view in the panel. A note that says the agent is blocked has a red **Blocked** label.

### A permission

Before a tool acts, the agent's CLI can ask for your permission. Zero turns the request into an ask.

When Claude Code runs in a terminal that Zero starts, the question says what Claude Code wants to do, such as **Run a command?**, **Edit a file?**, **Write a file?** or **Fetch a page?**. The box shows the command, file or address.

The answers are **Allow**, **Always allow**, **Deny**, and **Deny, and say why…**. **Always allow** shows only when Claude Code suggests a rule to remember. Only the **Deny** answers count as declining.

From a task in Zero, the question reads **Allow this command?** or **Allow these changes?**, and the answers are the agent's own:

| Agent | Answers |
|---|---|
| Claude Code | **Allow**, **Deny** and **Deny and stop**. When Claude Code offers one, also **Always allow** and the rule, or **Allow all edits this session**. |
| Codex | **Allow**, **Allow for this session**, **Deny** and **Deny and stop**. When Codex offers it, also **Always allow** and the command. |
| OpenCode | OpenCode's own answers |

## Answer in a task's conversation

When a task in Zero asks you something, its ask also shows in the task's conversation, docked above the composer. It's the same ask: answer it here or in the inbox, and it's answered in both.

The strip at the top of the docked card says what it is:

- **Question**, or **Questions** when the agent asks several at once. When the agent gave a question a heading, the strip shows that instead.
- **Approval**, with a shield, when the agent's CLI asks permission.
- **Run on your Mac**, **Approval** or **Question** for asks the agent sent through Zero.

One card shows at a time. When several are waiting, the strip shows where you are, such as **1 of 3**, with arrows to step between them.

To answer from the keyboard:

- When the composer is empty, type <kbd>1</kbd> to <kbd>9</kbd> to pick that answer of the first ask the agent sent through Zero. This doesn't work while the CLI's own question or permission request is docked.
- On a permission request, <kbd>Return</kbd> picks the first answer when you're not typing in the composer.

A permission request folds a long command after eight lines. To read the rest, click **Show all** and the number of lines.

Some questions ask for a secret, such as a password. The agent asks these only in the task's conversation, never in the inbox, as a form with a **Secret** box and an **Answer** button. The form also shows for a question before it reaches the inbox, with the answers as buttons and a box that reads **Your answer** or **Or say something else**.

In the conversation itself, each ask the agent sent through Zero is a step that reads **Asked**, or **Asked to run** for a command, then what it asked. At its right is what became of it: **Waiting on you**, **Running**, **Ran**, **Failed (exit** and the code **)**, **Declined**, **Expired**, or the answer you picked.

## Find answered asks on the Inbox page

The Inbox page in Zero's window lists every ask in a table. To open it, click the tray icon in the window's left rail. It always opens on **Waiting on you**.

Its sidebar has:

- **Waiting on you**, with how many: the asks waiting, oldest first.
- **Answered**: up to 50 asks you've answered in the last day, newest first.
- **Agents**: one row for each agent that has asked you something. A blue dot and a count mean that agent has asks waiting, and a grey dot means none. Click an agent to see its waiting asks, then its answered ones.

The table's columns are:

| Column | What it shows |
|---|---|
| **Ask** | The ask's title. |
| **Agent** | The agent that asked. |
| **Kind** | **Question** for questions and choices, **Approval** for approvals and permissions, **Command** for commands to run. |
| **When** | When it was asked, in blue while it waits, then when it was answered once it's done. A declined ask adds **· declined**. |

Click a row to open its card under it, and answer it there as in the panel. The oldest waiting ask opens on its own. Click the × at the card's right to close it. Its tip reads **Fold it back**. The number keys, and <kbd>Esc</kbd> to take an answer back, work in the inbox panel, not on this page.

## Read one agent's history

Point at an agent's mark on the control bar, or click it, to see just that agent in the panel. From the top:

- **Earlier**: a short list of what came before, newest at the bottom. It shows six rows at a time and scrolls. Each row has how long ago it was, an icon for its kind, and one line. The line is **You:** and your message, the agent's name and its note, or an ask with what became of it: **· rejected**, **· ran, exit 0**, or the answer. **Closed** marks where the agent was removed or went offline.
- **The latest exchange**: your last message, and what the agent has said since. While it works on your message, a row reads the agent's name and **is working…**.
- **The latest answer**, for a task in Zero, when it's newer than the task's last ask or note. The card shows the task's name, how long ago it answered, and the first part of the answer. **Open task** opens it in Zero's window.
- **The asks still waiting** from this agent.
- **A message box**, **Message** and the agent's name, when Zero can reach the agent.

Click a row in **Earlier** to read it in full under the list: the whole message, or the ask with its answer and, for a command, its output. Click it again to close it. To start a message that quotes a row, point at it and click the arrow at its right. The arrow's tip reads **Reply to this**.

When nothing has come from the agent yet, the panel reads **Nothing from this agent yet**.

## When an ask expires

An ask you don't answer in time expires and leaves the inbox and the Inbox page. In a task's conversation, its step reads **Expired**.

| Ask | Expires after |
|---|---|
| Asks where the agent set no time | 1 hour unless you change **Unanswered asks expire after** |
| Asks where the agent set its own time | The agent's time |
| Permission requests from a task in Zero | 24 hours |

To change the default, go to **Settings › Inbox and bar › Answers › Unanswered asks expire after**: **15 min**, **1 h**, **4 h**, **1 day** or **Never**.

An agent can also withdraw an ask it no longer needs, and it leaves the inbox the same way. When the ask was a command that's running, the command stops.

## Get told when an ask arrives

How you hear about a new ask depends on where you are:

- **In Zero**, with Zero in front and you at the Mac: a sound plays and the control bar shows the ask.
- **Away from Zero**, in another app, away from the Mac or with the screen locked: a macOS notification. For an agent outside Zero, it's titled with the agent's name and shows the question, **Wants to run:** and the command, or **Wants your approval:** and what it wants.

An ask from a task in Zero counts as the task's notification. The task's state turns to **Needs you**, and you hear the sound for that state. Clicking a task's notification opens the task in Zero's window. While you're in Zero, a task that needs you plays its sound. When it still needs you five minutes later and you haven't used the Mac since the sound, the notification goes too.

A notification goes away by itself when you answer or the ask expires or is withdrawn. It also goes when you look at the task, the inbox or the agent.

While Zero's window is open, Zero's icon in the Dock shows how many tasks need you.

These settings are in **Settings › General**. Open Settings with <kbd>⌘</kbd> <kbd>,</kbd> or the gear at the foot of the window's left rail.

| Setting | Where | What it does |
|---|---|---|
| Needs you | Settings › General › Notifications | Tells you when a task, one of its workers, or an agent outside Zero asks you something, or a task is over to you. On by default. Its sound chip sets the sound: **Blow** by default, or **None** for no sound. Asks from agents outside Zero play **Glass** while you're in Zero. |

macOS's own settings for Zero, and Focus, can quiet its notifications as they do for any app.

## Settings for the inbox

Most are in **Settings › Inbox and bar**.

| Setting | Where | What it does |
|---|---|---|
| Undo an answer | Settings › Inbox and bar › Answers | How long <kbd>Esc</kbd> can take an answer back: **Off**, **1 s**, **2 s**, **3 s** or **5 s**. **2 s** by default. |
| Unanswered asks expire after | Settings › Inbox and bar › Answers | How long an ask waits when the agent set no time: **15 min**, **1 h**, **4 h**, **1 day** or **Never**. **1 h** by default. |
| Inbox hotkey | Settings › General › Zero | The keys that open the inbox, from any app. <kbd>⌥</kbd> <kbd>Space</kbd> by default. |

Zero records every ask and answer in `~/.zero/asks.jsonl`. To open it, right-click the control bar and choose **Open log**.

The iPhone app, coming soon, shows the same asks and has a **Take back** button on an answer you've just picked. See [The iPhone app](/docs/iphone).
