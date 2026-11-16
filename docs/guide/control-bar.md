---
title: The control bar
description: The small bar on the edge of your screen that keeps your agents in view.
order: 4
---

The control bar is a small bar on the right edge of your screen, halfway down. It stays on top of other apps, so your agents stay in view while you work in another app. Point at the bar and the inbox opens beside it.

<!-- figure: bar -->

## What the bar shows

From the top:

- **The inbox.** A round button with a tray icon, at the top of the bar. While the pointer is away from the bar, it folds into a thin arc. The arc turns blue while at least one ask is waiting for you, and brightens once when a new one comes in.
- **The workspace.** Its icon shows only when you have more than one workspace. Click it to see your workspaces and switch to another one.
- **A line**, then **one mark for each task** in the workspace, workers included. They're in the same order as the window's sidebar. Each mark is the task's state icon, the same one the sidebar shows. A blue spinner means the task is working.
- **Agents outside Zero**, such as Claude Code in a terminal. When one asks you something, it shows as a coloured dot after the tasks.
- **The settings button**, at the foot of the bar, when you turn it on in **Settings › Control bar › In the bar**. It folds into an arc too. Click it to change what the bar shows.

With the pointer on the bar, only the button nearer to it comes out: the inbox near the top, the settings button near the foot. Over the tasks, both come out.

The task states:

| Icon colour | State | What it means |
|---|---|---|
| Blue hand | Needs you | The task, or one of its workers, asked you something. |
| Orange triangle | In trouble | The task failed, got stuck or ran out of usage. |
| Red minus | Blocked | The task can't go on until something outside you and the agent changes, such as an outage. |
| Blue spinner | Working | The task is working. |
| Teal box | Over to you | The task is done, and there's a step left for you. |
| Indigo speech bubble | Replied | The task answered you. It turns grey once you've read it. |
| Grey hourglass | Waiting | The task is waiting on someone else, such as a review. |
| Blue terminal | In Ghostty | The task is open in your terminal app, which the state names. |
| Purple badge | Done | Nothing is left to do. |

## Open the inbox from the bar

- **Point** at the inbox icon or at a task's mark. The inbox opens beside the bar and shows the asks, or that task. A task's view shows its latest answer, with **Open task** to open it in Zero's window.
- **Click** to keep the inbox open. To close it, click the same icon or mark again, or press <kbd>Esc</kbd>.
- **Click a task's mark.** When the task has asked you something, its asks open in the inbox. Otherwise the task opens in Zero's window.

When you move the pointer from the bar into the open inbox, the marks and buttons it crosses on the way don't take over. Pointing at the settings button closes an inbox you opened by pointing, but not one you opened with a click.

While the inbox is open, <kbd>1</kbd>, <kbd>2</kbd> and <kbd>3</kbd> pick an answer. See [The inbox and asks](/docs/inbox-and-asks).

## Change the order

Drag a mark up or down the bar. The window's sidebar takes the same order.

## Use a mark's menu

Right-click a task's mark for its menu, beside the bar:

| Item | What it does |
|---|---|
| **Open** | Opens the task in Zero's window. |
| **Pause** / **Resume** | Puts the task and its workers on hold, or takes them off hold. |
| **Save for later** | Puts the whole task in Later. See [Later, scratchpads and loops](/docs/later-scratchpads-loops). |
| **Archive…** | Opens the task and asks you to confirm archiving it. See [Tasks and workers](/docs/tasks-and-workers). |

Right-click the mark of an agent outside Zero:

- **Remove** closes the agent in the inbox. Its open asks expire, and a **Closed** note stays in its history.
- **Remove and stop** does the same and also stops the agent. It shows in place of **Remove** when Zero can stop the agent.

## Use the bar's menu

Right-click the bar for:

- **Customise bar…**: opens **Settings › Control bar**.
- **Open log**: opens `~/.zero/asks.jsonl`, the file where Zero records every ask and answer.
- **Settings…**: opens Zero's settings.
- **Quit Zero**: quits the app.

## Settings for the bar

These are in **Settings › Control bar**. Open Settings with <kbd>⌘</kbd> <kbd>,</kbd> or the gear at the foot of the window's left rail.

| Setting | Where | What it does |
|---|---|---|
| In the bar | Settings › Control bar › In the bar | Turns the bar's parts on or off, and sets their order: drag a row up or down. **Inbox** stays first. **Workspace** shows only while you have more than one. **Agents** shows **All tasks**, **Only those that need you**, **Pinned tasks only** or **None**. |
| Settings button | Settings › Control bar › In the bar | Puts the settings button at the foot of the bar. It comes out when the pointer is on the bar. |
| Follow the active screen | Settings › Control bar › Placement | On: the bar moves to the screen you're using. Off: it stays on the screen where it first appeared. |
| Show the bar in Zero's window | Settings › Control bar › Placement | Puts the bar in Zero's window, not on the screen's edge: **When it fills the screen**, **Always** or **Never**. **When it fills the screen** is the default. |
| Agents in the bar | Settings › Control bar › Agents in the bar | The agents outside Zero that the bar shows. Rename or remove one, or drag them into a new order. A removed agent comes back when it next asks you something. |

The **Inbox hotkey** opens the inbox from any app. It's <kbd>⌥</kbd> <kbd>Space</kbd> unless you change it in **Settings › General › Zero › Inbox hotkey**.
