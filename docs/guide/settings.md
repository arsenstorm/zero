---
title: "Settings"
description: "Every setting in Zero: what it does, where it is and what it's set to by default."
order: 10
---

Settings is part of Zero's window. Its left column lists the pages. **General**, **Inbox**, **Control bar** and **Phone** come first. Then three groups follow. **Agents** has Agents, Accounts and models, Git, Browsers and MCP servers. **Work** has Workspaces. **Connections** has GitHub, Linear and Slack.

## Open Settings

- Press <kbd>⌘</kbd> <kbd>,</kbd>.
- Click the gear at the foot of the window's left rail.
- Click Zero's icon in the menu bar and choose **Settings…**.
- Right-click the control bar and choose **Settings…**.

Settings opens on **General**. When Zero's own checks find a problem, the gear has an orange dot, and Settings opens on General: the problem is in its **Health** section, near the foot. Each change takes effect at once, so the pages have no Save button.

## General

While Zero's plugin or an account is missing, the page starts with **Set up Zero**, a list of what's left to do:

| Step | Button | What it does |
|---|---|---|
| Zero plugin in your agents | **Install** | Installs the plugin, so agents ask you in Zero instead of waiting in a terminal. |
| An account for an agent | **Add account** | Opens **Accounts and models**. |
| Your phone (optional) | **Pair** | Opens **Phone**. |
| Chrome for agents (optional) | **Set up** | Opens **Browsers**. |

A step you've done shows **Done**. The list goes away once the plugin and an account are there.

| Setting | Where | What it does |
|---|---|---|
| Launch Zero at login | Settings › General › Zero | Opens Zero when you log in to your Mac, so agents can always reach you. |
| Inbox hotkey | Settings › General › Zero | The keys that open the inbox, from any app. Click the button, then press a combination that includes <kbd>⌘</kbd>, <kbd>⌥</kbd>, <kbd>⌃</kbd> or <kbd>⇧</kbd>. <kbd>Esc</kbd> cancels. Default: <kbd>⌥</kbd> <kbd>Space</kbd>. |
| Needs you | Settings › General › Notifications | A notification when a task asks you something or has a step for you (**Over to you**), or one of its workers asks. Asks from agents outside Zero count too. On by default. |
| In trouble | Settings › General › Notifications | A notification when a task fails, gets stuck, runs out of usage, or is blocked. On by default. |
| Finished | Settings › General › Notifications | A notification when a task is done, replied, or waiting on someone else. On by default. |

Each kind of notification has a switch and a sound chip. The chip lists the Mac's alert sounds and **None**. You hear a sound as you pick it. The list marks the default with **(default)**: Blow for Needs you, Bottle for In trouble, Hero for Finished.

At the foot of General, **About**, **Health** and **Help**:

| Setting | Where | What it does |
|---|---|---|
| Zero and its version | Settings › General › About | Shows the version you have and whether it's up to date. **Check now** looks for an update. When an update is out, the row reads **Zero**, the new version's number and **is available**. Click **Update and restart** to install it. Zero quits and opens again as the new version. Running agents pause for a few seconds, then continue. Zero never updates without your click. |
| Start Zero's daemon at login | Settings › General › About | Shown only when the daemon doesn't start at login. Then it starts when Zero opens, not at login, and not without the app. When it's off in the Mac's Login Items, **Login Items** opens the Mac's settings, where you switch Zero back on. A build that can't add it shows **Not in this build**. |
| Icons | Settings › General › About | Which icons this copy of Zero draws. **Icons: Nucleo** in official builds. **Icons: Lucide** in a build from source, which differs in nothing else. |
| Health | Settings › General › Health | Zero's own checks: **zerod**, **The zero command**, **Quarantine**, **Open files**, **zerod's build**, **Crashes** and **Zero's window**. Each has its state as a pill: **OK**, **Past** for a crash or hang that isn't recent, **Look**, **Failing** or **Unknown**. A check that found a problem has its fix beside it: **Restart zerod**, **Start zerod**, **Open report** or **Dismiss**. **Check now** runs the checks again. |
| Show log | Settings › General › Help | **Show log** opens the file where Zero records what it did and when. The row shows its path. |
| Show welcome again | Settings › General › Help | **Open** shows the welcome screens again. |

To give each task state its own sound, choose **Each state's sound…**. The dialog has a sound for **Needs you**, **Over to you**, **In trouble**, **Blocked**, **Replied**, **Waiting** and **Done**. Defaults: Blow for Needs you and Over to you, Bottle for In trouble and Blocked, Hero for the rest. When the states of one kind have different sounds, its chip reads **Each state's sound…**.

While you're in Zero, you hear the sound and get no notification. **None** turns the sound off for that kind.

[Tasks and workers](/docs/tasks-and-workers) explains the task states.

## Inbox

| Setting | Where | What it does |
|---|---|---|
| Undo an answer | Settings › Inbox › Answers | How long you can press <kbd>Esc</kbd> to take an answer back after you give it: **Off**, **1 s**, **2 s**, **3 s** or **5 s**. Default: **2 s**. |
| Unanswered asks expire after | Settings › Inbox › Answers | How long an ask waits before it expires, unless the agent sets its own time: **15 min**, **1 h**, **4 h**, **1 day** or **Never**. Default: **1 h**. |

A time you set in an earlier version of Zero stays in the list of choices.

## Control bar

| Setting | Where | What it does |
|---|---|---|
| Show the control bar | Settings › Control bar › Control bar | Off: asks reach you in Zero's window, in notifications and on the Dock instead. While it's off, the bar's other settings are greyed out and read **The control bar is off.** On by default. |
| Follow the active screen | Settings › Control bar › Placement | On: the bar moves to the screen you're using. Off by default. |
| Show the bar in Zero's window | Settings › Control bar › Placement | Puts the bar inside Zero's window instead of on the screen's edge: **When it fills the screen**, **Always** or **Never**. Default: **When it fills the screen**. |
| Agents in the bar | Settings › Control bar › Agents in the bar | The agents outside Zero that the bar shows. Point at one for the pen, **Rename**, and the bin, **Remove**. The bin is **Remove and stop** when Zero can stop the agent. Drag rows to change the order. A removed agent comes back the next time it asks you something. The list is empty until an agent first asks you something. |

See [The control bar](/docs/control-bar) for the bar, and [The inbox and asks](/docs/inbox-and-asks) for answering asks.

## Phone

| Setting | Where | What it does |
|---|---|---|
| Relay server | Settings › Phone › Relay | The relay that passes messages between your phone and this Mac. The messages are encrypted, and the relay can't read them. Default: **Zero's relay**. To use your own, choose **Your own relay…**, type its `wss://` address and click **Use it**. **Change address…** changes it later. Phones paired before must pair again. The row shows the status under its name: **Off**, **Connecting…**, **Connected: your phones can reach this Mac**, **Can't reach it:** and the reason, or **It has closed:** and the relay's message. When the day's 2 GB through the relay are used, it says so. |
| Pair phone | Settings › Phone › Phones | Opens the steps to pair a phone and shows a QR code to scan with Zero on your phone. The code lasts five minutes. **New code** makes another. **Copy link** copies the same code as a link. |
| Each paired phone | Settings › Phone › Phones | The phone's name and when it was paired. **Remove** unpairs it. **None yet** until you pair one. |

The iPhone app, coming soon, calls this Mac **Your Mac** and unpairs with **Unpair this phone**. See [The iPhone app](/docs/iphone).

## Agents

| Setting | Where | What it does |
|---|---|---|
| Zero plugin | Settings › Agents › Setup | Lets your agents reach your inbox and use your scratchpads. On: Zero installs its plugin in Claude Code and adds its MCP server to Codex and OpenCode. Off: it takes them out again. When something goes wrong, the reason shows under the row. |
| Archive done tasks | Settings › Agents › Tasks | When Zero archives a done task: **Once you've read it**, **After an hour**, **After a day**, **After a week** or **Never**. Default: **After a day**. An archived task comes back when something it follows changes. |
| Terminal app | Settings › Agents › Tasks | The app a task opens in, and where **Terminal** on a running command follows its output: Ghostty, Terminal, iTerm or Warp when installed, each with its icon, or **Other app…**. The task's actions name the app you chose, such as **Open in Ghostty**. By default, Ghostty when it's installed, else Terminal. |
| Suggest files after @ | Settings › Agents › Tasks | Typing <kbd>@</kbd> in a message box also lists files from the task's project, after your loops. Off by default. |
| When a command looks stuck | Settings › Agents › Stuck commands | What Zero does about a command that looks stuck: **Tell me**, **Stop it** or **Never check**. A command looks stuck when it runs well past its usual time with no output and no CPU, or waits for input that no one will type. When Zero stops one, it tells the agent why, and the agent carries on. |
| Thresholds | Settings › Agents › Stuck commands | When a command counts as stuck, in one line. **Change…** opens a dialog: **Hung after** (no output and no CPU for 1 to 15 minutes), **Past its usual time** (2× to 10× its usual time, and at least 1 to 30 minutes), and **Never stop commands containing**, words separated by commas, such as `migrate, deploy`. Hidden when the setting above is **Never check**. |

**Advanced** holds the settings that few people change. Click **Show** in its heading to see them, and **Hide** to fold them away again.

| Setting | Where | What it does |
|---|---|---|
| Let agents use their own subagents | Settings › Agents › Advanced | Off, the default: agents hand work to Zero workers, which you can see, steer and stop in Zero. On: Claude Code and Codex can also use their own subagents, which you can't see. The change takes effect the next time each task starts. |
| Summarise conversations at | Settings › Agents › Advanced | The size at which agents summarise their conversation: **CLI's default** (each CLI's own size), **200k**, **400k**, **600k**, **800k**, or **Other** for a number of tokens you type, such as `350k`. Each turn sends the whole conversation again, so on a model with a 1M-token context, summarising earlier makes long tasks use much less. The cost is that some detail is lost at each summary. Applies to Claude Code and Codex. OpenCode keeps its own size. The change takes effect the next time each task starts. |
| Shared build cache | Settings › Agents › Advanced | Agents' copies of a project reuse each other's compiled dependencies. Zero passes the tools to agents but never installs them. When this Mac lacks one, a pill such as **needs sccache** shows beside the switch. Point at the pill for the `brew install` command. Off by default. |
| Task places command | Settings › Agents › Advanced | A command that tells Zero which folder each ticket's task runs in. Empty by default. See below. |

The task places command must print JSON: a list of tickets and their places, such as `[{"ticket": "…", "place": "…"}]`. Zero runs it in your login shell every five minutes. A task filed under one of those tickets shows that place as its **Where**, instead of its folder. Zero saves the command when you press <kbd>Return</kbd> or leave the field.

See [Tasks and workers](/docs/tasks-and-workers) for workers and archiving.

## Accounts and models

The page has a section for each agent, **Claude Code**, **Codex** and **OpenCode**, with the accounts it runs as and two buttons:

- **Add account**: sign in with Claude or ChatGPT in your browser, or add an API key. For OpenCode, pick the provider of the key: OpenCode Go, Anthropic, OpenAI or OpenRouter.
- **Add model**: add a model that the agent doesn't list yet, by its id and the name to show in the model picker.

Click an account to open it in place: how much it has used of each usage window, when each resets, and its activity by day. Its **⋯** menu has **Rename** and **Remove…**. Claude accounts also have **Switch to a browser sign-in** or **Switch to a token**. [Accounts and models](/docs/accounts-and-models) covers all of this in detail.

## Git

These settings change who agents commit as: only the agents' Git, not your own terminal's.

| Setting | Where | What it does |
|---|---|---|
| Agents commit as their own account | Settings › Git › Agents' commits | On: the account below commits and signs the agents' commits, so they show as verified. Your terminal keeps your own key. Off by default. While it's off, the rows below are hidden, and agents' commits are as yours. |
| Account | Settings › Git › Agents' commits | The GitHub account that commits and signs. **Choose…** asks for its GitHub login. Zero uses the account's name and noreply email. The row then shows the login, name and email, and the button reads **Change…**. |
| Signing key | Settings › Git › Agents' commits | The private key agents sign with. It must have no passphrase. **Choose…** picks the file. **Replace…** picks another. A pill shows **On** and the login when the key is one of the account's signing keys on GitHub, so commits show as Verified. It shows **Not on** and the login when you still need to add it there. |
| Credit you as co-author | Settings › Git › Agents' commits | Off, the default: you stay the author, and the agents' account is the committer. On: the agents' account is both author and committer, and Zero adds a `Co-authored-by` trailer for you to new commits. The repository's own hooks run first. An amend doesn't add a second trailer. |
| Your name and email | Settings › Git › Agents' commits | Shown while **Credit you as co-author** is on. The name and email in the trailer. **Set…** changes them. Left blank, Zero uses each repository's `user.name` and `user.email`. If neither has them, the commit stops and asks you to set them. |
| Only in these folders | Settings › Git › Only in these folders | Keeps the agents' account, and their GitHub token, to these folders and the folders inside them. With no folders added, it reads **Every folder**, the default. **Add folder** adds one. **Remove** takes it off. Shown while the agents' own account or their GitHub token is on. |

The agents' GitHub token and how they push are on the GitHub page, under **Agents' access**.

## Workspaces

Each row has a workspace's icon and name. **Shown** marks the one the window shows. Point at a row for the pen, **Edit**, and the bin, **Delete: its tasks are Zero's again**. The **Zero** workspace is always there: it can't be deleted or renamed.

**Add workspace** opens **New workspace**: a **Name**, an **Icon** and a **Colour**. Editing a workspace also lists the **MCP servers** its tasks get.

| Setting | Where | What it does |
|---|---|---|
| Projects | Settings › Workspaces › Projects | The folders that **New task** offers. **Add folder** adds one or more. Click a folder for **Rename…**, **Show in Finder** and **Remove**. **Rename…** changes the name Zero shows for it. Empty by default. |

See [Workspaces and folders](/docs/workspaces-and-folders).

## GitHub

| Setting | Where | What it does |
|---|---|---|
| Connection | Settings › GitHub › Connection | Zero uses the GitHub CLI and the account it's signed in to. Until then, **Connect GitHub** shows `gh auth login` to run in a terminal, and **Check again**. |
| Link pull requests and commits | Settings › GitHub › Links | `repo#123`, `#123` and commit hashes in messages open on GitHub. On by default. |
| Give agents their own GitHub token | Settings › GitHub › Agents' access | Limits what agents' `gh` commands and pushes can reach. Turning it on without a saved token opens **Agents' GitHub token**. The dialog lists the permissions to give: Contents and Pull requests read and write, Checks and Actions read, and no Administration. **Create a token on GitHub** opens GitHub's page for a fine-grained token. Choose only the repositories agents need. Zero keeps the token in your Keychain. The token applies only in the folders of **Settings › Git › Only in these folders**. Off by default. |
| Token | Settings › GitHub › Agents' access | Shown once a token is saved: its GitHub owner, and its expiry when GitHub reports one. **Remove** deletes it and turns the token off. **Replace…** saves another. |
| Push with the GitHub CLI's sign-in | Settings › GitHub › Agents' access | Agents push to GitHub over HTTPS with the GitHub CLI's sign-in, instead of SSH, which may wait on your own key. Works only while **Agents commit as their own account** is on in Git. While the agents' token is on, it stays on and reads **The token pushes over HTTPS.** Off by default. |
| Following | Settings › GitHub › Following | The pull requests agents follow. Shown once GitHub is connected. |

## Linear

| Setting | Where | What it does |
|---|---|---|
| Connection | Settings › Linear › Connection | **Connect Linear** signs in in your browser. Kept on this Mac. The row's **Disconnect** button removes it. |
| Link issues | Settings › Linear › Links | Issue keys such as `ABC-123` in messages open the issue. On by default. |
| Open issues in the Linear app | Settings › Linear › Links | Opens issues in Linear's app instead of the browser. On by default. Turned off and greyed out when Linear's app isn't installed or **Link issues** is off. |
| Let agents make changes | Settings › Linear › Agents | Agents read Linear through Zero with `zero linear`. When this is on, they can also change it, and you approve each change first. Zero asks Linear for write access only while this is on, so disconnect and connect Linear again after you change it. Only Zero's app can change this setting. Off by default. |
| Following | Settings › Linear › Following | The issues agents follow. Shown once Linear is connected. |

## Slack

| Setting | Where | What it does |
|---|---|---|
| Workspaces | Settings › Slack › Workspaces | The Slack workspaces Zero is connected to. Their channels and message links open in Slack. **Connect Slack** adds one. Each workspace's row has a **Disconnect** button that removes it. |
| Let agents post | Settings › Slack › Agents | Agents read Slack through Zero with `zero slack`. When this is on, they can also post, and you approve each post first. Zero's Slack app has the `chat:write` scope only while this is on. After you change it, add or remove `chat:write` in the app's **User Token Scopes** in Slack, reinstall the app and connect Slack again with the new token. Only Zero's app can change this setting. Off by default. |
| Following | Settings › Slack › Following | The threads and channels agents follow. Shown once Slack is connected. |

To stop a follow, point at its row under **Following** and click **×**, **Unfollow**. Click the task's name to open the task. A task's own follows are also in its details pane, under **Follows**. [Following and integrations](/docs/following-and-integrations) explains connecting each service and the rows.

## MCP servers

Set up an MCP server here once, and Zero gives it to your tasks as they start, in every agent. **Add a server** opens the form. Each server's row has a switch and **Edit**. In the form, **Start when first used** keeps a command's server stopped until a task first calls it. Until then, Zero answers from what the server said last time.

**Claude Code's servers** lists the servers in Claude Code's own settings, each with its project or **Every project**. One that needs you to sign in shows **Needs sign-in** and **Sign in**, which opens its sign-in page in your browser. One that isn't in Zero yet shows **Manage in Zero**, which opens the form with the server's settings filled in. Save it, and Zero gives it to every task in every agent and account. [Browsers and MCP servers](/docs/browsers-and-mcp) explains every field.

## Browsers

| Setting | Where | What it does |
|---|---|---|
| Zero for Chrome | Settings › Browsers › Chrome | Lets agents use Chrome, each task in tabs of its own. **Set up** installs the extension's files, shows them in Finder and opens Chrome's Extensions page. The row shows whether it's connected. |
| Firefox Developer Edition | Settings › Browsers › Firefox | Zero opens it under remote control when an agent asks for Firefox. **Open** opens it now. Shows **Connected** while it's under Zero's control. |
| Let agents use Safari | Settings › Browsers › Safari | A signed-out Safari window, for comparing how a page looks in each browser. **Try it** checks that it works. |
| Blocked sites | Settings › Browsers › Blocked sites | Sites that no task can use. Type one in **Add a site (bank.com)** and press <kbd>Return</kbd>. To take a site off, point at it and click the bin, **Unblock it**. Empty by default. |

[Browsers and MCP servers](/docs/browsers-and-mcp) explains each browser and how agents use it.

## Remembered without a setting

Zero also remembers these as you use it:

- How wide you dragged the sidebars. One width counts for all of them.
- The agent and project you last picked for a new task.
- How the tasks sidebar is sorted, the order you dragged tasks into, and which tasks have their workers folded.
- The workspace the window shows, and whether a task's details pane is open.
- Your unsent drafts, and where you scrolled to in each conversation.
- The names you gave agents and their order in the control bar.
- Whether **Advanced** is open on the Agents page.
