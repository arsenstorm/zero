// Each task's tabs: a tab group of its own, in a window its team shares, and any tab the user gave it from the popup.
// A tool may act only on those. Which group and window each task has is kept for the browser's session.


// Kept in local storage, so a reload of the extension remembers them; a group is trusted only if it still has its
// task's title (Chrome reuses ids after it restarts).
async function kept() {
  const { groups = {}, windows = {}, titles = {} } = await chrome.storage.local.get(["groups", "windows", "titles"]);
  const { shared = {} } = await chrome.storage.session.get("shared");
  return { groups, windows, titles, shared };
}

/** A task's group title: Zero, with the work's reference when it has one ("Zero: ENG-9686"). */
const title = (task) => {
  const ticket = String(task.ticket || "").trim();
  if (!ticket) return "Zero";
  const named = `Zero: ${ticket}`;
  return named.length > 26 ? named.slice(0, 25) + "…" : named;
};

// The task's state, first in its group's title: working, blocked (it needs the user), done.
const LIGHTS = { working: "🚧", blocked: "⛔", done: "✅" };
// Earlier lights too, so groups named with them are still known as their task's.
const bare = (shown = "") => shown.replace(/^(🚧|⛔|✅|🟡|🔴|🟢)\s*/u, "");
const lit = (name, light) => (LIGHTS[light] ? `${LIGHTS[light]} ` : "") + name;

/** The task's groups that still exist as its (one per window it has tabs in), the newest first. */
async function groupsOf(task, state) {
  const ids = [].concat(state.groups[task.group] ?? []);
  const found = [];
  for (const id of ids) {
    const group = await exists((i) => chrome.tabGroups.get(i), id);
    if (group && bare(group.title) === state.titles[task.group]) found.push(group);
  }
  return found.reverse();
}

/** The task's newest group, if it has one. */
async function groupOf(task, state) { return (await groupsOf(task, state))[0] || null }

/** A task's light, as zerod says it; a tab with an alert open makes its group red until it's answered. */
const lights = new Map();
const alerting = new Set(); // tabs with a dialog open

export async function setLight(key, light) {
  if (light) lights.set(key, light);
  const state = await kept();
  for (const group of await groupsOf({ group: key }, state)) {
    const tabs = await chrome.tabs.query({ groupId: group.id });
    const shown = tabs.some((t) => alerting.has(t.id)) ? "blocked" : lights.get(key);
    const wanted = lit(state.titles[key], shown);
    if (group.title !== wanted || group.color !== "grey") await chrome.tabGroups.update(group.id, { title: wanted, color: "grey" }).catch(() => {});
  }
}

/** A dialog opened or closed in a tab: its group's light follows. */
export async function alerted(tabId, open) {
  if (open) alerting.add(tabId); else alerting.delete(tabId);
  const key = await sessionOf(tabId);
  if (key) await setLight(key, null);
}


async function exists(get, id) {
  if (id == null) return null;
  try { return await get(id) } catch { return null }
}

/** The task's tabs: its group's, then those the user gave it. */
export async function tabsOf(task) {
  const state = await kept();
  const { shared } = state;
  const own = [];
  for (const group of (await groupsOf(task, state)).reverse()) own.push(...await chrome.tabs.query({ groupId: group.id }));
  const given = [];
  for (const [id, session] of Object.entries(shared)) {
    if (session !== (task.session || "zero")) continue;
    const tab = await exists((i) => chrome.tabs.get(i), Number(id));
    if (tab) given.push({ ...tab, given: true });
  }
  return [...own, ...given];
}

/** A tab of the task's, or why not. */
export async function own(task, tabId) {
  if (typeof tabId !== "number") throw new Error("Which tab? browser_tabs lists this task's tabs");
  const tab = (await tabsOf(task)).find((t) => t.id === tabId);
  if (!tab) throw new Error(`Tab ${tabId} isn't this task's: browser_tabs lists its tabs`);
  return tab;
}

/** A new tab for the task, in the background so the user's view stays theirs: beside the task's other tabs; else in
 * a window its team asked for; else in the user's Chrome window, the one they used last. `window` asks for a window of
 * the team's own ("own", made behind the user's) or a private one ("incognito"), from now on. */
export async function newTab(task, url = "about:blank", window = "") {
  const state = await kept();
  const groups = await groupsOf(task, state);
  const teams = await exists((id) => chrome.windows.get(id), state.windows[task.window]);
  // Its newest group's window, unless the team asked for one of its own since.
  const group = groups.find((g) => !teams || g.windowId === teams.id) || null;
  let windowId;
  if (window === "own" || window === "incognito") {
    if (window === "incognito" && !(await chrome.extension.isAllowedIncognitoAccess())) {
      throw new Error("Zero for Chrome isn't allowed in Incognito: the user can turn on Allow in Incognito on its card in Chrome's Extensions page");
    }
    const made = await chrome.windows.create({ url: "about:blank", focused: false, incognito: window === "incognito", width: 1280, height: 900 });
    windowId = made.id;
    state.windows[task.window] = windowId;
    // The window's own first tab is the task's.
    const tab = made.tabs?.[0] || (await chrome.tabs.query({ windowId }))[0];
    if (url !== "about:blank") await chrome.tabs.update(tab.id, { url });
    return grouped(task, state, tab, null);
  }
  if (group) windowId = group.windowId;
  else if (teams) windowId = teams.id;
  else windowId = (await chrome.windows.getLastFocused({ windowTypes: ["normal"] }).catch(() => null))?.id;
  const tab = windowId == null ? (await chrome.windows.create({ url, focused: false })).tabs[0] : await chrome.tabs.create({ windowId, url, active: false });
  return grouped(task, state, tab, group);
}

/** The tab put in the task's group (made, named and lit, if it has none in that window). */
async function grouped(task, state, tab, group) {
  if (group && group.windowId === tab.windowId) {
    await chrome.tabs.group({ groupId: group.id, tabIds: [tab.id] });
  } else {
    const groupId = await chrome.tabs.group({ tabIds: [tab.id], createProperties: { windowId: tab.windowId } });
    if (task.state) lights.set(task.group, task.state);
    // Named as the task's other groups are, so they're all known as its.
    state.titles[task.group] ??= title(task);
    // Grey: Chrome's neutral colour, white on grey in a dark window. The light says the rest.
    await chrome.tabGroups.update(groupId, { title: lit(state.titles[task.group], lights.get(task.group)), color: "grey" });
    state.groups[task.group] = [].concat(state.groups[task.group] ?? []).slice(-8).concat(groupId);
  }
  await chrome.storage.local.set({ groups: state.groups, windows: state.windows, titles: state.titles });
  return tab;
}

/** The task's first tab, opened if it has none. */
export async function firstTab(task) {
  return (await tabsOf(task))[0] || newTab(task);
}

/** Gives the user's tab to a task (session), or takes it back (null). */
export async function share(tabId, session) {
  const { shared } = await kept();
  if (session) shared[tabId] = session; else delete shared[tabId];
  await chrome.storage.session.set({ shared });
}

export async function sharedWith(tabId) { return (await kept()).shared[tabId] || null }

/** The session driving a tab, for the page's Stop button: its group's, or the one it was given to. */
export async function sessionOf(tabId) {
  const { groups, shared } = await kept();
  if (shared[tabId]) return shared[tabId];
  const tab = await exists((i) => chrome.tabs.get(i), tabId);
  if (!tab || tab.groupId < 0) return null;
  return Object.entries(groups).find(([, ids]) => [].concat(ids).includes(tab.groupId))?.[0] ?? null;
}

/** Whether the user blocked this URL's site: "bank.com" and "*.bank.com" both cover bank.com and its subdomains. */
export function blocked(url, patterns = []) {
  let host;
  try { host = new URL(url).hostname.toLowerCase() } catch { return false }
  return patterns.some((pattern) => {
    const site = String(pattern).toLowerCase().trim().replace(/^\*\./, "").replace(/^https?:\/\//, "").replace(/\/.*$/, "");
    return site && (host === site || host.endsWith("." + site));
  });
}

chrome.tabs.onRemoved.addListener((tabId) => share(tabId, null));
