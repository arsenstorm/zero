// The home page's demo: the recreated app works as Zero does. Asks answer with a click or 1 to 3, orange while Esc can
// take the answer back, then green; an ask shown in several places is one ask, answered everywhere at once. Answering
// sets its task working, in the window's sidebar and on the control bar. The window opens a task's conversation from
// the sidebar and takes messages; the control bar's marks open their task in the inbox beside it.
import checkIcon from "../../../apps/macos/Resources/nucleo/check-outline.svg?raw";

// Shorter than the app's 2 s default (Settings › Composer and inbox), so the demo doesn't keep you waiting.
const TAKE_BACK_MS = 1000;
const spinner = (size: number) =>
  `<svg width="${size}" height="${size}" viewBox="0 0 12 12" aria-hidden="true" class="spinner"><circle cx="6" cy="6" r="4" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" pathLength="100" stroke-dasharray="85 100" /></svg>`;
const check = checkIcon.replace('width="18" height="18"', 'width="13" height="13"').replace("<svg ", '<svg aria-hidden="true" ');

// Asks

type Ask = { headline: string; cards: HTMLElement[]; timer?: number; answer?: { index: number; text: string } };
const asks = new Map<string, Ask>();
let selected: Ask | undefined;

for (const card of document.querySelectorAll<HTMLElement>("[data-ask]")) {
  const headline = card.dataset.headline!;
  const ask = asks.get(headline) ?? { headline, cards: [] };
  ask.cards.push(card);
  asks.set(headline, ask);
  // As in the inbox, the card under the pointer (or holding the keyboard) is the one the keys answer.
  card.addEventListener("pointerenter", () => (selected = ask));
  card.addEventListener("focusin", () => (selected = ask));
  for (const button of card.querySelectorAll<HTMLButtonElement>("[data-option]")) {
    button.addEventListener("click", () => choose(ask, Number(button.dataset.option), card));
  }
  for (const form of card.querySelectorAll<HTMLFormElement>("form[data-reply]")) {
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      const text = form.querySelector("input")!.value.trim();
      if (text) pick(ask, Number(form.dataset.reply), text);
    });
  }
}

function option(card: HTMLElement, index: number) {
  return card.querySelector<HTMLButtonElement>(`[data-option="${index}"]`)!;
}

/** An answer picked: one ending in "…" opens its box first, in the card it was picked in. */
function choose(ask: Ask, index: number, card = ask.cards[0]) {
  if (ask.answer) return;
  const button = option(card, index);
  if (!button) return;
  if (button.dataset.typed === undefined) return pick(ask, index, button.dataset.label!);
  const form = card.querySelector<HTMLFormElement>(`form[data-reply="${index}"]`)!;
  button.hidden = true;
  form.hidden = false;
  form.querySelector("input")!.focus();
}

function pick(ask: Ask, index: number, text: string) {
  ask.answer = { index, text };
  render(ask, "pending");
  ask.timer = window.setTimeout(() => deliver(ask), TAKE_BACK_MS);
}

function takeBack(ask: Ask) {
  if (!ask.answer || ask.timer === undefined) return false;
  clearTimeout(ask.timer);
  ask.timer = undefined;
  ask.answer = undefined;
  render(ask, "waiting");
  return true;
}

function deliver(ask: Ask) {
  ask.timer = undefined;
  render(ask, "done");
  // Answered, a docked ask leaves the task's conversation, as the app's does; the answer shows there instead.
  for (const card of ask.cards) card.closest<HTMLElement>("[data-docked]")?.setAttribute("hidden", "");
  const task = ask.cards[0].dataset.task;
  if (task) setWorking(task);
  document.dispatchEvent(new CustomEvent("zero:answered", { detail: { headline: ask.headline, ...ask.answer } }));
}

// An ask asked again (the inbox section's pile, which never runs out): unanswered everywhere it shows.
document.addEventListener("zero:reask", (event) => {
  const ask = asks.get((event as CustomEvent).detail.headline);
  if (!ask) return;
  clearTimeout(ask.timer);
  ask.timer = undefined;
  ask.answer = undefined;
  render(ask, "waiting");
});

/** Every copy of the ask shows the same state: the chosen row orange then green, the others faded. */
function render(ask: Ask, state: "waiting" | "pending" | "done") {
  for (const card of ask.cards) {
    card.toggleAttribute("data-decided", state !== "waiting");
    for (const button of card.querySelectorAll<HTMLButtonElement>("[data-option]")) {
      const chosen = state !== "waiting" && Number(button.dataset.option) === ask.answer!.index;
      button.dataset.state = chosen ? state : "";
      button.disabled = state !== "waiting";
      button.hidden = false;
      button.querySelector("[data-text]")!.textContent = chosen ? ask.answer!.text : button.dataset.label!;
      button.querySelector("[data-mark]")!.innerHTML = chosen ? (state === "pending" ? spinner(12) : check) : "";
    }
    for (const form of card.querySelectorAll<HTMLFormElement>("form[data-reply]")) {
      form.hidden = true;
      form.reset();
    }
  }
}

document.addEventListener("keydown", (event) => {
  // Not while you type, and never for the search box in the header.
  if (event.metaKey || event.ctrlKey || event.altKey || (event.target as HTMLElement).closest("[data-search]")) return;
  const typing = (event.target as HTMLElement).closest("input, textarea");
  if (event.key === "Escape") {
    // Esc takes back the last answer, wherever it was given, as the inbox's Esc does.
    for (const ask of asks.values()) if (takeBack(ask)) return event.preventDefault();
    return;
  }
  if (typing || !selected || !/^[1-3]$/.test(event.key)) return;
  event.preventDefault();
  choose(selected, Number(event.key) - 1);
});

// Task states: answering a task's ask sets it working everywhere it shows.

function setWorking(task: string) {
  for (const icon of document.querySelectorAll<HTMLElement>(`[data-task-state="${task}"]`)) {
    icon.innerHTML = spinner(12);
    icon.className = "size-3.5 shrink-0 grid place-items-center text-blue";
    icon.title = "Working";
  }
}

// The window

const win = document.querySelector<HTMLElement>("[data-window]");
if (win) {
  const composer = win.querySelector<HTMLFormElement>("[data-composer]")!;
  const input = composer.querySelector("input")!;
  let open = win.querySelector<HTMLElement>("[data-conversation]:not([hidden])")!.dataset.conversation!;

  const conversation = (id: string) => win.querySelector<HTMLElement>(`[data-conversation="${id}"]`)!;
  const placeholder = (id: string) => (conversation(id).dataset.state === "working" ? "Steer it while it works" : "Reply");

  const stop = composer.querySelector<HTMLButtonElement>("[data-stop]")!;
  const send = composer.querySelector<HTMLButtonElement>("[data-send]")!;
  function buttons() {
    const working = conversation(open).dataset.state === "working";
    stop.hidden = !working;
    send.hidden = working;
    send.toggleAttribute("data-ready", input.value.trim() !== "");
  }
  input.addEventListener("input", buttons);
  stop.addEventListener("click", () => {
    conversation(open).dataset.state = "stopped";
    append(open, `<div class="flex items-center gap-[7px] text-[12.5px] text-muted"><span>Stopped</span></div>`);
    input.placeholder = placeholder(open);
    buttons();
  });

  function show(id: string) {
    open = id;
    for (const c of win!.querySelectorAll<HTMLElement>("[data-conversation]")) c.hidden = c.dataset.conversation !== id;
    for (const row of win!.querySelectorAll<HTMLElement>("[data-open-task]")) row.setAttribute("aria-pressed", String(row.dataset.openTask === id));
    input.placeholder = placeholder(id);
    win!.querySelector<HTMLElement>("[data-title]:not([data-conversation])")!.textContent = conversation(id).dataset.title!;
    buttons();
    toEnd(id);
  }
  // A conversation sits at its end, as the app keeps it, with its latest words above the composer.
  const toEnd = (id: string) => {
    const items = conversation(id).querySelector<HTMLElement>("[data-items]")!;
    items.scrollTop = items.scrollHeight;
  };

  function append(id: string, html: string) {
    const items = conversation(id).querySelector<HTMLElement>("[data-items]")!;
    items.insertAdjacentHTML("beforeend", html);
    items.scrollTop = items.scrollHeight;
  }
  const escape = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);
  const bubble = (text: string) => `<div class="self-end max-w-[78%] rounded-[18px] bg-knob text-on-knob px-3.5 py-3 text-pretty">${escape(text)}</div>`;
  const step = (text: string) =>
    `<div class="flex items-center gap-[7px] text-[12.5px] text-muted"><span class="text-blue">${spinner(11)}</span><span class="truncate">${escape(text)}</span></div>`;

  for (const row of win.querySelectorAll<HTMLElement>("[data-open-task]")) row.addEventListener("click", () => show(row.dataset.openTask!));
  // "Worked for …" opens to the steps it folds, and closes again.
  for (const group of win.querySelectorAll<HTMLElement>("[data-worked]")) {
    const toggle = group.querySelector("button")!;
    toggle.addEventListener("click", () => {
      const open = toggle.getAttribute("aria-expanded") !== "true";
      toggle.setAttribute("aria-expanded", String(open));
      group.querySelector<HTMLElement>("div[hidden], div:not([data-worked])")!.hidden = !open;
    });
  }
  input.placeholder = placeholder(open);
  buttons();
  toEnd(open);

  composer.addEventListener("submit", (event) => {
    event.preventDefault();
    const text = input.value.trim();
    if (!text) return;
    append(open, bubble(text));
    append(open, step(conversation(open).dataset.state === "working" ? "Queued: the agent reads your message between steps" : "Working on it"));
    input.value = "";
    conversation(open).dataset.state = "working";
    input.placeholder = placeholder(open);
    buttons();
    setWorking(open);
  });

  // An answer reaches the task that asked, in its conversation.
  document.addEventListener("zero:answered", (event) => {
    const { headline, text } = (event as CustomEvent<{ headline: string; text: string }>).detail;
    const card = asks.get(headline)?.cards[0];
    const task = card?.dataset.task;
    if (!task || !win.querySelector(`[data-conversation="${task}"]`)) return;
    append(task, bubble(text));
    append(task, step(headline === "Open a pull request with the fix?" && text === "Yes" ? "Opening a pull request" : "Carrying on"));
  });
}

// The control bar

for (const bar of document.querySelectorAll<HTMLElement>("[data-bar]")) {
  const controls = [...bar.querySelectorAll<HTMLButtonElement>("[data-peek-open]")];
  // Pointing at a control pins it, as a click does in the app: its view in the inbox beside the bar and, for a task's
  // mark, the mark grown, until you point at another. No clicks needed, and none do anything more.
  function pin(control: HTMLButtonElement) {
    const id = control.dataset.peekOpen!;
    for (const peek of bar.querySelectorAll<HTMLElement>("[data-peek]")) peek.hidden = peek.dataset.peek !== id;
    for (const c of controls) {
      const pinned = c === control;
      c.setAttribute("aria-pressed", String(pinned));
      c.toggleAttribute("data-shown", pinned && c.hasAttribute("data-task-mark"));
    }
  }
  for (const control of controls) {
    control.addEventListener("pointerenter", () => pin(control));
    control.addEventListener("focus", () => pin(control));
  }
  pin(controls[0]);
}
