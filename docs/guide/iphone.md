---
title: "The iPhone app"
description: "Your inbox and tasks away from the Mac."
order: 12
---

The iPhone app, coming soon, puts Zero's inbox and tasks on your phone. You answer asks, write to your tasks, start new tasks and save work for later. Your agents keep running on your Mac, so Zero must be open there and the Mac must be online.

## How your phone reaches your Mac

Your phone reaches your Mac through a relay: a server on the internet that passes messages between the two. Zero's own relay works out of the box, with nothing to set up.

To run your own relay, deploy `apps/relay` from Zero's source code. Its README shows how. Then type its address in **Settings › Phone › Relay › Address** on your Mac and press <kbd>Return</kbd>. To go back to Zero's relay, click **Use Zero's**.

Open Settings with <kbd>⌘</kbd> <kbd>,</kbd> or the gear at the foot of the window's left rail. **Status**, in **Settings › Phone › Relay**, shows the state of the connection:

| Status | What it means |
|---|---|
| Not set up | There's no relay address. |
| Off | There's an address, but Zero isn't connected to it. |
| Connecting… | Zero is connecting to the relay. |
| Connected: your phones can reach this Mac | The relay works. |
| Can't reach it: … | Zero couldn't connect. The reason follows. |
| Today's 2 GB through the relay are used: … | Your phones and this Mac passed more through Zero's relay today than it allows. Your phones reach the Mac again after midnight UTC. To have no limit, run your own relay. |
| Zero's relay has closed: … | Zero's relay no longer runs. The message says what to do instead, such as where to run your own. Zero stops connecting to it. |

## Pair your iPhone

You pair once. After that, the phone finds your Mac by itself.

On your Mac:

1. Go to **Settings › Phone › Phones**.
2. Next to **Add a phone**, click **Show code**. A QR code appears.

The code lasts five minutes. When it expires, click **New code**. **Copy link** copies the same code as a link, for a phone that can't scan it.

On your iPhone, open Zero. The **Pair with your Mac** screen points you to **Settings › Phone › Add a phone** on your Mac. Then:

- Tap **Scan the code** and point the camera at the QR code.
- Or copy the link to your phone and tap **Paste a pairing link**. A wrong link shows **That isn't a Zero pairing link.**

After you pair, the phone shows in **Settings › Phone › Phones** on the Mac, with the date you paired it.

## How your messages stay private

Messages between your phone and your Mac are encrypted end to end. The relay passes them on but can't read them. When you pair, the phone gets your Mac's key from the QR code, and the Mac keeps the phone's key. Each side uses these keys to check that it's talking to the other.

Notifications are encrypted too. Apple's push service carries only "Zero: A task has news". When the notification arrives, your phone decrypts the real text.

## When the phone can't reach your Mac

While the phone connects, it shows **Connecting to** and your Mac's name. When it can't connect, it shows **Can't reach**, your Mac's name and when it last connected. It also says that Zero must be open on your Mac and the Mac must be online. The phone keeps trying by itself. To try at once, tap **Try again**.

While the phone isn't connected, a line at the top of the app says **Reconnecting to your Mac** or **Can't reach your Mac**. What the app already loaded stays on screen. To reconnect, pull down on a list.

## Get around the app

The bar at the foot of the screen has three icons and a menu:

- **Inbox**: asks, steps for you and unread replies. A blue dot means something is waiting.
- **Tasks**: all your tasks.
- **Later**: work saved for later.
- **⌃⌄** opens the menu. It shows your workspace's name at the top, then **Inbox**, **Tasks**, **Later**, **Record your screen** and **Settings**. **Inbox** shows the number of things waiting.

When you have more than one workspace, tap the workspace's name in the menu to switch. The phone keeps its own choice of workspace, separate from the Mac's.

The round **+** button beside the bar starts a new task.

## Answer asks in the inbox

The inbox lists what needs you, in this order:

1. Asks from your agents, which you answer in place.
2. Tasks marked **Over to you**: they're done, and a step is left for you.
3. Tasks with a reply you haven't read.

When the inbox is empty, it says **Nothing for you**.

To answer an ask, tap one of its options. An option ending in "…" opens a box for your own words. An ask without options has **Reply…**.

To change your answer, tap **Take back** right after you answer. When an answer doesn't arrive, the card says **Not delivered · Try again**. Tap it to send the answer again.

The inbox has these cards:

| Card | What it asks |
|---|---|
| Question | A question, or a choice between options. |
| Run on your Mac | "Allow this command?": the agent wants a command run on your Mac. Its output goes back to the agent. |
| Run this yourself | A command for you to run. **Copy the command** copies it, and **Paste its output** sends what it printed back. |
| Approval | The agent wants your go-ahead before it does something. |
| Permission | An agent asks to use a tool, such as to run a command or change a file. |

See [The inbox and asks](/docs/inbox-and-asks) for every kind of ask.

## Browse your tasks

**Tasks** lists the tasks in your workspace, in the same order as the Mac's sidebar. Each row shows the agent, the task's state, its name, what it needs or does, and how long ago. A blue dot means a reply you haven't read.

The states are the same as on the Mac: **Needs you**, **In trouble**, **Working**, **Over to you**, **Waiting**, **Replied**, **Done**, **Paused**, **Idle** and **Offline**.

- **Swipe left** for **Archive** and **Pause**. On a paused task, **Pause** is **Resume**.
- **Swipe right** for **Rename**.
- **Touch and hold** for a preview and the menu. The preview shows the task's state, what it does now, what it needs from you and its asks. The menu has **Pause** or **Resume**, **Rename**, **Save for later** and **Archive**.

**Archive** asks you to confirm first. It puts the task away with all its workers. To bring an archived task back, use **Archived tasks** on your Mac.

## Read and write to a task

Tap a task to open its conversation. It shows your messages, the agent's answers, and its work folded under lines such as **Worked for …**. Tap a command to see its output. Scroll up for **Earlier messages**.

### Answer what the task is waiting on

The task's questions, approvals and asks are in its own inbox, not in the conversation. Tap the inbox button at the top right, beside the **…** menu. A blue count on it shows how many are waiting.

The button opens a sheet titled **Waiting on you**, where you answer each ask. An approval from the agent itself reads **Allow this command?** or **Allow this change?**, with the agent's own choices as buttons. When nothing is left, the sheet closes by itself. To close it before that, tap **Done**.

In the conversation, a step with an ask that is still open shows as one line with **Answer**. Tap **Answer** to open the same sheet.

Opening a task marks its reply as read on the phone and on the Mac, and clears its notification.

The **…** menu at the top right has:

- **Details**: the task's **State**, **Workers**, **Where**, **Branch**, **Ticket**, **Agent**, **Model** and **Permissions**, and any **Attributes** its agent set. Tap a link in an attribute to open it.
- **Save for later**: asks the agent to write down what's left, in Later.

Write to the task in the box at the foot, **Write to this task**. When you leave the task, Zero keeps your draft.

| Control | What it does |
|---|---|
| **+** | Adds up to 10 photos. |
| Microphone | Dictates into the box. |
| **Permissions: auto** | Switches between **Auto** and **Unrestricted** for the task. |
| The model, such as **Opus 5.5 High** | Picks the model and effort, from this agent's models, for your next message. |
| Send | Sends. While the task works, it's **Queue for after this turn**. |
| Stop | Shows while the task works and the box is empty. Stops the turn. |

Messages that wait for the end of the turn show above the box under **Queued**. Tap one to edit or delete it, or tap **Steer** to send it now. After you stop the task, these messages show as **Held**. Tap **Send** to send them.

## Start a task

Tap the round **+** button.

1. At the top, tap the folder to pick where the task works. The list has your Mac's project folders. Zero remembers the last one you used.
2. Type the job in **What should it do?**.
3. Tap the agent chip to pick **Claude Code**, **Codex** or **OpenCode** and its model. Claude Code is the default.
4. Tap the permissions chip for **Auto** or **Unrestricted**. **Auto** is the default.
5. Tap **Start**.

The task starts in the workspace your phone shows, and opens.

## Come back to saved work

**Later** holds work that your agents saved for you. **Open** and **Done** at the top switch between what's left and what you finished. Notes an agent saved without you asking show under **Suggested**.

Swipe a note to mark it **Done** or **Not done**. Tap it to read all of it, with its links and the agent's write-up. From there:

- **Send to a task** sends the note to one of your tasks, and that task's agent takes on the work.
- **Done** or **Not done** marks it.
- **Copy** copies it.

To save a task's work, choose **Save for later** from the task's menu.

## Record your screen

To show an agent something on your phone, open the menu and choose **Record your screen**.

- Tap the red button to start a screen recording. To speak while you record, turn on the microphone in the system's sheet. To stop, tap the same button or the red pill at the top of the screen.
- Or pick what you already have: up to 10 **Photos**, or **Recordings**.

Then add a line in **What should it look at?**, choose the task under **Send to**, and tap **Send**. The agent gets the recording as pictures, each with its time, and the words you said.

## Check the phone's settings

Open the menu and choose **Settings**.

| Row | Group | What it shows |
|---|---|---|
| Connection | Your Mac | **Connected**, **Connecting…**, **Can't reach it** or **Not paired**. **Reconnect** shows when the phone isn't connected. |
| Notifications | Permissions | Whether Zero can send notifications. |
| Microphone, Speech | Permissions | Whether Zero can use them, for dictation and recordings. |
| Open iOS Settings | Permissions | Opens Zero's page in the iPhone's Settings app, to change these. |
| Version | About | The app's version. |
| Unpair this phone | About | Unpairs the phone. |

## Get notifications on your phone

The first time you open **Tasks**, Zero asks to send notifications.

Your phone gets a notification when a task has news and you're away from your Mac. Zero counts you as away when one of these is true:

- Zero isn't in front on the Mac with its window open.
- The Mac's screen is locked or asleep.
- You haven't touched the keyboard or mouse for two minutes.
- You used the phone more recently than the Mac.

How notifications behave:

- Each task has one notification at a time. News replaces the old one.
- After you see the news on the Mac or the phone, the notification goes away on both.
- Tap an ask's notification to open the inbox. Tap a task's notification to open the task.
- Press and hold a task's notification for **Reply**. Type in **Reply to this task** and tap **Send**. While the task works, your reply waits until its turn ends.
- While you're in the app, notifications play their sound but don't show a banner.

## Send pictures and videos from other apps

Zero is in the iPhone's share sheet twice: as **Zero** among the apps, and as **Ask Zero** among the actions. Both do the same thing.

1. In Photos or another app, select up to 10 pictures or one video and tap **Share**.
2. Choose **Zero** or **Ask Zero**.
3. Write the agent's job in **What should it look at?**. When the box is empty, Zero sends "Have a look at this." For several pictures, it sends "Have a look at these."
4. Pick a task under **Send to a task**, or a folder under **Or start one in** to start a new Claude Code task there.
5. Tap **Send**.

A video goes as pictures taken from it. When the phone can't reach Zero on your Mac, it shows **Can't reach your Mac: Zero needs to be running there.**

## Use Siri and Shortcuts

Each action works through Siri and in the Shortcuts app. In the phrases below, Login fix stands for your task's name.

| Action | Say | What happens |
|---|---|---|
| What needs me | "What needs me in Zero", "What's waiting for me in Zero" or "Anything need me in Zero" | Siri reads out the tasks and asks that wait for you, or "Nothing needs you right now." |
| Check a task | "How is Login fix doing in Zero", "What's Login fix doing in Zero" or "Check on Login fix in Zero" | Siri says the task's state and what it does now. |
| Open a task | "Open Login fix in Zero" | Opens the task. |
| Save for later | "Save Login fix for later in Zero" | Asks the task's agent to save its work to Later. |
| Pause agents | "Pause my agents in Zero" or "Pause Zero" | After you confirm, every task and its workers finish their current step and stop. |
| Resume agents | "Resume my agents in Zero" or "Unpause Zero" | Takes your tasks off hold. Tasks with messages waiting continue. |

Ask Siri to send a message to a task by its name, or reply to a task's notification with Siri. Siri answers "Sent to" and the task's name.

When the phone can't reach Zero on your Mac, Siri says **Zero can't reach your Mac. Zero needs to be open there.**

## Unpair your iPhone

On the phone, open the menu, choose **Settings**, tap **Unpair this phone**, then **Unpair**. To unpair from the connecting screen, tap **Paired with** and your Mac's name at the foot, then **Unpair this phone**.

After that, the phone can't reach your Mac until you pair it again. Unpairing on the phone leaves it in the Mac's list.

To cut a phone off from the Mac's side, for example after you lose it, go to **Settings › Phone › Phones** on the Mac and click **Remove** next to the phone.
