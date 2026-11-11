---
title: "Troubleshooting"
description: "What to check when Zero, an agent, the control bar or the iPhone app doesn't work."
order: 14
---

When no section helps, [the logs](#read-the-logs) show what Zero and your agents did.

## An agent isn't found

You see one of these:

- The welcome's **Your agents** step says **Not installed** beside Claude Code or Codex.
- A task fails as soon as it starts.

Zero doesn't include the agents. It starts each one with zsh as a login shell, as a new Terminal window does, so it looks only where your shell looks. To see what Zero sees, open Terminal and run:

```sh
zsh -lic 'command -v claude codex opencode'
```

Each installed agent prints its path. For each agent that prints nothing:

1. Install the agent, or find where it's installed.
2. Add its folder to the PATH in `~/.zprofile` or `~/.zshrc`. Do this even when you use another shell every day. Zero always uses zsh.
3. Run the command again until the path prints.

New tasks get the change without a restart of Zero. The welcome checks only once, when it opens. To check again there, open **Settings › General › Advanced › Onboarding** and click **Open**.

A task's own errors, such as `command not found`, are in its `stderr.log`. See [Read the logs](#read-the-logs).

## Signing in doesn't work

Accounts are in **Settings › Accounts**. To open Settings, press <kbd>⌘</kbd> <kbd>,</kbd> or click the gear at the foot of the window's left rail.

| What you see | What to do |
|---|---|
| **Sign in with Claude** stays on **Finish signing in on Claude's page in your browser.** | Finish signing in on the page that opened in your browser. If Claude shows a code there, paste it into **Its code, if Claude shows one** and click **Send**. |
| "Couldn't start Claude Code's sign-in." | Zero couldn't run Claude Code. Make sure that Zero finds it. See [An agent isn't found](#an-agent-isnt-found). |
| "Claude Code's sign-in ended without a token. Try again." | Click **Try again** and finish signing in. Zero waits ten minutes for a sign-in. |
| A ChatGPT account stays on **Signing in… finish in your browser**, then goes away | The sign-in was refused, or it didn't finish within 15 minutes. Click **Add account** › **Sign in with ChatGPT** again. |
| A task says an account "isn't in the Keychain any more: sign in again" | The account's token or key is no longer in your Keychain. Click the account's **⋯**, choose **Remove…**, then click **Remove** in its row. Then add the account again. |
| A task fails with a sign-in error, and Zero has no accounts for that agent | Without accounts in Zero, tasks use the agent's own sign-in. Sign the agent in again in Terminal, or add an account in **Settings › Accounts**. |

See [Accounts and models](/docs/accounts-and-models).

## A task stops at a usage limit

When an account reaches its usage limit, Zero moves the task to another account of the same agent that isn't at a limit. The task then continues by itself.

When no other account can take over, the task shows **Usage limit** at the end of its conversation, with the time when the limit resets. Choose one:

- **Wait.** When Zero knows the reset time, the task continues by itself after the limit resets.
- **Hand it to another agent.** Click **Continue with Codex** or **Continue with Claude Code** in the same place. The other agent takes over the task and its conversation.
- **Add an account.** Add another account for the agent in **Settings › Accounts**. New tasks use it.

To see how close an account is to its limits, click its row in **Settings › Accounts**. The row opens in place with **Last 5 hours** and **This week**: how much of each is used, and when it resets. A bar turns orange at 90% and red at 100%. An account at its limit says **At its limit** in red on its row.

When a task says your account "can't use" a model, Zero moves the task to an account that can, if you have one. Otherwise, pick another model in the task's composer.

## You can't see the control bar

The control bar is on the right edge of one screen, halfway down. It shows in every Space, including over apps in full screen.

- **Is Zero running?** Look for Zero's icon in the menu bar. If the icon isn't there, open Zero from your Applications folder.
- **More than one screen?** The bar stays on the screen where it showed first. To move it to the screen you're using, turn on **Settings › Control bar › Placement › Follow the active screen**.

See [The control bar](/docs/control-bar).

## Asks don't reach you

Agents reach you with the `zero` command. Do these checks in order.

**Zero is running.** An agent's `zero` command can say "Zero.app is not running" or "Zero's daemon isn't running". In that case, open Zero. Turn on **Settings › General › Zero › Launch Zero at login**, so agents can always reach you.

**The agent can find the `zero` command.** Agents use `~/.local/bin/zero`, which points at the copy inside Zero.app. Zero puts it there when it updates. To check it, run this in Terminal:

```sh
ls -l ~/.local/bin/zero
```

If the file is missing, make it:

```sh
mkdir -p ~/.local/bin && ln -sf /Applications/Zero.app/Contents/MacOS/zero-cli ~/.local/bin/zero
```

**Claude Code has the Zero plugin.** The plugin teaches Claude Code to ask you in Zero. Turn on **Settings › Agents › Setup › Zero plugin**. When Zero can't install the plugin, the reason shows under the switch. The same switch adds Zero's tools to Codex's and OpenCode's configuration.

**The ask hasn't expired.** An ask without its own expiry expires after 60 minutes and leaves **Waiting on you**. To give asks more time, change **Settings › Composer and inbox › Inbox › Ask expiry**. Answered asks are under **Answered** on the **Inbox** page, the tray in the window's left rail.

**The agent is on another machine.** Agents on other machines leave their asks as files in a folder that Zero watches. To add that folder, go to **Settings › Folders › Drop folders** and click **Add drop folder**.

**No notifications.** When asks reach the inbox but no notifications come, check that Zero may send them in macOS's **System Settings › Notifications**. Then check that the kinds you want are on in **Settings › General › Notifications**.

## Your iPhone doesn't connect

The iPhone app, coming soon, reaches your Mac through a relay. The relay is a server that passes your phone's encrypted messages without being able to read them. Notifications on your iPhone come through the relay too.

On the Mac, open **Settings › Phone**. The **Relay** row shows which relay Zero uses on its right: **Zero's relay** by default. Under the word **Relay**, the row says how the connection is:

| The **Relay** row reads | What it means |
|---|---|
| **Connecting…** | Zero is connecting to the relay. |
| **Connected: your phones can reach this Mac** | The Mac side works. |
| **Can't reach it:** and a reason | Make sure that the relay's address is correct and that the Mac is online. |
| **Today's 2 GB through the relay are used** | Your phones reach this Mac again after 00:00 UTC. To have no limit, run your own relay from `apps/relay`. |
| **It has closed:** and a message | The relay no longer runs. Follow the message, such as running your own relay from `apps/relay`. |

To use your own relay, click the relay's name on the **Relay** row and choose **Your own relay…**. Type its address, which starts with `wss://`, and click **Use it**. Phones paired before then must pair again with a new code.

To pair a phone, click **Pair phone** under **Phones**. On the **Scan the code** step, the code expires after five minutes. Click **New code** to get another. For a phone without a camera, **Copy link** copies the same code as a link.

On the iPhone, **Can't reach** and your Mac's name means that the phone can't get through. Zero must be open on your Mac, and the Mac must be online. Tap **Try again**. The iPhone's own Settings page shows the same status under **Your Mac › Connection**, with **Reconnect**.

To start again, remove the phone on the Mac: in **Settings › Phone › Phones**, click **Remove**. Or tap **Unpair this phone** in the iPhone's Settings, then **Unpair**. Then pair again.

Zero logs each phone that connects or is refused in `~/.zero/zero.log`. These lines start with `phone:` and `phones:`. Lines about notifications sent to your iPhone start with `push:`.

## Read the logs

Zero keeps its logs in the `.zero` folder in your home folder. To open this folder in Finder, press <kbd>⇧</kbd> <kbd>⌘</kbd> <kbd>G</kbd> and type `~/.zero`.

| File | What it holds | How to open it |
|---|---|---|
| `~/.zero/zero.log` | What the app did and when: phone connections, notification permission, and problems it found. The previous log is beside it as `zero.log.1`. | **Settings › General › Advanced › Log › View log** |
| `~/.zero/zerod.log` | Messages from Zero's background service, which runs your tasks. For example, failed sign-ins and usage that it couldn't read. | Open it from Finder. |
| `~/.zero/asks.jsonl` | Every ask and every answer, one per line. | Right-click the control bar away from the tasks' dots, and choose **Open Log**. |
| `~/.zero/zerod/sessions/` | A folder for each task. `transcript.jsonl` holds everything that the task and its agent said to each other. `stderr.log` holds the agent's own errors. | Open it from Finder. The folder with the most recent change belongs to the task that worked last. |

The logs can hold your code and conversations. Read them before you share them.

## Updating Zero fails

Zero checks for updates when it opens and every six hours. The first row of **Settings › General** shows the result. When a check or an update fails, the row says why and shows **Check again**:

| Message | What to do |
|---|---|
| "Couldn't reach Zero's releases on GitHub" | Make sure that your internet connection works. Then click **Check again**. |
| "Couldn't download Zero" and the version | Click **Check again**, then **Update and restart**. |
| "Couldn't unzip Zero" and the version | Do the same: click **Check again**, then **Update and restart**. |
| "isn't signed as this Zero is, so it wasn't installed" | Zero installs only updates signed the same way as your Zero, so it skipped this one. Your Zero keeps working as it is. |

While the update installs, the row reads **Updating to Zero** and the version. Zero quits and opens again as the new version. Agents that are working continue after a pause of a few seconds.
