---
title: "The zero command"
description: "How agents reach you: the zero command and the Claude Code plugin."
order: 13
---

`zero` is the command your agents use to reach you. When an agent needs an answer, your go-ahead or a command run on your Mac, it runs `zero`, and the ask shows in Zero's inbox. Agents also use it to say where a task stands, start workers, show you tables and wake themselves up later. You rarely type it yourself.

## How agents learn the command

- **Tasks Zero runs**, in Claude Code, Codex and OpenCode, are told about `zero` when they start: how to ask you things, how to start workers and how to end a turn.
- **Claude Code** also gets the `zero` skill from Zero's Claude Code plugin, with every command and how to use it. See [The Claude Code plugin](#the-claude-code-plugin) below.
- **Any agent** can run `zero help` for the full list.

## Where the command lives

The command is inside Zero's app, at `/Applications/Zero.app/Contents/MacOS/zero-cli`. When Zero updates, it links the command as `~/.local/bin/zero`.

When an agent says `zero: command not found`, either the link is missing or `~/.local/bin` isn't on your shell's path. Agents find commands through your login shell. Add the folder to your path in your shell's profile, such as `~/.zprofile`:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

To make the link yourself:

```sh
mkdir -p ~/.local/bin && ln -sf /Applications/Zero.app/Contents/MacOS/zero-cli ~/.local/bin/zero
```

Two other messages mean Zero isn't running: `zero: Zero.app is not running` and `zero: Zero's daemon isn't running (open Zero)`. Open Zero and try again.

## Ask you something

Each of these puts a card in your inbox. By default, the command waits until you answer, then prints your answer for the agent. With `--async`, it prints the ask's id and returns at once. The answer reaches the agent later as a message.

| Command | Flags | What you see in Zero |
|---|---|---|
| `zero ask "question?"` | `--option`, `--body`, `--title`, `--code`, `--block`, `--about` | A question, or a choice when there are options. Each `--option` adds one option. The first option is the one that the agent recommends. An option that ends in "…" opens a box for your own words. `--body` adds a few sentences of detail under the question. `--code` shows a command or snippet in the card for you to run yourself. |
| `zero approve "what"` | `--body`, `--code`, `--about` | A request for your go-ahead, with **Yes**, **No** and **Suggest something else…**. |
| `zero run 'command'` | `--why`, `--cwd`, `--title`, `--allow`, `--about` | **Allow this command?**, with **Run**, **Reject** and **Suggest something else…**. When you click **Run**, Zero runs the command on your Mac and gives its output back to the agent. `--why` is required: it says what the agent needs the output for. |
| `zero withdraw <id>` | `--reason` | The ask leaves your inbox, because the agent no longer needs it. |

Zero refuses an ask whose question is longer than 140 characters or whose detail is longer than 280, and tells the agent to shorten it. Zero also refuses a question with choices such as "(a) … (b) …" in its text, and tells the agent to use `--option`.

**What an ask is about.** In a task Zero runs, the card shows **About** and a link to the agent's words just before the ask. Click it to go to those words in the conversation. With `--about "#bench-plan"`, the link goes to that heading of the agent's instead, by GitHub's anchor for it. Zero refuses an ask whose heading isn't in the conversation.

**Repeated reads with `--allow`.** When an agent runs the same read-only command on different files, it can pass the start of the command as `--allow`, for example `zero run 'cat logs/today.txt' --allow 'cat'`. The card then also offers **Run, and allow the same for this task**. After you choose it, later commands of that kind from the same task, in the same folder, run without an ask.

### Settings for asks

| Setting | Where | What it does |
|---|---|---|
| Unanswered asks expire after | Settings › Inbox › Answers | How long an ask waits for you before it expires, unless the agent sets its own with `--ttl`. The default is 1 hour. |

Open Settings with <kbd>⌘</kbd> <kbd>,</kbd> or the gear at the foot of the window's left rail.

## Say where a task stands

| Command | Flags | What you see in Zero |
|---|---|---|
| `zero note "where I am"` | `--waiting`, `--needs "what you should do"` | The words show on the task's row in the sidebar. `--waiting` marks the task **Waiting**: on someone other than you. `--needs` marks it **Over to you**: its work is done and a step is left for you. It stays until you write to the task or the agent posts a note without `--needs`. |
| `zero done "what's done"` | `--confirm TOKEN`, `--ask` | Marks the task **Done**. It takes two steps. Zero refuses the first run and gives what done means and a token. The agent then runs the command again with `--confirm` and the token within 5 minutes. With `--ask`, Zero asks you whether the task is done. A worker's `zero done` marks it at once and asks no one: its lead judges it. |
| `zero blocked "what blocks it"` | `--confirm TOKEN` | Marks the task **Blocked**: it can't go on until something outside the agent and you changes, such as an outage or another team's access. A worker is also blocked when it needs a decision only its lead or you can make. It takes two steps, as `zero done` does. Agents that run in a sandbox use the `zero_blocked` tool instead. Until it's confirmed, the task shows **Waiting**. |
| `zero issue TICKET STATE ["text"]` | `--session` | One row for an issue the task leads, under the task in the sidebar. The state is `you`, `over`, `working`, `waiting`, `parked` or `done`. `you` marks the task **Needs you**: the agent needs a decision or something only you can give. `over` marks it **Over to you**: the agent's part is done, and a step is left for you, such as a review or a merge. A `you` or `over` row set before your last message to the task no longer sets the task's state. |

Zero starts a turn for a message from another task, an event or a reminder. The agent ends such a turn with a line that sets the task's state. A worker ends every turn with one, and its lead hears how it ended. When a worker leaves the line out, Zero sends it back once to add it.

| Last line | State in Zero |
|---|---|
| `[zero: done]` | **Done**, once `zero done` has confirmed it. Otherwise **Replied**. |
| `[zero: waiting]` | **Waiting**: the next move is someone else's, such as a review. When the task follows nothing and has nothing running, Zero tells the agent once that nothing will wake it. |
| `[zero: asked <id>]` | **Needs you**, while that ask is open. |
| `[zero: working]` | **Replied**: the agent pauses between steps. |
| `[zero: blocked]` | **Waiting**. Only `zero blocked`, once confirmed, marks the task **Blocked**. |

## Start and lead other tasks

Inside a task, `zero spawn` starts a worker of that task. The worker shows under the task in the sidebar. Zero tells its lead when the worker finishes, fails or gets stuck. Anywhere else, `zero spawn` starts a new task.

Zero puts a finished worker away an hour after its lead has its report. A worker that still follows something, watches or has a wake-up set stays. `zero send` to a worker that was put away brings it back. When **Settings › Agents › Tasks › Archive done tasks** is **Never**, workers stay too.

| Command | Flags | What it does |
|---|---|---|
| `zero spawn "task"` | `--brief FILE`, `--loop NAME`, `--provider codex\|claude\|opencode`, `--model`, `--effort`, `--cwd`, `--label`, `--ticket`, `--permissions auto\|unrestricted`, `--workspace ID` | Starts a worker, or a new task, and prints its id. A worker gets its lead's folder and permissions, unless the flags give others. A new task gets Claude Code, **Auto** permissions and the current folder, unless the flags give others. `--label` names it. |
| `zero send <task> "text"` | | Sends a message to a task, by id or name. Zero resumes an offline task first, and brings an archived one back with its workers. When the sender is another task, the message is marked as that task's and arrives between turns. |
| `zero wait <task>...` | `--any`, `--timeout MINUTES` | Waits until the tasks stop working, then prints how each ended. A task waiting on a command it started in the background is still working. An archived task is found as it was put away. |
| `zero result <task>` | | Prints the task's last answer. |
| `zero workers` | `--session` | Lists the task's workers. |
| `zero adopt <task>` | `--session` | Makes another task, or a Claude Code session, a worker of this one. |
| `zero detach <worker>` | | Lets a worker go: it becomes a task of its own. |
| `zero close <worker>...` | | Archives a worker the lead has read. It leaves the sidebar. |
| `zero migrate <session id>` | `--label`, `--workspace` | Brings a Claude Code, Codex or OpenCode session from outside Zero in as a task, with its history. |
| `zero pause [task...]` | | Pauses the tasks named, or every task, with their workers. Zero asks each working task to finish up and gives it five minutes, then the task stops. They show as **Paused**. |
| `zero unpause [task...]` | | Takes them off hold. Tasks with messages waiting continue. |
| `zero tasks` | | Lists every task: id, state, lead, ticket, Claude Code session, name and folder. |
| `zero workspaces` | | Lists your workspaces: id and name. |
| `zero loops` | | Lists your loops. |
| `zero loop <name>` | | Prints a loop's words. |

## Show you things on a task

| Command | Flags | What you see in Zero |
|---|---|---|
| `zero table "Title"` | `--column NAME`, `--row "a \| b"`, `--session` | A table in the task's conversation. Give `--column` once per column and `--row` once per row. A cell holding a state, such as `working` or `done`, shows as a pill. In a column named for a risk, `low`, `medium` and `high` show as pills too. The table can also come as JSON on standard input: `{"title", "columns", "rows"}`. |
| `zero attr NAME [VALUE]` | `--session` | An attribute in the task's details pane, such as `zero attr PR https://github.com/example/app/pull/12`. A link opens when you click it. Without a value, the command removes the attribute. |
| `zero expect DURATION ["what"]` | `--session` | Says how long the step under way takes, such as `20m` for a full test run, so Zero doesn't take it for stuck. `DURATION` is like `90s`, `20m` or `1h30m`. A command that hangs well past it, with no output and no CPU, Zero may stop, and it tells the agent why. **Settings › Agents › Stuck commands** sets what Zero does. |
| `zero label "name"` | `--ticket`, `--where PLACE`, `--session` | Renames the task. `--ticket` sets its ticket. `--where` sets the **Where** shown for it, such as a machine it runs on. `--where ""` shows its folder again. |

## Hear of changes and wake up later

| Command | Flags | What it does |
|---|---|---|
| `zero follow <url or topic>...` | `--mine`, `--about "word,other words"`, `--session` | The task hears of changes between its turns. It can follow a pull request, for its reviews, comments, checks, pushes and merge, and once merged, its GitHub deployments. It can also follow an issue, one comment thread in an issue, or a Slack thread or channel. In a busy channel, `--mine` passes on only messages that name the pull requests the task follows or their merge commits, and `--about` only those with these words. After a message passes, the next messages from the same author pass too, until the author names something else or half an hour passes. Each service's page in Settings, such as **Settings › GitHub**, shows what tasks follow through it, under **Following**. A task's details pane shows its own, under **Follows**. Zero follows a pull request that a task opens by itself, and makes it the task's **PR** attribute when it has none. |
| `zero unfollow <topic>...` | `--all`, `--session` | Stops following. |
| `zero following` | `--session` | Lists what the task follows, and any trouble reading it. |
| `zero watch -- command...` | `--session` | Runs the command in the background. The task is told how it ended, so it doesn't need to keep checking. |
| `zero watch --file PATH` | `--alert TEXT`, `--until TEXT`, `--quiet MINUTES` | Watches a log as it grows. A line with an `--alert` text is passed on, at most once a minute. `--alert` can be given more than once. `--until` ends the watch when a line has that text. `--quiet` says when the file stops growing. Text can be a pattern between slashes. |
| `zero watch list`, `zero watch stop ID` | | Lists or stops watches. |
| `zero schedule "what for"` | `--at TIME` or `--in DURATION` | Wakes the task at that time with "Scheduled:" and the words. `TIME` is `05:12` on your clock, `05:12Z`, `05:12 UTC` or a full date and time. `DURATION` is like `90m`, `2h`, `1d` or `1h30m`. Schedules stay when Zero restarts. |
| `zero schedule list`, `zero schedule cancel ID` | | Lists or cancels them. |
| `zero remind <minutes> "text"` | `--session` | The same as `zero schedule`, in minutes. |
| `zero notify <task> "text"` | | Gives a task words between its turns, for scripts. |

## Read Slack and Linear

Agents read Slack and Linear through the connections in Settings, so they need no tokens of their own. Zero keeps the tokens and never gives them to the agent. Agents get the service's JSON.

| Command | Flags | What it does |
|---|---|---|
| `zero slack <method> [key=value...]` | `--workspace NAME`, `--approval ID` | Calls a method of Slack's Web API, such as `conversations.history`, `conversations.replies` or `search.messages`. To get the next page, give `cursor=` the `next_cursor` from the last answer. `--workspace` picks a workspace by its name when more than one is connected. If Slack limits the rate, Zero waits as Slack tells it, for up to 30 seconds. |
| `zero linear '<graphql>'` | `--variables JSON`, `--approval ID` | Sends a GraphQL query to Linear. With `-` or no query, it reads the query from standard input. |

Agents can only read. A Slack post or a Linear change is refused unless you turn on **Let agents post** in **Settings › Slack**, or **Let agents make changes** in **Settings › Linear**. When it is on, Zero asks you to approve each post or change, and shows you the call. The agent then runs the same command again with `--approval` and the ask's id. An approval is for that one call. Agents without a shell get the same commands as the `zero_slack` and `zero_linear` tools of Zero's MCP server.

## Later, the browser, videos and scratchpads

| Command | Flags | What it does |
|---|---|---|
| `zero later save "note"` | `--asked`, `--file PATH`, `--link URL`, `--attach FILE` | Saves work to **Later** in the window's left rail. The note is a short headline. The file is the full write-up. `--file -` reads it from standard input. `--link` and `--attach` can each be given more than once. Without `--asked`, the item is a suggestion. It shows under **Suggested by agents**. Each task can have at most 3 open suggestions. A suggestion goes away after a week unless you keep it. |
| `zero later list [words]` | | Lists saved items, or those with these words. |
| `zero later view <id>` | `--version N` | Prints an item in full. |
| `zero later edit <id>` | `--note`, `--file`, `--link`, `--attach` | Changes an item. |
| `zero later done <id>`, `open <id>`, `delete <id>` | | Marks an item done or open again, or deletes it. |
| `zero browser <tool> ['{json}']` | `--session` | Uses your Chrome, through Zero for Chrome, for agents that don't have Zero's browser tools. Screenshots are saved to a file. See [Browsers and MCP servers](/docs/browsers-and-mcp). |
| `zero video <file>` | `--frames N`, `--at T,T…`, `--from T`, `--to T`, `--every S`, `--out DIR` | Turns a video into pictures an agent can look at. Without flags, it takes 12 pictures spread over the video. |
| `zero mcp` | | Runs Zero's MCP server, for adding it to an agent by hand. When Zero's daemon isn't running, it starts it from the Mac's Login Items, or opens Zero in the background. |

## Commands for you in a terminal

Run these yourself to check on Zero.

| Command | Flags | What it does |
|---|---|---|
| `zero list` | `--all` | Lists the open asks: id, state, kind, agent and title. `--all` lists every ask Zero keeps: the open ones, those from the last day, and each agent's latest. |
| `zero status <id>` | | Prints an ask's state and answer. |
| `zero wait <id>` | | Waits for an ask's answer. If Zero restarts while it waits, it keeps waiting for up to 10 minutes. |
| `zero say <agent> "text"` | | Sends your words to an agent, as the inbox's message box does. |
| `zero board` | `--watch` | Prints your tasks as the sidebar shows them, as JSON. `--watch` prints a new line each time something changes. |
| `zero usage` | | Each agent's usage limits, as its CLI last reported them. |
| `zero open-terminal [task]` | | Opens the task in your terminal app, on its agent's own resume. Without a task, the one it runs in. See [Open in Terminal](/docs/tasks-and-workers#continue-in-your-terminal-app). |

## Flags every ask takes

| Flag | What it does | Default |
|---|---|---|
| `--async` | Prints the ask's id and returns at once. | Waits for your answer. |
| `--agent NAME` | The name the ask comes from. | Inside a task, that task. Elsewhere, the `ZERO_AGENT` variable. |
| `--ticket ID` | The ticket the ask is about, shown with it. | None. |
| `--ttl MINUTES` | How long the ask waits before it expires. | **Unanswered asks expire after** in Settings. |

The command exits with `0` when you answered, `2` when you declined and `3` when the ask expired or was withdrawn. For `zero run`, the exit code is the command's own.

## Commands only hooks run

Three commands aren't in `zero help`. Zero's Claude Code plugin runs them, so you never need to:

- `zero permission` turns Claude Code's permission prompt into an ask in your inbox, and sends your answer back. **Always allow** also saves the rule Claude Code suggested. When Claude Code can't reach Zero, or the ask expires, Claude Code asks in its terminal as usual.
- `zero question` turns Claude Code's own multiple-choice questions into asks, with **Something else…** added for your own answer.
- `zero prompt` works out whether you typed a message in the terminal yourself, so the agent answers you there instead of through Zero.

## The Claude Code plugin

Zero's plugin connects Claude Code to Zero. Turn it on in **Settings › Agents › Setup › Zero plugin**. Zero installs it with Claude Code's own plugin commands, so the `claude` command must work in your terminal. Zero updates the plugin when Zero itself updates.

The plugin has three parts.

**Hooks.** They apply to Claude Code that Zero runs. They don't apply to Claude Code in a terminal: one you start yourself, or a task you open there with **Open in Terminal**.

| Hook | What it does |
|---|---|
| Session start | Tells Claude Code that you aren't watching its terminal, and that it reaches you only through `zero`. |
| Permission requests | Sends Claude Code's permission prompts to your inbox, with `zero permission`. |
| Questions | Sends Claude Code's own questions to your inbox, with `zero question`, unless you typed in the terminal this turn. |
| Your messages | Notices when you type in the terminal yourself, with `zero prompt`. |
| End of a turn | Sends the agent back once when it ends a turn without an ending line, or with a question to you left in its text. The agent then asks you properly. |

Tasks that Zero runs in its own window don't need these hooks: Zero handles their permission prompts and questions itself.

**Skills.**

- `zero`: how to reach you, with every command.
- `merge-risk`: grades the risk of merging a pull request as low, medium or high, for a "Merge risk" column in a `zero table`.

**The MCP server.** It gives Claude Code these tools:

- Your scratchpads: read, write, search and organise them.
- Your Chrome, through Zero for Chrome: the browser tools.
- `zero_ask`, `zero_run`, `zero_note`, `zero_issue`, `zero_done` and `zero_blocked`, which do what the commands do, for agents in a sandbox where the `zero` command can't reach Zero.

## What Codex and OpenCode get

The plugin is only for Claude Code. Codex and OpenCode get Zero like this:

- **Tasks Zero runs** get Zero's MCP server and Zero's instructions on using `zero`. The server gives them scratchpads, the browser and the `zero_` tools. They can also run the `zero` command, as any agent can.
- **In your own terminal**, the **Zero plugin** switch also adds Zero's MCP server to Codex's settings in `~/.codex/config.toml` and OpenCode's in `~/.config/opencode/opencode.json`, when those files exist. When you turn the switch off, Zero removes the server again.

## Agents outside Zero

Any agent on your Mac can run `zero`, even one you started in a terminal yourself. Its asks reach your inbox. While it has an open ask, it shows as a coloured dot on the control bar. When the `ZERO_AGENT` variable is set, Zero names the agent by it. Set it to a short, stable name, so all of the agent's asks show under one name. See [The control bar](/docs/control-bar).
