---
title: "Browsers and MCP servers"
description: "Let agents use your browser, and give them more tools."
order: 9
---

Agents can use your own Chrome, signed in as you, and each task gets its own tabs. Agents can also use Firefox Developer Edition, and compare a page across Chrome, Firefox and Safari.

MCP servers give agents more tools. Add a server once in Zero, and every task gets it.

## Let agents use Chrome

Agents use Chrome through Zero for Chrome, an extension that you add to Chrome once.

1. Open **Settings › Browsers**. To open Settings, press <kbd>⌘</kbd> <kbd>,</kbd> or click the gear at the foot of the window's left rail.
2. Under **Chrome**, click **Set up** on the **Zero for Chrome** row. Finder shows the extension's folder, and Chrome opens its Extensions page.
3. On Chrome's Extensions page, turn on **Developer mode**.
4. Click **Load unpacked** and pick the folder that Finder shows. Its path is also under the row in Settings.

Zero for Chrome connects by itself. The row then reads **Connected · each task works in tabs of its own**, and the button reads **Set up again**. Before that, the row reads **Not connected · set it up so agents can use Chrome**.

You set it up once. When a new version of Zero brings a newer extension, the extension reloads itself.

Each Chrome profile that has the extension connects as a separate browser.

## What you see while an agent uses Chrome

- **A tab group for each task.** A task's tabs open in a group in the Chrome window that you used last. They open in the background, so the tab you're looking at stays in front. The group's title is Zero and the task's name, after a symbol for the task's state: working, needs you, waiting on something else, or done.
- **A border and a pill on the page.** While a task uses a tab, the page has an orange border. A pill at the bottom shows which task uses the tab. To interrupt the task, click **Stop** on the pill.
- **A window of its own.** An agent with many tabs or a long run can ask for its own window, which opens behind yours. It can also ask for a private window, with none of your sign-ins. For a private window, turn on **Allow in Incognito** on Zero for Chrome's card, on Chrome's Extensions page.

Zero tells agents to close the tabs they opened when they're done.

## What agents can do in the browser

In a task's own tabs, an agent can:

- Open pages, and go back and forward.
- Read a page's elements and text, and take screenshots.
- Click, type, scroll, fill in forms and answer the page's alerts.
- Upload files to a page, up to 10 MB in all.
- Read the console and the page's requests.
- Lay the page out at a phone's or laptop's width.
- Run JavaScript in the page.
- Record a video of the tab while it works, to show you a bug or a feature.

An agent can act only on its own task's tabs and on tabs that you give it.

## Give an agent one of your tabs

1. In Chrome, open the page for the agent.
2. Click Zero in Chrome's toolbar. The popup shows **Connected**, and **Give this tab to a task** with the tasks open in Zero.
3. Click the task.

Zero tells the task that it can use the tab. To take the tab back, open the popup and click the task again, the one with a tick beside it. When the agent is done with a tab that you gave it, the agent gives the tab back and doesn't close it.

## Keep agents off some sites

Open **Settings › Browsers › Blocked sites**. Type a site in **Add a site (bank.com)** and press <kbd>Return</kbd>. Zero also blocks the site's subdomains.

Agents can't open a blocked site or act on a tab that shows one, in Chrome or in Firefox. When an agent compares a page across browsers, Safari's automation window refuses a blocked site too. In Safari, Zero checks the address that each step opens.

To unblock a site, point at it and click the bin, **Unblock it**.

When a task in **Auto** permissions first opens a site, Zero has the task's own agent check that the site fits the task. If the agent advises against the site, it can ask you to allow it. The ask, such as "Open example.com in Chrome", comes to your inbox like any other ask. See [The inbox and asks](/docs/inbox-and-asks).

## Use Firefox

To let agents use Firefox, install Firefox Developer Edition. Agents that ask for Firefox then use it, with your sign-ins. Zero opens it with remote control on and adds its own extension.

In **Settings › Browsers › Firefox**, the **Firefox Developer Edition** row shows **Connected** while Zero controls Firefox. **Open** opens it now.

## Compare a page across browsers

An agent that checks a change to a web page can run one step in Chrome, Firefox and Safari at the same time. It then sees the page in each browser, side by side. Chrome and Firefox are yours, and you're signed in. Safari is an automation window that's signed out of everything and keeps nothing.

To make sure that Safari's automation windows work, open **Settings › Browsers › Safari**. Then click **Try it** on the **Safari's automation windows** row. If Safari refuses remote control, turn on **Allow remote automation** in Safari's own settings, under **Developer**.

## Add an MCP server

An MCP server gives agents more tools, such as a lookup in a database that you use. When a task starts, Zero gives the servers you add to the task's agent: Claude Code, Codex or OpenCode. Servers already set up in the agent's own configuration keep working alongside them.

1. Open **Settings › MCP servers**.
2. Click **Add a server**. The **Add an MCP server** form opens.
3. Fill in the form and click **Save**.

| Field | What it's for |
|---|---|
| Name | The server's name, such as "CVE lookup". |
| **Runs a command** or **At a URL** | How the server runs: a command on your Mac, or a server at an address. A new server starts on **Runs a command**. |
| Command | For **Runs a command**: the program, such as `npx`, `uvx` or a path. |
| Arguments | For **Runs a command**: its arguments, separated by spaces. |
| URL | For **At a URL**: the server's address, such as `https://…/mcp`. A server that signs in with OAuth needs no headers. |
| Environment | For **Runs a command**: values that the server gets, each with a **NAME**. **Add** adds another value. |
| Headers | For **At a URL**: headers sent with each request, each with a **NAME**. |
| Workspaces | **Every workspace**, the default, or the workspaces whose tasks get the server. |

For each value in Environment or Headers, choose where Zero keeps it:

- **Keychain**, the default: in your Mac's Keychain. After you save, the box reads **Kept (type to change)**. To keep the value, leave the box empty.
- **Zero's file**: in Zero's own settings file on this Mac.
- **Its command**: Zero keeps nothing, and the server gets the value itself.

When a server that signs in with OAuth first starts in a task, the task's conversation shows a link to its sign-in page. Open the link on your Mac and sign in.

## Choose which workspaces get a server

In the server's form, turn off **Every workspace**. Then tick the workspaces whose tasks get the server. The server's row in **Settings › MCP servers** shows **Every workspace**, or the names of its workspaces.

Or choose from the workspace: open **Settings › Workspaces**, point at a workspace and click the pen, **Edit**. Under **MCP servers**, tick the servers for its tasks. Servers for every workspace show as ticked, and you can't change them there. When you take a server out of its last workspace, Zero turns the server off rather than give it to every workspace. See [Workspaces and folders](/docs/workspaces-and-folders).

## Turn a server off, change it or delete it

In **Settings › MCP servers**:

- The switch on a server's row turns the server on or off. When it's on, Zero gives the server to tasks as they start.
- **Edit** opens the server's form. Change the form and click **Save**. To remove the server, click **Delete**.

A running task gets a change the next time it starts.

## Zero's own tools

Agents reach your inbox, your scratchpads and the browser through Zero's own MCP server. This server isn't in the list in **Settings › MCP servers**. To turn it on or off, use **Settings › Agents › Setup › Zero plugin**. When the switch is on, Zero installs its plugin in Claude Code and adds its server to Codex and OpenCode.
