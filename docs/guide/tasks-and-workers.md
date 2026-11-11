---
title: Tasks and workers
description: Start a task, talk to it while it works, and follow the workers it starts.
order: 2
---

A task is one agent working on one job for you, such as "Fix the flaky login test". It runs Claude Code, Codex or OpenCode in a folder on your Mac. You start, read and steer tasks in Zero's window. A task can also start workers: tasks of its own, each taking part of the job.

To open the window, choose **Show Zero** from the menu bar icon. While that menu is open, <kbd>⌘</kbd> <kbd>0</kbd> does the same. The rail runs down its left edge. Next to it, the tasks sidebar lists the tasks in the workspace you're looking at.

## Start a task

1. Click **New task** at the top of the tasks sidebar, or press <kbd>⌘</kbd> <kbd>N</kbd>. The **Home** button at the top of the rail opens the same page.
2. In the box that says **Do anything**, write what you want done. Paste or drop images into it too.
3. Check the chips under the box:
   - **The project**: the folder the task starts in. Click it to pick another from **Projects**. Zero lists the folders you added in **Settings › Folders › Projects**. Until you add a folder, **Add a project in Settings › Folders** shows in place of the chips. See [Workspaces and folders](/docs/workspaces-and-folders).
   - **The workspace**: shown only when you have more than one workspace. The task and every worker it starts go into the workspace you pick here. It starts as the workspace you're looking at.
   - **The agent**: the model and effort, such as "Opus 5.5 · High", with the provider's mark as its icon. Click it to pick a provider from the tabs at the top, a model from the list, and an effort with the **Effort** slider. With no model picked, the task starts on the provider's first model. OpenCode starts on the model set in its own config.
   - **Permissions**: an icon with no label. Point at it to see **Permissions: Auto** or **Permissions: Unrestricted**.
4. Click the paper plane, or press <kbd>↩</kbd>. The task starts and opens.

The two permission modes:

| Mode | What the agent can do |
|---|---|
| **Auto** | The default. The agent's CLI decides what's safe and asks you about the rest. Its requests reach your inbox. |
| **Unrestricted** | Anything, without asking. An orange bolt marks the task wherever its permissions show. |

Zero keeps what you write on this page as a draft until you send it, and remembers the provider and project you used last. For accounts and models, see [Accounts and models](/docs/accounts-and-models).

## Find your tasks in the sidebar

The tasks sidebar shows, from the top:

- **The workspace's name.** Click it to switch workspace, make one with **New workspace…**, or open **Workspace settings…**.
- **New task** and **All tasks**. All tasks opens the board. See "See every task at once" below.
- **Tasks**, then a row for each task, with its state icon on the right.
- **Earlier**: tasks that stopped some time ago and need nothing from you.

Click a row to open the task. <kbd>⌘</kbd> <kbd>1</kbd> to <kbd>⌘</kbd> <kbd>9</kbd> open the first nine tasks in the order the sidebar shows them.

Rest the pointer on a row for half a second to see a card about the task:

- Its state, and what it's doing now.
- What it handed over to you, as **For you: …**.
- Up to three of its open asks, and messages queued for it.
- When it wakes up next, if it has scheduled a check.

Click the card to open the task.

### Sort, pause or unarchive

Click the sliders button beside the **Tasks** heading. Its tip is **Sort, pause or unarchive tasks**.

| Item | What it does |
|---|---|
| **State** | Sorts the most urgent task first, in the order of the states table below. The default. |
| **Name** | Sorts by name. |
| **Manual (drag to arrange)** | Keeps the order you drag the rows into. Dragging a row switches to this sort. |
| **Pause all tasks** | Puts every running task in this workspace on hold. Shown when a task is running. |
| **Resume paused tasks** | Takes this workspace's paused tasks off hold. Shown when a task is paused. |
| **Archived tasks…** | Opens the tasks you archived. |

The control bar lists the tasks in the same order as the sidebar.

### Use a task's menu

Right-click a task in the sidebar:

| Item | What it does |
|---|---|
| **Rename…** | Gives the task a new name. |
| **Move to** | Moves the task to another workspace. Shown only when you have more than one. |
| **Pause** / **Resume** | Puts the task and its workers on hold, or takes them off hold. |
| **Work with another task…** | Pick another task, then click **Work together**. Each of the two hears about the other and how to reach it, so they can settle things between them. |
| **Save for later** | Asks the agent to save what it has to Later, after its current turn. The task stays where it is. See [Later, scratchpads and loops](/docs/later-scratchpads-loops). |
| **Move to Later** | Puts the whole task in Later. It leaves the sidebar and is paused with its workers, but isn't archived. Also in the **⋯** menu in the window's title bar. See [Later, scratchpads and loops](/docs/later-scratchpads-loops). |
| **Archive…** | Archives the task. See "Archive a task" below. |

## What a task's state means

The sidebar and the control bar show each task's state as an icon. The board and the details pane show it as a pill. A task's state includes its workers': when a worker needs you or is in trouble, so does its task.

| Icon | State | What it means |
|---|---|---|
| Blue hand | Needs you | The task, or one of its workers, asked you something and is waiting for your answer. |
| Orange triangle | In trouble | The task failed, got stuck or ran out of usage. |
| Red minus | Blocked | The task can't go on until something outside you and the agent changes, such as an outage or another team's access. The agent has to confirm it, so it's rare. Zero tells you the same way as for In trouble. |
| Blue spinner | Working | The agent is working. |
| Teal box | Over to you | The task is finished, and there's a step only you can take, such as a merge or a check. |
| Indigo speech bubble | Replied | The task answered you and isn't waiting on anything. It turns grey once you've read it. |
| Grey hourglass | Waiting | The task is waiting on someone or something other than you, such as a review or a build, or a command it started in the background. |
| Grey pause | Paused | You put the task on hold. |
| Purple badge | Done | The task is finished end to end, and the agent confirmed it. An agent that only says it's done shows Replied. |
| Grey moon | Idle | The agent is between turns with nothing to report. |
| Grey power button | Offline | The agent isn't running. |

When a task is done, waiting or blocked and its agent can't know, such as when you did the last of it yourself, right-click it in the sidebar and choose **Mark as done**, **Mark as waiting** or **Mark as blocked**. Zero takes your word as it would the agent's confirmation. A question or approval still open keeps the task at **Needs you**. When you next write to the task, it's the agent's to settle again.

Zero archives done tasks after a while. Choose when in **Settings › Agents › Tasks › Archive done tasks**: **Once you've read it**, **After an hour**, **After a day**, **After a week** or **Never**. **After a day** is the default. An archived done task comes back when something it follows changes.

## Read the conversation

A task's page shows its conversation: your messages, the agent's answers, and the work in between.

- **Steps.** Each turn's work folds under one line. It reads **Working for 12s** while the agent works, then **Worked for 2m 37s** or **Thought for 8s**. Click the line to see every step: the commands, such as `$ make test`, the files edited and the tools used. A command that fails shows its exit code. Point at a command's output for **Copy the output**.
- **Quiet updates.** Turns that Zero started and that needed nothing from you fold into one row, such as **2 updates that needed nothing from you**. Click the row to read them.
- **Messages from others.** A worker's report, a message from another task, or a note from Zero shows as one line. Click it to read the whole message. Click the sender's name to open that task.
- **Everything the last turn changed.** Shows below the last answer while the agent is idle. Open it to see the turn's changes as a diff.
- **Trouble.** A task that's stuck, or that hit its provider's usage limit, shows a callout at the end. When it's out of usage, click **Continue with Claude Code** or **Continue with Codex** to hand the task, conversation and all, to the other provider.

To move around a long conversation, use the ticks down the left edge, one for each of your messages. Point at one to preview it, and click to go there. The down arrow, **Go to the latest**, takes you to the end.

Point at a message to see a copy button, a **⋯** menu and the time it was sent. The menu has:

| Item | What it does |
|---|---|
| **Copy** | Copies the message. |
| **Quote in reply** | Adds the message to your reply as a quote. |
| **Save to a scratchpad** | Saves the message as a new scratchpad in the **Saved** folder, named after its first line. |
| **Save for later** | On the agent's answers: asks the agent to save that answer to Later. |
| **Rewind…** | On your messages: takes the task back to before that message. See "Rewind a task" below. |

## Write to a task

Write in the composer at the foot of the page:

| You want to | Do this |
|---|---|
| Send a message | Press <kbd>↩</kbd>, <kbd>⌘</kbd> <kbd>↩</kbd>, or click the paper plane. |
| Steer the agent while it works | Press <kbd>⌘</kbd> <kbd>↩</kbd>. The message reaches the agent in the middle of its turn. The box says **Steer it while it works**. |
| Queue a message for after this turn | Press <kbd>↩</kbd> while the agent works. |
| Stop the agent's turn | Click the square that replaces the paper plane, or press <kbd>⌘</kbd> <kbd>.</kbd>. |
| Start a new line | Press <kbd>⇧</kbd> <kbd>↩</kbd> or <kbd>⌥</kbd> <kbd>↩</kbd>. |

Start typing, or press <kbd>⌘</kbd> <kbd>V</kbd>, anywhere on the page, and it goes into the composer without a click. Zero keeps an unsent message as a draft for each task, and puts your words back in the box if a message can't be sent.

OpenCode takes one message at a time, so you can't steer it. Its box says **OpenCode answers one message at a time**.

### Edit, drop or send queued messages

Queued messages wait above the composer under **Queued**. For each one:

- Click it, or its pen, to take it back into the composer. The pen's tip is **Edit in the composer**.
- Click its bin to drop it. Its tip is **Delete**.
- Click **Steer** to send it now. Its tip is **Send it now, mid-turn**.

Stopping the agent holds the queue. The heading says **Held**, and nothing goes out until you click **Send** beside it or send something new.

### Attach files, folders and scratchpads

- **Images and videos**: paste them, drop them on the composer, or use the **+** button. Each shows as a pill in your words, such as **Image 1** or **Video 1**, and as a thumbnail above. Click a pill to open the image. A video goes to the agent as up to six stills.
- **Other files and folders**: click **+** › **Files and folders**. Zero puts each one's path in your message, and the agent reads it from there.
- **A scratchpad**: click **+** › **Scratchpad**, then find and pick one. Zero puts a link to it in your message.

### Use / and @

- Type <kbd>/</kbd> for Claude Code's commands and skills, eight at a time. Turn this off in **Settings › Composer and inbox › Composer › Suggest skills after /**.
- Type <kbd>@</kbd> for your loops. See [Later, scratchpads and loops](/docs/later-scratchpads-loops). To also list files from the task's folder, turn on **Settings › Composer and inbox › Composer › Suggest files after @**. It's off by default.

In the suggestions, <kbd>↑</kbd> and <kbd>↓</kbd> move, <kbd>Tab</kbd> or <kbd>↩</kbd> takes one, and <kbd>Esc</kbd> closes them.

### Change the model or permissions

The composer's chips show the task's model and permissions.

- **The agent chip** changes the model and effort from your next message. It also lists the other provider: Claude Code for a Codex task, or Codex for a Claude Code task. Pick one of its models and the task carries on there, with the whole conversation.
- **The permissions chip** shows **Auto** or **Unrestricted**, and changes what the agent can do without asking.

Change either while the agent is working, and the change applies from its next turn. The chip shows a clock, and its tip says **From the next turn**.

### Answer the task's questions

When a task asks you something, the question shows as a card above the composer and in your inbox. When the composer is empty, press <kbd>1</kbd> to <kbd>9</kbd> to pick an answer. See [The inbox and asks](/docs/inbox-and-asks).

## See a task's details

The details pane floats at the top right of the task's page. Show or hide it with the sidebar button at the right of the title bar. Its tip reads **Show details** or **Hide details**. It's shown by default.

| Row | What it shows |
|---|---|
| **Agent** | The provider and the model, such as "Opus 5.5 · High". An orange bolt means the task is **Unrestricted**. Change the model in the composer, not here. |
| **Where** | The project folder. Click it to show the folder in Finder. When **Settings › Agents › Tasks › Where tasks run** has a command, it shows the place that command names instead. |
| **Status** | The task's state. Point at it for a card with more about where the task stands. Click the card to keep it open. Press <kbd>Esc</kbd> or click outside to close it. |
| **Branch** | The Git branch it's on, when there is one. |
| **Ticket** | The issue the task is on, as a link, when it has one. |
| Others | Anything else the agent recorded about the task, such as its pull request, as links. |
| **Workers** | The task's workers, the most urgent first. Click one to open it. **All N** shows every worker, **Fewer** goes back. |

## Follow a task's workers

A task can hand parts of its job to workers: other agents it starts, each with a conversation of its own. Ask a task for one, such as "Have a worker review the change".

By default, agents use Zero's workers rather than their CLI's own subagents, so you can see, steer and stop every one of them. To let Claude Code and Codex also use their own subagents, turn on **Settings › Agents › Tasks › Agents' own subagents**. It applies from each task's next start.

Workers show in several places:

- **In the sidebar**, under their task on a dotted branch. To fold them away, click the chevron beside the task. Its tip reads **Hide its workers** or **Show its workers**. When a task works through several issues, each issue gets a row of its own, with how long it's been waiting on you.
- **On the task's page.** Click a worker to open its conversation in the task's page. The sidebar keeps the task selected. Write to the worker as you would to any task.
- **In the details pane**, under **Workers**.
- **On the board**, as "1 worker" or "N workers" under the task's name.
- **In the task's conversation.** When a worker finishes, fails or gets stuck, its report arrives as a line that starts with "Worker". Click it to read the report.

When a worker needs you or is in trouble, its task shows that state too. The task's card in the sidebar says so, for example "1 worker needs you".

A worker that ends its turn while a command it started in the background still runs shows **Waiting**. Its task hears that it's waiting on the command, and the worker carries on when the command finishes.

Zero archives a finished worker an hour after its task has its report, so finished workers don't pile up under a task. A worker that's waiting, asking or in the middle of its work stays, and so does one with an ask, a follow, a watch or a wake-up still open. Zero doesn't archive workers when **Archive done tasks** is **Never**. A message to an archived worker, from you or its task, brings it back.

## Pause, end or resume a task

| Action | Where | What it does |
|---|---|---|
| **Stop** | The square in the composer, or <kbd>⌘</kbd> <kbd>.</kbd> | Stops the turn the agent is on. The task stays where it is, and you can write to it again. |
| **Pause** | A task's menu in the sidebar, the **⋯** menu in the title bar called **More**, or the **⋯** menu on the board called **Actions** | Puts the task and its workers on hold. Zero asks a working agent to finish the step it's on and end its turn, then stops it. Messages for it wait until you resume it. |
| **Resume** a paused task | The same menus | Takes the task and its workers off hold. Any with messages waiting start again for them. |
| **End session** | The **⋯** in the title bar, or the **⋯** on the board | Stops the agent's process. |
| **Resume** an offline task | The **⋯** in the title bar, or the **⋯** on the board | Starts the agent again on the same conversation. |

To pause every task in a workspace, use **Pause all tasks** in the sliders menu beside the sidebar's **Tasks** heading.

When an agent has been idle for three minutes with nothing open, Zero stops it to free memory. You don't need to resume it by hand: write to it and it starts again. Its box says **Message to resume it**.

## Archive a task

Archive a task to take it out of the sidebar and the board.

1. Choose **Archive…** from the task's menu in the sidebar, the **⋯** in the title bar, or the **⋯** on the board.
2. A card asks you to confirm, and says whether the task's workers go with it. Click **Archive**, or press <kbd>↩</kbd>. <kbd>Esc</kbd> cancels.

Archiving stops the task and its workers. To bring one back, click the sliders button beside **Tasks** › **Archived tasks…**. Find it with **Search** and click **Unarchive**. Its workers come back with it.

## Rewind a task

Rewinding takes a task back to before one of your messages: its conversation, the files in its folder, or both.

1. Press <kbd>Esc</kbd> twice quickly on the task's page, or choose **Rewind…** from the **⋯** menu on one of your messages.
2. In **Rewind to**, pick the message with <kbd>↑</kbd> <kbd>↓</kbd> and <kbd>↩</kbd>.
3. The card says what's changed in the folder since then, such as "Since this message: 3 files changed, +40 −12." Choose what to do:

| Choice | What it does |
|---|---|
| **Restore conversation and code** | Back to before this message, files and all. |
| **Restore conversation** | The conversation goes back. The files stay as they are now. |
| **Restore code** | The files go back. The conversation carries on as it is. |
| **Branch from here** | Starts a new task from before this message. This one stays as it is. |
| **Never mind** | Closes the card. |

When the conversation goes back, your message returns to the composer, so you can change it and send it again.

When the folder is in a Git repository, Zero keeps a copy of it each time you send a message. When there's no copy for that message, the card says **Zero didn't keep the folder for this message, so only the conversation can go back.** Zero also keeps a copy before it restores the files, so you can rewind the restore too.

## See every task at once

Click **All tasks** in the tasks sidebar. The board lists the workspace's tasks in two tables:

- **Running**: agents at work now, the most urgent first.
- **Offline**: tasks that aren't running. Each shows the state it was last in. A message resumes it.

| Column | What it shows |
|---|---|
| **Task** | The task's name, and how many workers it has. |
| **Where** | Where the task runs. Shown only when the tasks are in more than one place. |
| **State** | The state, and what the task needs from you: its first open ask, or the step it handed over. |
| **Now** | What the task is doing now, in its own words. |

Click a row to open the task. Its **⋯** menu, called **Actions**, has **Ask for a status update**, **Open**, **End session** or **Resume**, **Pause** or **Resume**, **Copy task id** and **Archive…**. With **Ask for a status update**, the agent answers in a few lines and posts where it stands.

## Use the agent's own terminal

Some things only a provider's own terminal app can do. Click the terminal button in the title bar to swap the conversation for that terminal. The terminal picks up the same conversation. The button's tip names the provider, such as **Open in Codex's own terminal, for what only it has**. The details pane stays beside it.

In the terminal, <kbd>⌘</kbd> <kbd>C</kbd>, <kbd>⌘</kbd> <kbd>V</kbd> and <kbd>⌘</kbd> <kbd>A</kbd> copy, paste and select all. Files you paste or drop go in as their paths. The terminal uses the font from your Ghostty config, when you have one.

To go back, click the button again. Its tip then reads **Back to Zero, with what happened in the terminal**. A terminal left untouched for 15 minutes closes, and the task comes back to Zero. The terminal won't open while the agent is working, and Zero's composer, steering and queue aren't there while it's open.
