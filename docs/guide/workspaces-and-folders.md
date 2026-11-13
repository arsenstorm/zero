---
title: "Workspaces and folders"
description: "Keep tasks apart by workspace, and tell Zero which folders your projects are in."
order: 6
---

Workspaces keep your tasks apart by who they're for, such as your own projects and your job. Projects are the folders your tasks start in. **Settings › Git** sets how agents commit in them.

Open Settings with <kbd>⌘</kbd> <kbd>,</kbd> or the gear at the foot of the window's left rail.

## What a workspace is for

Each task belongs to one workspace. The window's tasks sidebar, the board, **All tasks**, and the control bar show only the tasks of the workspace you're looking at.

Switching changes only what you see. Tasks in every workspace keep running, and their asks still reach your inbox.

Zero always has a workspace called **Zero**, which you can't rename or delete. A task is in the Zero workspace unless it started in another workspace or you moved it.

These things act on the workspace you're looking at:

- **New task** starts tasks there, unless you pick another in its workspace chip.
- The workers a task starts go into its workspace.
- <kbd>⌘</kbd> <kbd>1</kbd> to <kbd>⌘</kbd> <kbd>9</kbd> open that workspace's first nine tasks.
- **Pause all tasks** and **Resume paused tasks**, in the sliders menu beside the sidebar's **Tasks** heading, act on that workspace's tasks only.

A workspace can also have MCP servers for its own tasks only. See [Browsers and MCP servers](/docs/browsers-and-mcp).

## Create a workspace

From the window:

1. Click the workspace's name at the top of the tasks sidebar.
2. Choose **New workspace…**.
3. Type a name and click **Create**.

From Settings:

1. Go to **Settings › Workspaces** and click **Add workspace**.
2. Type a **Name** and pick an **Icon**.
3. Click **Save**.

A new workspace gets the first icon in the grid until you pick another.

## Switch workspace

- **In the window**: click the workspace's name at the top of the tasks sidebar, then click another workspace. A tick marks the one you're looking at. **Workspace settings…**, in the same menu, opens **Settings › Workspaces**.
- **In the control bar**: click the workspace's icon, below the inbox. The icon shows only when you have more than one workspace.

Each workspace reopens the task you last had open in it. When you open a task from another workspace, for example from the inbox or a notification, the window goes to that task's workspace.

## Change a workspace's name, icon or servers

1. Go to **Settings › Workspaces**. The workspace you're looking at has a **Shown** pill.
2. Point at a workspace and click the pen, **Edit**, or double-click its row.
3. Change its **Name**, pick an **Icon** from the grid, or tick the **MCP servers** its tasks get. Servers that every workspace gets show as "(every workspace)", and you can't untick them here. Add and change servers in **Settings › MCP servers**.
4. Click **Save**.

The icon shows beside the workspace's name in the tasks sidebar, in the control bar and in Settings. Zero's own workspace shows Zero's mark until you pick an icon for it.

## Delete a workspace

In **Settings › Workspaces**, point at the workspace and click the bin, **Delete: its tasks are Zero's again**. Zero doesn't delete its tasks: they move to the Zero workspace.

## Move a task to another workspace

Right-click the task in the tasks sidebar and choose **Move to** and the workspace's name (**Move to Zero** puts it back in the Zero workspace). These show only when you have more than one workspace. The task's workers go with it.

## Add your projects

Tasks start in a project: a folder on your Mac that you added to Zero. Every workspace shares the same projects.

1. Go to **Settings › Workspaces**.
2. Next to **Projects**, click **Add folder**.
3. Choose one or more folders and click **Open**.

Your projects then show in the project chip on the **New task** page. Until you add one, that page says **Add a project in Settings › Workspaces** in place of its chips.

Each project shows with its folder's name. Point at a row to see the folder's full path. Click a row for its menu:

| Item | What it does |
|---|---|
| **Rename…** | Gives the project a name of its own in Zero, used in the project chip and a task's **Where**. Zero doesn't rename the folder. Clear the name to go back to the folder's own. |
| **Show in Finder** | Shows the folder in Finder. |
| **Remove** | Takes the folder off the list. The folder and its files stay on your Mac, and tasks that already run there continue. |

## Set how agents commit

**Settings › Git** gives your agents a Git identity of their own. When it's on, the identity you set here commits and signs their commits. You stay the author unless you turn on **Credit you as co-author**.

So nothing waits on your own signing key: agents commit and push while your key is locked or you're away. Only the agents' processes get this identity. Your own Git settings and your own terminal keep yours.

| Setting | Where | What it does |
|---|---|---|
| Agents commit as their own account | Settings › Git › Agents' commits | Turns the agents' identity on. Off by default. While it's off, the other rows are hidden. |
| Account | Settings › Git › Agents' commits | The GitHub account that commits and signs. Click **Choose…** or **Change…**, type the account's login and click **Use**. Its name and GitHub's noreply email become the committer. |
| Signing key | Settings › Git › Agents' commits | The private key the agents sign with. It must have no passphrase. Click **Choose…** or **Replace…** and pick the key file. A pill shows **On** and the login when the key is one of the account's signing keys on GitHub, so commits show as Verified. **Not on** means you still need to add it to the account as a signing key. |
| Credit you as co-author | Settings › Git › Agents' commits | On: the agents' account is the author too, and Zero adds a `Co-authored-by` trailer for you. **Your name and email**, with **Set…**, sets the name and email in it. Left blank, Zero uses each repository's `user.name` and `user.email`. Off by default: you stay the author. |
| Only in these folders | Settings › Git › Only in these folders | Keeps the agents' identity, and their GitHub token, to these folders and the folders inside them. Click **Add folder** to add one, and **Remove** to take one off. With no folders added, it reads **Every folder**, and agents in all folders commit this way. |

The identity applies only when it's on and both an account and a signing key are set.

How agents push, and a GitHub token of their own, are in **Settings › GitHub › Agents' access**. See [Settings](/docs/settings#github).
