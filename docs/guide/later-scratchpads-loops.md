---
title: "Later, scratchpads and loops"
description: "Save work for later, keep notes your agents can read, and keep instructions you give agents by name."
order: 7
---

Three places in Zero's window keep things that you and your agents come back to:

- **Later**: work to pick up another time. Each item has a short note and everything behind it.
- **Scratchpads**: Markdown notes that you and every agent can read and write.
- **Loops**: named instructions that you give an agent when you type `@name`.

Each has a button on the window's left rail, below **Inbox**, in this order. Point at a button to see its name. To open the window, choose **Show Zero**, <kbd>⌘</kbd> <kbd>0</kbd>, in the menu bar icon's menu.

## Save something for later

A Later item has two parts. The note says in one sentence what to do. The artifact holds everything behind it in full, such as an agent's findings or a plan.

Items come to Later in four ways.

**Write one yourself.**

1. Click **Later** on the rail.
2. At the top of its list, click the compose button, **Write one**.
3. Fill in **What's to be done, in a sentence**.
4. Fill in **Anything behind it, in Markdown (optional)**, or leave it empty.
5. Click **Save**.

**Ask a task to save one.** The agent writes the note and the artifact from what it has learned. There are two ways:

- Right-click the task in the tasks sidebar and choose **Save for later**.
- To save one of the agent's answers, point at the answer, click its **⋯** and choose **Save for later**.

The agent saves the item after its current turn.

**Move a whole task there.** Right-click a task in the tasks sidebar, or open the **⋯** menu in the window's title bar. Then choose **Move to Later**. The task leaves the sidebar, and it and its workers pause. Zero doesn't archive the task. In Later, it shows with a **Task** pill.

**Agents suggest them.** An agent can save an item unasked when it expects you'll want to come back to it. These items go under **Suggested by agents** at the foot of the Later list. The heading shows how many there are. Click the heading to show them. Zero deletes a suggestion a week after it was saved, unless you click **Keep**.

## Use a Later item

Click an item in the Later list to open it. The item shows its note, the task it came from, when it was saved, the links and files that came with it, and its artifact. Click the task's name to open that task.

| Button | What it does |
|---|---|
| **Resume task** | For a task you moved to Later. Puts the task back in the sidebar, takes it and its workers off hold, and marks the item done. |
| **Start a task from this** | Opens **New task** with the item in its box, ready to send. |
| **Send to a task** | Pick a task in this workspace. Zero sends the item to that task and opens the task. |
| **Copy** | Copies the note and the artifact. |
| **Keep** | For suggestions. Keeps the item in Later. Without it, Zero deletes the item a week after it was saved. |
| **Done** / **Not done** | Marks the item done, or open again. Done items stay in the list, struck through and faded. |
| **Version N** | Shows when an agent changed the item. Pick an earlier version to read it. |
| **Delete** / **Dismiss** | Deletes the item. Suggestions say **Dismiss**. When you delete a task that you moved to Later, the task goes back in the sidebar and stays paused. |

Right-click an item in the list for **Copy link**, **Done** or **Not done**, and **Delete** or **Dismiss**. For a task you moved there, the menu also has **Resume task**. For a suggestion, it also has **Keep**.

An item's link looks like `zero://later/<id>`. To point an agent at the item, paste the link in a message.

### How agents use Later

Agents save, list, read and change Later items with the `zero later` command, for example:

```sh
zero later save "Retry the flaky login test with a longer timeout" --file notes.md
```

A task keeps at most three suggestions open at a time. See [The zero command](/docs/cli).

Zero keeps Later items in `~/.zero/later`.

## Keep notes in a scratchpad

Scratchpads are Markdown notes in folders that you and your agents share. Use them for plans, checklists, findings, or anything else for an agent to read.

Click **Scratchpads** on the rail. At the top of the list:

- **Search** finds pads by their title or folder. The ×, **Clear**, empties the search.
- **New scratchpad** makes a pad.
- **New folder** makes a folder.

Right-click a folder for **New scratchpad here**, **New folder inside** and **Show in Finder**.

Right-click a pad for:

| Item | What it does |
|---|---|
| **Copy link** | Copies the pad's link. |
| **Copy Markdown link** | Copies the link as Markdown, with the pad's title. |
| **Rename…** | Renames the pad. |
| **Move to** | Moves the pad to another folder, or to **Scratchpads (top)**. |
| **Show in Finder** | Shows the pad's file. |
| **Move to Trash** | Deletes the pad. |

Zero keeps each pad as a Markdown file in `~/.zero/scratchpads`. Each of your scratchpad folders is a folder there.

## Write in a scratchpad

Click a pad to open it. Type its title over **Untitled** at the top. Write the text below it, in Markdown. Zero saves as you type. Under the title, the pad shows its folder and the time of the last edit.

The formatting buttons and their keys:

| Button | Keys |
|---|---|
| **Bold** | <kbd>⌘</kbd> <kbd>B</kbd> |
| **Italic** | <kbd>⌘</kbd> <kbd>I</kbd> |
| **Strikethrough** | <kbd>⇧</kbd> <kbd>⌘</kbd> <kbd>X</kbd> |
| **Code** | <kbd>⌘</kbd> <kbd>E</kbd> |
| **Link** | <kbd>⌘</kbd> <kbd>K</kbd> |
| **Heading** | <kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>1</kbd> |
| **Subheading** | <kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>2</kbd> |
| **Small heading** | <kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>3</kbd> |
| **Bulleted list** | <kbd>⇧</kbd> <kbd>⌘</kbd> <kbd>8</kbd> |
| **Numbered list** | <kbd>⇧</kbd> <kbd>⌘</kbd> <kbd>7</kbd> |
| **Checklist** | <kbd>⇧</kbd> <kbd>⌘</kbd> <kbd>9</kbd> |
| **Quote**, **Code block**, **Table**, **Divider** | No keys |

In a table, right-click a cell for **Add row below**, **Add column after**, **Delete row** and **Delete column**. The **Add row** and **Add column** buttons also add rows and columns.

When an agent changes the pad while you type, Zero says **Changed elsewhere while you were typing.** Click **Keep mine** to save your version. Click **Take theirs** to load the agent's version.

## Hand a scratchpad to an agent

Every pad has a link, `zero://pad/<id>`. Every heading in a pad has a link too. When a message has one of these links, the agent reads that pad, or that part of it.

- **The whole pad**: click **Copy link** beside the pad's title, or right-click the pad in the list. The arrow beside **Copy link** has **Copy Markdown link**. It also has a link for each heading, under **Link to a section**.
- **One section**: right-click in the pad's text and choose **Copy link to "<section>"**. **Copy link to scratchpad** in the same menu copies the link for the whole pad.
- **From the composer**: in a task's composer, click **+** › **Scratchpad** and pick the pad. Zero puts its link in your message.
- **By dragging**: drag a pad from the list into a message.

Agents in Zero read, write, search and organise pads with Zero's scratchpad tools. They give you links to what they wrote. To keep one of an agent's messages as a pad, point at the message, click its **⋯** and choose **Save to a scratchpad**. The pad goes into the **Saved** folder, named after the first line of the message.

## Give an agent a loop

A loop is an instruction for an agent, kept under a name. For example, `@review` can hold how you like changes reviewed. When you type `@review` in a message, the agent gets the loop's words with the message. Your message still shows `@review`.

A loop can name other loops in its text, such as `@tests`. Zero doesn't add those loops' words: the names tell the agent which loops to start workers on. The lead follows `@review`, and its workers follow `@tests`.

### Make a loop

1. Click **Loops** on the rail. At the top of the list, click the compose button, **New loop**. When no loop is open, the page also has a **New loop** button.
2. Type a name and click **Create**. Zero writes the name in lower case, with hyphens for spaces.
3. Under the loop's name, write **What this loop is for, in a line**. This line shows in the list and when you type `@`.
4. Write the instruction below it, in Markdown. Zero saves as you type.

At the foot of a loop:

- **Names** lists the loops that it names. Click one to open it.
- **Ran by** lists the tasks that used it, as a lead or as a worker, with their state and the time. Click a task to open it. A new loop says **No session has run it yet.**

**Copy name** is beside the loop's name. It copies `@name`, ready to paste into a message. Right-click a loop in the list for **Copy name** and **Delete**.

Zero keeps each loop as a Markdown file in `~/.zero/loops`.

### Use a loop

- **In a message**: type <kbd>@</kbd> in a task's composer. Zero suggests your loops first, each with what it's for. Pick one with <kbd>↑</kbd> <kbd>↓</kbd> and <kbd>Tab</kbd> or <kbd>Return</kbd>.
- **From an agent**: an agent lists your loops with `zero loops`, reads one with `zero loop <name>`, and starts a worker on one with `zero spawn --loop <name>`. See [The zero command](/docs/cli) and [Tasks and workers](/docs/tasks-and-workers).
