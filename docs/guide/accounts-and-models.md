---
title: "Accounts and models"
description: "Sign in Claude Code, Codex and OpenCode, and pick the model for a task."
order: 5
---

Zero keeps accounts for Claude Code, Codex and OpenCode. Each time a task starts, Zero gives one account to the agent. The agents talk to their providers themselves; Zero never does. Your keys and tokens stay in your Keychain.

Accounts in Zero are optional. When Zero has no account for an agent, the agent's tasks use the sign-in that the agent already has, the one it uses in Terminal. After you add an account for an agent, its tasks use Zero's accounts.

## Open the Accounts page

Open **Settings › Accounts and models**. To open Settings, press <kbd>⌘</kbd> <kbd>,</kbd> or click the gear at the foot of the window's left rail.

The page has a section for each agent: **Claude Code**, **Codex** and **OpenCode**. Each section lists its accounts. A section with no accounts shows **None yet**. **Add model** and **Add account** are beside the agent's name.

## Add an account

Click **Add account** beside the agent's name and choose how to sign in:

| Agent | Choice | What happens |
|---|---|---|
| Claude Code | **Sign in with Claude** | Claude's sign-in page opens in your browser. Sign in there. If the page shows a code, paste it into **Its code, if Claude shows one** and click **Send**. The account's tasks get a token that lasts a year. Zero keeps it in your Keychain. |
| Claude Code | **Anthropic API key** | Type **A name for it** and **Its API key**, then click **Save**. You pay for each use. |
| Codex | **Sign in with ChatGPT** | ChatGPT's sign-in page opens in your browser. Until you finish the sign-in, the account shows on the page with **Signing in… finish in your browser**. |
| Codex | **OpenAI API key** | Type a name and the key, then click **Save**. You pay for each use. Codex keeps the key in a separate folder for this account. |
| OpenCode | **OpenCode Go key**, **Anthropic key**, **OpenAI key** or **OpenRouter key** | Type a name and the key, then click **Save**. Zero gives the key to OpenCode in the variable of that provider, such as `OPENCODE_API_KEY`. |

- If Claude doesn't say whose account it is, the new row asks **Whose account is this? (its email, or a name)**. Type one and press <kbd>Return</kbd>.
- A ChatGPT sign-in goes away when you refuse it, or when you don't finish it within 15 minutes. To try again, add it again.
- If a Claude sign-in fails, the dialog says why and shows **Try again**.

Under each account's name, its row says what it is:

- Its plan, as the agent reports it: a Claude plan, or ChatGPT and its plan.
- **Subscription**, when Claude doesn't say which plan.
- **API key**. For OpenCode, the name of the key's variable comes after it.

## Rename or remove an account

Click **⋯** at the end of the account's row to open its menu:

- **Rename**: type a new name and press <kbd>Return</kbd>. <kbd>Esc</kbd> cancels.
- **Switch to a token**: shows for a Claude account whose row says **its own folder: your MCP sign-ins aren't shared**. It opens Claude's sign-in again. With the token it gets, the account shares your MCP sign-ins.
- **Remove…**: the row asks again. Click **Remove** to confirm, or **Cancel**. The tasks of a removed account can't restart with it. To get the account back, sign in again.

## See how much usage is left

Click an account's row to open it in place. It shows a tile for each allowance its plan has:

- **Last 5 hours**: how much of the five-hour allowance is used.
- **This week**: how much of the weekly allowance is used.

Each tile shows the share used, a bar and when the allowance resets. The bar turns orange at 90% and red at 100%. An account at a limit shows **At its limit** on its row. Click the row again to close it.

Under the tiles, **Activity** has a square for each day, darker the more turns the account's tasks finished that day. The count starts on the day Zero began to keep it.

While the page is open, Zero asks each agent for its accounts' usage every two minutes. API keys have no allowance, so they show no tiles.

The foot of the tasks sidebar also shows the accounts your tasks used in the last day, with a **5h** and a **Week** bar each. Point at a bar to see when it resets. Click the card to open **Settings › Accounts and models**.

## Which account a task uses

You don't pick a task's account. Zero picks one when the task starts:

- A worker of the same agent uses the same account as the task that started it.
- For other tasks, Zero leaves out accounts that are at a limit, and accounts that can't use the task's model. From the rest, it picks the account with the least weekly allowance left. So Zero uses up one account before it goes to the next, and the other accounts keep their allowance. When two accounts are equal, the one that resets sooner goes first.
- When every account is at a limit, Zero uses the first account in the agent's list.

## When a task changes account

A task keeps its account until one of these happens:

- **The account reaches a usage limit.** The task continues on another account of the same agent, with its conversation. Zero tells the agent, and the agent continues from where it stopped.
- **The account can't use the task's model.** Zero records that the account can't use that model, and the task continues on an account that can. Zero doesn't pick that account for that model again.

When no other account can take over, the task stops. For a usage limit, the task shows **Usage limit** at the end of the conversation, with the time when the limit resets. After the reset, the task continues by itself. To continue sooner, click **Continue with Codex** or **Continue with Claude Code** there. The other agent then takes over the task and its whole conversation.

When an account's key is missing from your Keychain, the task doesn't start. It shows "isn't in the Keychain any more: sign in again". Remove the account and add it again.

## Pick a model and effort for a new task

To open the **New task** page, click **Home**, the house at the top of the window's left rail. On the right of the row under the box, a chip shows the agent's icon, the model and the effort, such as "Opus 5.5 · High". A model the list doesn't have shows by a readable name, such as "Opus 5.5" for `claude-opus-5-5`.

1. Click the chip. It has a tab for each agent: **Claude Code**, **Codex** and **OpenCode**. To switch agent, click a tab or press <kbd>←</kbd> and <kbd>→</kbd>.
2. Point at a model, or move to it with <kbd>↑</kbd> and <kbd>↓</kbd>. The pane beside the list describes the model. For models that have levels, the pane also shows an **Effort** slider.
3. Click the model, or press <kbd>Return</kbd>. Or move the **Effort** slider. The slider picks the model at that level and keeps the list open. <kbd>Esc</kbd> closes the list.

When you pick no model, the task uses the agent's first model. OpenCode uses the default from its own configuration. The effort levels are different for each model. On the chip, Zero shows **Extra High** as "XHigh".

Zero remembers the agent you picked last and uses it for the next new task.

## Change the model during a task

In a task, the same chip is in the composer, at the foot of the conversation.

- **Between turns**, the model and effort you pick apply from your next message.
- **While the agent works**, your choice waits for the next turn. The chip shows a mark. When you point at it, it shows **From the next turn**.

The list also shows the models of the other agents. When you pick one, the task moves to that agent with its whole conversation. Claude Code and Codex can take over a task. OpenCode can't.

## Add a model the list doesn't show

Sometimes a new model is available before an agent lists it. To add it to Zero:

1. Open **Settings › Accounts and models**.
2. Click **Add model** beside the agent's name.
3. In **Add a Claude Code model**, or the Codex or OpenCode form, type the model's id in the form that the agent accepts. For example, `claude-mythos-5-2`, `gpt-5.5-codex`, or `provider/model` for OpenCode.
4. Optionally, type a name for the list, such as "Mythos 5.2". Without one, the list shows the id.
5. Click **Add**.

The model shows under the agent's accounts and in every model list for that agent. All of the agent's accounts offer it.

When an account turns out not to have the model, its tasks on that model run on your other accounts. The model's row then says **Not on** and that account. When none of your accounts can use the model, the row says **None of your accounts can use it**. To take a model out, click **Remove**.

## Where the lists come from

- **Claude Code**: first **Fable**, **Opus**, **Sonnet** and **Haiku**. Each follows the latest model of its family. Once a task has run one, the row shows that version's name, such as "Opus 5.5". Then come the models that Claude Code has offered your account, such as the 1M-context versions, and the models you added. Zero reads these from Claude Code's own files and never calls Anthropic.
- Under them, each version your tasks ran or you typed, newest first. Such a row stays on that version, even when a newer one comes out.
- **Other model…**, at the end of Claude Code's list, takes any Claude model by its full id. Click it, type the id, such as `claude-opus-5`, and press <kbd>Return</kbd>. The model stays in the list from then on.
- **Codex**: the models that Codex offers your account, as Codex lists them, plus the models you added.
- **OpenCode**: its own list, which Zero reads when you open the chip. The rows fill in after Zero reads the list.
