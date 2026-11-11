---
title: Getting started
description: Install Zero, sign in an agent, and start your first task.
order: 1
---

Zero runs coding agents on your Mac: Claude Code, Codex and OpenCode. You give an agent a job in a folder and it gets to work. When it needs you, it asks in Zero's inbox.

## Check what you need

- **A Mac with macOS 26 or later.** Zero doesn't open on earlier versions.
- **At least one agent CLI.** Zero doesn't include the agents. It runs the ones you have installed:

| Agent | Command Zero runs |
|---|---|
| Claude Code | `claude` |
| Codex | `codex` |
| OpenCode | `opencode` |

## Install Zero

Download Zero from [withzero.dev/download](/download). It needs macOS 26 or later.

1. Open **Zero.dmg**. A window opens with Zero on the left and your **Applications** folder on the right.
2. Drag **Zero** onto **Applications**. Zero updates itself there, and the tools it gives your agents look for it there.
3. Open Zero from your **Applications** folder. Then eject the **Zero** disk in Finder's sidebar.

If you open Zero from somewhere else, such as the disk image or your **Downloads** folder, Zero asks to move itself first. Click **Move to Applications**. Zero copies itself to **Applications**, opens from there and puts the copy you opened in the Trash, or ejects the disk image. If a Zero is already in **Applications**, it goes to the Trash. If your account can't add apps to **Applications**, Zero goes in the **Applications** folder in your home folder instead.

Each release also has **Zero.zip**, the same app zipped. Zero's updater uses it.

Zero is a menu bar app. It shows in the Dock only while one of its windows is open.

## Make sure Zero can find your agents

Zero starts each agent with zsh as a login shell, like a new Terminal window does. A command that works in a new Terminal window works in Zero too, wherever it's installed: with Homebrew, in `~/.local/bin` or through a Node version manager.

To check, open Terminal and run:

```sh
zsh -lic 'command -v claude codex opencode'
```

Each agent you have installed prints its path. One that prints nothing isn't on the PATH that zsh sets in `~/.zprofile` or `~/.zshrc`. Add it there and run the command again. You don't need to restart Zero.

## Go through the welcome

The first time you open Zero, a welcome window walks you through five steps. Click **Continue** for the next step, or **Back** to go back.

1. **Welcome to Zero.** What the control bar and the inbox are.
2. **Your agents.** Shows whether Claude Code and Codex are installed. For Claude Code, click **Add plugin** to install the Zero plugin. The plugin lets Claude Code ask you things in Zero. Once it's installed, the button reads **Plugin added**. The Codex row is for information only.
3. **Permissions.** To dictate replies, click **Allow** beside **Microphone** and **Speech recognition**. Both permissions are optional.
4. **Make it yours.** Set the **Talk hotkey**. Turn on **Launch Zero at login**. Turn **Follow the active screen** on or off for the control bar. The Talk hotkey is <kbd>⌥</kbd> <kbd>Space</kbd> unless you change it.
5. **Try it.** Click **Send test ask**. A sample ask opens in the inbox, just like one from an agent. Press <kbd>1</kbd> to answer it. Then click **Done**.

macOS also asks whether Zero can send notifications. Allow them so you hear when a task needs you.

To see the welcome again, open **Settings › General › Advanced › Onboarding** and click **Open**. Open Settings with <kbd>⌘</kbd> <kbd>,</kbd> or the gear at the foot of the window's left rail.

## Sign in an agent

An agent needs an account to work. Give it one in either of two ways:

- **Use the sign-in the agent already has.** When Claude Code, Codex or OpenCode already works in your Terminal, Zero's tasks use that sign-in. You set up nothing in Zero.
- **Add accounts to Zero.** Open **Settings › Accounts** and click **Add account** beside the agent's name. Sign in with your Claude or ChatGPT subscription, or add an API key. Zero keeps the account and gives it to the agent when a task starts. With more than one account, a task that reaches one account's usage limit carries on with another.

Once you add an account for an agent in Zero, that agent's tasks use Zero's accounts. See [Accounts and models](/docs/accounts-and-models).

## Add a project folder

Each task works in a project: a folder on your Mac that you added to Zero. To add one:

1. Open **Settings › Folders**.
2. Beside **Projects**, click **Add folder**.
3. Choose one or more folders.

Until you add a folder, the new task page shows **Add a project in Settings › Folders** in place of the project chip.

## Start your first task

1. Open Zero's window: click the Zero icon in the menu bar and choose **Show Zero**.
2. Click **Home**, the house at the top of the left rail. The new task page opens, with a box that says **Do anything**.
3. Look at the chips under the box:
   - **The project.** Click it to choose the folder the task works in.
   - **The agent and model**, on the right of the row. Click it to choose Claude Code, Codex or OpenCode and one of its models. See [Accounts and models](/docs/accounts-and-models).
   - **Permissions**, the wand icon. With **Auto**, the agent decides what's safe and asks you about the rest. With **Unrestricted**, it does anything without asking.
4. Type what you want done, such as "Fix the flaky login test", and press <kbd>Return</kbd>.

The task opens and the agent gets to work. When it needs you, its question shows in the inbox and on its mark in the control bar. See [Tasks and workers](/docs/tasks-and-workers).

## Find your way around

Zero has three places on your screen:

- **The window.** Your tasks and their conversations. The rail on its left side leads to **Home**, **Inbox**, **Later**, **Scratchpads**, **Loops**, **Integrations** and **Settings**. To open it, choose **Show Zero** from the menu bar icon, or open Zero again from the Applications folder.
- **The control bar.** A small bar on the right edge of your screen, halfway down. It shows the inbox and a mark for each task. Point at it to open the inbox. See [The control bar](/docs/control-bar).
- **The menu bar icon.** Zero's mark in the menu bar. Click it for:

| Item | What it does |
|---|---|
| **Show Zero** | Opens the window. |
| **Check for Updates…** | Opens **Settings › General** and checks for a new version. |
| **Settings…** | Opens Settings in the window. |
| **Quit Zero** | Quits the app. |

Closing the window with <kbd>⌘</kbd> <kbd>W</kbd> leaves Zero in the menu bar, with the control bar on screen. Your agents keep working when the window is closed, and even when you quit Zero.

## Keep Zero up to date

Zero checks for a new version when it opens and every six hours after that. It installs one only when you say so.

- When a new version is out, the menu bar icon's menu shows **Update to Zero** and the version. Choose it to go to **Settings › General**.
- In **Settings › General**, the first row shows your version. It reads **Up to date.** with **Check now**, or names the new version with **Update and restart**.

Click **Update and restart**. Zero quits and opens again as the new version. Agents that are working pause between steps for a few seconds, then carry on.
