---
title: "Following and integrations"
description: "Let agents watch pull requests and issues, and connect the services you use."
order: 8
---

An agent can follow a pull request, an issue or a Slack thread. Zero reads it and tells the agent what changed, so the agent learns of a review or a reply without your help.

Integrations connect Zero to GitHub, Linear and Slack, so agents can follow things there.

## What following does

Zero reads each thing that an agent follows about once a minute. It reads a Slack thread or channel every 30 seconds. When agents follow many things, Zero reads less often.

When something changes, Zero tells the agent between its turns. The message starts with the number of new events. When the agent's turn has ended, the message wakes the agent and it continues.

An agent can follow:

| What | What the agent hears of |
|---|---|
| A GitHub pull request | Reviews, comments, review threads resolved, checks failing and the overall result, pushes, conflicts, merges, and changes to its state, title, description, labels, assignees and reviewers. |
| A Linear issue | Changes to its status, assignee, priority, project, cycle, labels, estimate, due date, parent, title and description, and every comment. |
| One comment thread in a Linear issue | Only the comments in that thread. |
| A Slack thread | Replies, edits, deletions and reactions. |
| A Slack channel | New messages, and new replies in its recently active threads. |

Following needs a connected integration: see [Connect GitHub, Linear and Slack](#connect-github-linear-and-slack).

A task that's done and archived still follows its things. When one of them changes, the task comes back. When Zero fails to read something three times in a row, it tells the agent. It tells the agent again when reading works.

## How agents follow things

To make an agent follow something, give it the link. Agents start follows themselves with the `zero` command, usually when they pick up an issue or watch a pull request. Zero has no button to start a follow.

Zero follows each pull request that an agent opens, with no command from the agent. This works when the agent opens it with `gh pr create`, GitHub's API or an MCP tool. The task's conversation then shows a line such as **Following app#7**. When the task has no **PR** attribute yet, the pull request becomes its PR. An agent that sets a PR attribute with `zero attr PR <link>` follows that pull request too.

A worker's pull requests pass to its lead with the worker's report, so the lead keeps hearing of reviews and merges once the worker is archived.

When an agent ends its turn waiting, but follows nothing and runs nothing, nothing would wake it. Zero then asks the agent, once, to follow what it waits on or to say who it waits on.

| Command | What it does |
|---|---|
| `zero follow <link>` | Follows a pull request, an issue, a Slack thread or channel, or a Linear comment thread. The link to a Linear comment thread ends in `#comment-…`. |
| `zero follow <link> --mine` | For a busy channel. Delivers only messages that name a pull request that the task follows. |
| `zero follow <link> --about "word,other words"` | Delivers only events that contain one of these words. |
| `zero following` | Lists what the task follows, and whether Zero can read each one. |
| `zero unfollow <topic>` | Stops one follow. `--all` stops all of them. |

See [The zero command](/docs/cli) for every command.

## See and stop what agents follow

Each service's page in Settings, such as **Settings › GitHub**, lists the follows that Zero reads through it, under **Following**. To open Settings, press <kbd>⌘</kbd> <kbd>,</kbd> or click the gear at the foot of the window's left rail.

Until an agent follows something there, the list shows **No agent follows anything through GitHub yet.**, with the service's name. Each row shows:

- The thing's title, such as the pull request's name.
- Below the title, the topic that Zero reads, such as `github/acme/app/42`. Next comes the filter, if the follow has one: **only your pull requests**, or **about** and the words. Last comes the time of Zero's last read.
- **Can't read it:** and the reason, in red, when Zero fails to read it.
- On the right, the name of the task that follows it. Click the name to open the task.

To stop a follow, point at its row and click **×**, **Unfollow**. Double-click a row to open the thing in your browser. Right-click a row for **Open**, **Copy topic** and **Unfollow**.

A task's details pane lists what that task follows, under **Follows**. Click one to open it. To stop it, point at it and click **×**, **Unfollow**.

## Open the integrations

**GitHub**, **Linear** and **Slack** are in Settings, under **Connections** in the sidebar. **Browsers** and **MCP servers** are under **Agents**. To open Settings, press <kbd>⌘</kbd> <kbd>,</kbd> or click the gear at the foot of the window's left rail. The pages for GitHub, Linear and Slack each show the connection, the links and what agents follow through it.

## Connect GitHub, Linear and Slack

An integration that isn't connected says so under **Connection** on its page, as **Connect GitHub**, **Connect Linear** or **Connect Slack**, with the steps below it.

**GitHub.** Zero uses the GitHub CLI and the account that the CLI is already signed in to.

1. If the GitHub CLI isn't installed, install it first:

   ```sh
   brew install gh
   ```

2. In a terminal, run this command. In Zero, the copy button beside the command copies it.

   ```sh
   gh auth login
   ```

3. Go back to Zero and click **Check again**.

The page then shows **Connected as** and your GitHub login. To disconnect, sign out of the GitHub CLI.

**Linear.** Click **Connect Linear**, then allow Zero on the Linear page that opens in your browser. Zero reads Linear and never writes to it. Issue keys of the workspace's teams, such as `ABC-123`, then link in messages. It keeps the connection on this Mac. To disconnect, click **Disconnect** on the page.

**Slack.** Zero reads channels, messages and names. It posts nothing. Each Slack workspace gets Zero's own Slack app:

1. Click **Connect Slack**, then **Open Slack**. Slack opens with the app filled in.
2. In Slack, click **Create**, then **Install to Workspace**.
3. Copy the **User OAuth Token** that Slack shows.
4. Paste the token in the `xoxp-…` box in Zero and click **Connect**.

To connect more than one Slack workspace, click **Connect Slack** beside **Workspaces** and do the same steps for each one.

A Slack connection made before agents could follow Slack needs new scopes. Add the scopes from the app's manifest to your Slack app, reinstall the app and paste the new token.

The page then lists the workspace under **Workspaces**. Each workspace has its own **Disconnect**.

## Make references in messages open where you want

When an agent's message names a pull request, a commit, an issue or a Slack channel, Zero makes the name a link. Choose where those links go under **Links** on the integration's page:

| Setting | Where | What it does |
|---|---|---|
| Link pull requests and commits | Settings › GitHub › Links | `repo#123`, `#123` and commit hashes open on GitHub. On by default. |
| Link issues | Settings › Linear › Links | Issue keys such as `ABC-123` open the issue. On by default. |
| Open issues in the Linear app | Settings › Linear › Links | Opens issues in Linear's app, not in the browser. On by default. Greyed out when Linear's app isn't installed. |
| Slack | Settings › Slack › Workspaces | The Slack workspaces that Zero is connected to. Their #channels and message links open in Slack. **Connect Slack** adds a workspace. **Disconnect** removes it. |
