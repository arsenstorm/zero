---
title: "Following and integrations"
description: "Let agents watch pull requests and issues, and connect the services you use."
order: 8
---

An agent can follow a pull request, an issue or a Slack thread. Zero reads it and tells the agent what changed, so the agent learns of a review or a reply without your help.

Integrations connect Zero to GitHub, Linear and Slack, so agents can follow things there. GitHub and Linear also show your pull requests and issues in Zero's window.

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

To make an agent follow something, give it the link. Agents start each follow themselves with the `zero` command, usually when they open a pull request or pick up an issue. Zero has no button to start a follow.

| Command | What it does |
|---|---|
| `zero follow <link>` | Follows a pull request, an issue, a Slack thread or channel, or a Linear comment thread. The link to a Linear comment thread ends in `#comment-…`. |
| `zero follow <link> --mine` | For a busy channel. Delivers only messages that name a pull request that the task follows. |
| `zero follow <link> --about "word,other words"` | Delivers only events that contain one of these words. |
| `zero following` | Lists what the task follows, and whether Zero can read each one. |
| `zero unfollow <topic>` | Stops one follow. `--all` stops all of them. |

See [The zero command](/docs/cli) for every command.

## See and stop what agents follow

Open **Settings › Following**. To open Settings, press <kbd>⌘</kbd> <kbd>,</kbd> or click the gear at the foot of the window's left rail.

The page groups the follows by **GitHub**, **Linear** and **Slack**. Until an agent follows something, the page shows **No agent follows anything yet.** Each row shows:

- The thing's title, such as the pull request's name.
- Below the title, the topic that Zero reads, such as `github/acme/app/42`. Next comes the filter, if the follow has one: **only your pull requests**, or **about** and the words. Last comes the time of Zero's last read.
- **Can't read it:** and the reason, in red, when Zero fails to read it.
- On the right, the name of the task that follows it. Click the name to open the task.

To stop a follow, point at its row and click **×**, **Unfollow**. Double-click a row to open the thing in your browser. Right-click a row for **Open**, **Copy topic** and **Unfollow**.

Each integration's page in **Integrations** also lists the follows that Zero reads through it, under **Following**.

## Open Integrations

Click **Integrations**, the puzzle piece near the foot of the window's left rail. The page lists **GitHub**, **Linear** and **Slack** on its left. Pick one to connect it, to see what agents follow through it, and to make its views.

## Connect GitHub, Linear and Slack

An integration that isn't connected says so at the top of its page, as **Connect GitHub**, **Connect Linear** or **Connect Slack**, with the steps below it.

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

**Linear.** Click **Connect Linear**, then allow Zero on the Linear page that opens in your browser. Zero reads Linear and never writes to it. It keeps the connection on this Mac. To disconnect, click **Disconnect** on the page.

**Slack.** Zero reads channels, messages and names. It posts nothing. Each Slack workspace gets Zero's own Slack app:

1. Click **Create Zero's Slack app**. Slack opens with the app filled in.
2. In Slack, click **Create**, then **Install to Workspace**.
3. Copy the **User OAuth Token** that Slack shows.
4. Paste the token in the `xoxp-…` box in Zero and click **Connect**.

**Settings › Links › Slack › Connect Slack** goes through the same steps. To connect more than one Slack workspace, do the same steps for each one.

A Slack connection made before agents could follow Slack needs new scopes. Add the scopes from the app's manifest to your Slack app, reinstall the app and paste the new token.

The page then shows **Connected to** and the workspace's name. When one Slack workspace is connected, **Disconnect** is on the Integrations page. When more than one is connected, disconnect each one in **Settings › Links › Slack**.

## Keep your pull requests and issues in the rail

With GitHub or Linear connected, turn on **Show in the sidebar** on its page in Integrations. The integration then gets its own place in the window's left rail, under Loops. The switch is off by default.

Click the integration's icon in the rail. Its views show down the left, and the items of the open view show on the right. While the list is on screen, it refreshes every minute. The refresh button fetches it again at once.

- **GitHub** shows a table of pull requests: **#**, **Pull request**, **Repository**, **State**, **Checks** and **Author**. Click a row to open the pull request.
- **Linear** shows issues grouped by state, as Linear does. Click a state's heading to fold its issues away. Each row shows the priority, key, state, title, labels, assignee and when the issue was made. Click a row to open the issue. Right-click a row for **Open in Linear**, **Copy link**, and **Start task** or **Open task**.

Right-click an integration's icon in the rail for **Move up**, **Move down**, **Edit views** and **Hide from the sidebar**. To move an icon, hold <kbd>⌘</kbd> and drag it. **Edit views** at the foot of an integration's views opens its page in Integrations.

## Set up views

A view is a saved list of pull requests or issues. To make one, click **Add a view** under **Views** on GitHub's or Linear's page in **Integrations**.

To change a view, point at it and click the pen, **Edit**, or double-click the view. The **…** button beside the pen has **Move up**, **Move down** and **Delete**. The view's right-click menu has the same items, and **Edit**.

GitHub starts with **My pull requests** and **Review requests**. Linear starts with **My issues**: issues assigned to you that are in the backlog, to do or in progress.

A **GitHub view** has:

- **Name**.
- **Search**: a search in GitHub's own syntax, as on github.com. Click a chip under the box, such as `author:@me`, `review-requested:@me` or `org:`, to add it to the search. To show only the repositories of one organisation, add `org:` and the organisation's name.

A **Linear view** has:

- **Name**.
- **Assigned to**: **Me**, **Anyone** or **No one**.
- **Teams**: **Every team**, or the teams you pick.
- **States**: the states to show. When you pick none, the view shows every state.

## Start a task from an issue

A Linear view can start a task for any of its issues. In the view's form, turn on **Start a task from each issue** and fill in:

- **Folder**: where the task works. Type a path or click **Choose…**.
- **Agent**: **Claude**, **Codex** or **OpenCode**, with a model and an effort. To use the agent's default model, leave the model empty.
- **Prompt**: what Zero tells the task. Zero fills in `{key}`, `{title}` and `{url}` from the issue. The default is `Work on {key}: {title} ({url}).`

Then, in the view, point at an issue and click **Start**, or right-click the issue and choose **Start task**. The task gets the issue's key and title as its name.

The task also gets its own scratchpad, State, where it records where it stands. The prompt tells the task where that scratchpad is, unless you put `{state}` in the prompt yourself.

When an issue already has a task, the issue shows the task's state instead of **Start**. Click the state to open the task. For scratchpads, see [Later, scratchpads and loops](/docs/later-scratchpads-loops).

## Make references in messages open where you want

When an agent's message names a pull request, a commit, an issue or a Slack channel, Zero makes the name a link. Choose where those links go in **Settings › Links**:

| Setting | Where | What it does |
|---|---|---|
| Link pull requests and commits | Settings › Links › GitHub | `repo#123`, `#123` and commit hashes open on GitHub. On by default. |
| Link issues | Settings › Links › Linear | Issue keys such as `ABC-123` open the issue. On by default. |
| Open issues in the Linear app | Settings › Links › Linear | Opens issues in Linear's app, not in the browser. On by default. Greyed out when Linear's app isn't installed. The Linear page in Integrations has the same switch. |
| Slack | Settings › Links › Slack | The Slack workspaces that Zero is connected to. Their #channels and message links open in Slack. **Connect Slack** adds a workspace. **Disconnect** removes it. |
