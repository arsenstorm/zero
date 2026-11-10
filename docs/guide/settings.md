---
title: "Settings"
description: "Every setting: what it does and where it is."
order: 10
---

Settings is part of Zero's window. Its left column lists the pages: **General** first, then three groups. **App** has Control bar, Composer and inbox, and Phone. **Agents** has Agents, Accounts, MCP servers and Browsers. **Work** has Workspaces, Folders, Git, Links and Following.

## Open Settings

- Press <kbd>⌘</kbd> <kbd>,</kbd>.
- Click the gear at the foot of the window's left rail.
- Click Zero's icon in the menu bar and choose **Settings…**.
- Right-click the control bar and choose **Settings…**.

Settings opens on **General**. Each change takes effect at once, so the pages have no Save button.

## General

| Setting | Where | What it does |
|---|---|---|
| Zero and its version | Settings › General › Zero | Shows the version you have and whether it's up to date. **Check now** looks for an update. When an update is out, the row reads **Zero**, the new version's number and **is available**. Click **Update and restart** to install it. Zero quits and opens again as the new version. Running agents pause for a few seconds, then continue. Zero never updates without your click. |
| Launch Zero at login | Settings › General › Zero | Opens Zero when you log in to your Mac, so agents can always reach you. |
| Talk hotkey | Settings › General › Zero | The keys that open the inbox and start dictation, from any app. Click the button, then press a combination that includes <kbd>⌘</kbd>, <kbd>⌥</kbd>, <kbd>⌃</kbd> or <kbd>⇧</kbd>. <kbd>Esc</kbd> cancels. Default: <kbd>⌥</kbd> <kbd>Space</kbd>. |
| Needs you | Settings › General › Notifications | A notification when a task, one of its workers, or an agent outside Zero asks you something. On by default. |
| In trouble | Settings › General › Notifications | A notification when a task fails, gets stuck, runs out of usage, or is blocked. On by default. |
| Finished | Settings › General › Notifications | A notification when a task is done, replied, waiting, or over to you. On by default. |
| Sounds | Settings › General › Notifications | Plays a sound with each notification. While you're in Zero, you hear the sound and get no notification. On by default. Turning it off hides the Sounds section. |
| Needs you, In trouble, Over to you, Replied, Waiting, Done | Settings › General › Sounds | The sound for each task state. Pick one of the Mac's alert sounds, or **None**. You hear it as you pick it. Defaults: Blow for Needs you, Bottle for In trouble, Hero for the rest. The list marks each default with **(default)**. |
| Log | Settings › General › Advanced | **View log** opens the file where Zero records what it did and when. The row shows its path. |
| Onboarding | Settings › General › Advanced | **Open** shows the welcome screens again. |

[Tasks and workers](/docs/tasks-and-workers) explains the task states.

## Control bar

| Setting | Where | What it does |
|---|---|---|
| Follow the active screen | Settings › Control bar › Placement | On: the bar moves to the screen you're using. Off by default. |
| Bar in the window | Settings › Control bar › Placement | Puts the bar inside Zero's window instead of on the screen's edge: **When it fills the screen**, **Always** or **Never**. Default: **When it fills the screen**. |
| Agents in the bar | Settings › Control bar › Agents in the bar | The agents outside Zero that the bar shows. Point at one for the pen, **Rename**, and the bin, **Remove**. The bin is **Remove and stop** when Zero can stop the agent. Drag rows to change the order. A removed agent comes back the next time it asks you something. The list is empty until an agent first asks you something. |

[The control bar](/docs/control-bar) explains the bar itself.

## Composer and inbox

| Setting | Where | What it does |
|---|---|---|
| Suggest skills after / | Settings › Composer and inbox › Composer | Typing <kbd>/</kbd> in a message box lists Claude Code's commands and skills. On by default. |
| Suggest files after @ | Settings › Composer and inbox › Composer | Typing <kbd>@</kbd> also lists files from the task's folder, after your loops. Off by default. |
| Take-back window | Settings › Composer and inbox › Inbox | How long you can press <kbd>Esc</kbd> to take an answer back after you give it: 0 to 5 seconds, in half seconds. Default: 2 seconds. |
| Move to the next ask | Settings › Composer and inbox › Inbox | After you answer, the inbox moves on to the next waiting ask 3 seconds later. On by default. |
| Ask expiry | Settings › Composer and inbox › Inbox | How long an ask waits before it expires, unless the agent sets its own time: 5 to 1,440 minutes, in steps of 5. Default: 60 minutes. |
| Microphone | Settings › Composer and inbox › Dictation | The microphone used when you dictate a reply. **System default** follows the Mac's input, and is the default. When the one you picked isn't connected, the row says so and Zero uses the system default. |

See [The inbox and asks](/docs/inbox-and-asks) for answering asks, and [Tasks and workers](/docs/tasks-and-workers) for the message box.

## Phone

| Setting | Where | What it does |
|---|---|---|
| Address | Settings › Phone › Relay | The address of the relay that passes messages between your phone and this Mac. The messages are encrypted, and the relay can't read them. Zero's own relay by default. To use your own, type its address and press <kbd>Return</kbd>. **Use Zero's** goes back to Zero's relay. |
| Status | Settings › Phone › Relay | Whether the Mac reaches the relay: **Not set up**, **Off**, **Connecting…**, **Connected: your phones can reach this Mac**, **Can't reach it:** and the reason, or **Zero's relay has closed:** and its message. |
| Each paired phone | Settings › Phone › Phones | The phone's name and when it was paired. **Remove** unpairs it. |
| Add a phone | Settings › Phone › Phones | **Show code** shows a QR code to scan with Zero on your phone. The code lasts five minutes. **New code** makes another. **Copy link** copies the same code as a link. It needs a relay address first. |

The iPhone app, coming soon, calls this Mac **Your Mac** and unpairs with **Unpair this phone**. See [The iPhone app](/docs/iphone).

## Agents

| Setting | Where | What it does |
|---|---|---|
| Zero plugin | Settings › Agents › Setup | Lets your agents reach your inbox and use your scratchpads. On: Zero installs its plugin in Claude Code and adds its MCP server to Codex and OpenCode. Off: it takes them out again. When something goes wrong, the reason shows under the row. |
| Archive done tasks | Settings › Agents › Tasks | When Zero archives a done task: **Once you've read it**, **After an hour**, **After a day**, **After a week** or **Never**. Default: **After a day**. An archived task comes back when something it follows changes. |
| Agents' own subagents | Settings › Agents › Tasks | Off, the default: agents hand work to Zero workers, which you can see, steer and stop in Zero. On: Claude Code and Codex can also use their own subagents, which you can't see. The change takes effect the next time each task starts. |
| Where tasks run | Settings › Agents › Tasks | A command that prints, as JSON, the place where each piece of work runs: `[{"ticket": "…", "place": "…"}]`. Zero runs it in your login shell every five minutes. A task filed under one of those tickets shows that place as its Where, instead of its folder. Empty by default. Zero saves it when you press <kbd>Return</kbd> or leave the field. |

See [Tasks and workers](/docs/tasks-and-workers) for workers and archiving.

## Accounts

The page has a section for each agent, **Claude Code**, **Codex** and **OpenCode**, with the accounts it runs as and two buttons:

- **Add account**: sign in with Claude or ChatGPT in your browser, or add an API key. For OpenCode, pick the provider of the key: OpenCode Go, Anthropic, OpenAI or OpenRouter.
- **Add model**: add a model that the agent doesn't list yet, by its id and the name to show in the model picker.

Each account shows how much it has used of its two usage windows, **5h** and **Week**. Point at one to see when it resets. Click an account for **Rename** and **Remove…**. Some Claude accounts also have **Switch to a token**. [Accounts and models](/docs/accounts-and-models) covers all of this in detail.

## MCP servers

Set up an MCP server here once, and Zero gives it to your tasks as they start, in every agent. **Add a server** opens the form. Each server's row has a switch and **Edit**. [Browsers and MCP servers](/docs/browsers-and-mcp) explains every field.

## Browsers

| Setting | Where | What it does |
|---|---|---|
| Zero for Chrome | Settings › Browsers › Chrome | Lets agents use Chrome, each task in tabs of its own. **Set up** installs the extension's files, shows them in Finder and opens Chrome's Extensions page. The row shows whether it's connected. |
| Firefox Developer Edition | Settings › Browsers › Firefox | Zero opens it under remote control when an agent asks for Firefox. **Open** opens it now. Shows **Connected** while it's under Zero's control. |
| Safari's automation windows | Settings › Browsers › Safari | A signed-out Safari window, for comparing how a page looks in each browser. **Try it** checks that it works. |
| Blocked sites | Settings › Browsers › Blocked sites | Sites that no task can use. Type one in **Add a site (bank.com)** and press <kbd>Return</kbd>. To take a site off, point at it and click the bin, **Unblock it**. Empty by default. |

[Browsers and MCP servers](/docs/browsers-and-mcp) explains each browser and how agents use it.

## Workspaces

Each row has a workspace's icon and name. **Shown** marks the one the window shows. Point at a row for the pen, **Edit**, and the bin, **Delete: its tasks are Zero's again**. The **Zero** workspace is always there: it can't be deleted or renamed.

**Add workspace** opens **New workspace**: a **Name** and an **Icon**. Editing a workspace also lists the **MCP servers** its tasks get. See [Workspaces and folders](/docs/workspaces-and-folders).

## Folders

| Setting | Where | What it does |
|---|---|---|
| Projects | Settings › Folders › Projects | The folders tasks start in. **Add folder** adds one or more. Click a folder for **Rename…**, **Show in Finder** and **Remove**. **Rename…** changes the name Zero shows for it. Empty by default. |
| Drop folders | Settings › Folders › Drop folders | Folders where agents on other machines leave their asks as files, synced to this Mac. **Add drop folder** takes a pattern such as `~/projects/*/.zero`, typed or picked with **Choose…**. Click one to **Remove** it. Empty by default. |

See [Workspaces and folders](/docs/workspaces-and-folders).

## Git

These settings change how agents commit: only the agents' Git, not your own terminal's.

| Setting | Where | What it does |
|---|---|---|
| Sign with the agents' own key | Settings › Git › Agents' commits | On: the account below commits and signs the agents' commits, and you stay the author. Off by default. |
| Account | Settings › Git › Agents' commits | The GitHub account that commits and signs. **Choose…** asks for its GitHub login. Zero uses the account's name and noreply email. The row then shows the login, name and email, and the button reads **Change…**. |
| Signing key | Settings › Git › Agents' commits | The private key agents sign with. It must have no passphrase. **Choose…** picks the file. **Replace…** picks another. A pill shows **On** and the login when the key is one of the account's signing keys on GitHub, so commits show as Verified. It shows **Not on** and the login when you still need to add it there. |
| Push over HTTPS | Settings › Git › Agents' commits | Agents push to GitHub with the GitHub CLI's sign-in instead of SSH, so a push doesn't wait on your own key. On by default. |
| Folders | Settings › Git › Folders | Keeps the agents' Git identity to these folders. An empty list means **Every folder**, the default. **Add folder** adds one. **Remove** takes it off. |

## Links

These settings decide what opens when you click a reference in a message.

| Setting | Where | What it does |
|---|---|---|
| Link pull requests and commits | Settings › Links › GitHub | `repo#123`, `#123` and commit hashes in messages open on GitHub. On by default. |
| Link issues | Settings › Links › Linear | Issue keys such as `ABC-123` in messages open the issue. On by default. |
| Open issues in the Linear app | Settings › Links › Linear | Opens issues in Linear's app instead of the browser. On by default. Turned off and greyed out when Linear's app isn't installed or **Link issues** is off. |
| Slack | Settings › Links › Slack | The Slack workspaces Zero is connected to. Their channels and message links open in Slack. **Connect Slack** adds one. **Disconnect** removes it. **No workspace connected** until you add one. |

[Following and integrations](/docs/following-and-integrations) explains connecting Slack.

## Following

Everything your agents follow, grouped by GitHub, Linear and Slack. To stop following one, point at its row and click **×**, **Unfollow**. Click the task's name to open the task. [Following and integrations](/docs/following-and-integrations) explains the rows.

## Remembered without a setting

Zero also remembers these as you use it:

- How wide you dragged the sidebars. One width counts for all of them.
- The agent and project you last picked for a new task.
- How the tasks sidebar is sorted, the order you dragged tasks into, and which tasks have their workers folded.
- The workspace the window shows, and whether a task's details pane is open.
- The order of the integrations in the rail, and which states are folded in each Linear view.
- Your unsent drafts, and where you scrolled to in each conversation.
- The names you gave agents and their order in the control bar.
