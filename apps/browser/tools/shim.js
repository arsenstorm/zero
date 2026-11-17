// Zero Browser's tools page: Zero's browser tools for agents (the extension's own, apps/chrome, bundled after this),
// on a chrome.* of Zero Browser's making. It runs in a hidden page of Zero Browser that loads nothing else; the one
// way out is `zeroBridge`, a DevTools binding on this page alone, to the browser app, which answers through
// `__zeroReply` and tells of zerod's lines, debugger events and closed tabs through `__zeroIn`.
// Tabs are the browser app's (each its own off-screen page); groups, windows and storage are kept here.
(() => {
  // about:blank may not count as a secure context, where crypto.randomUUID is missing; the extension names itself with one.
  if (!crypto.randomUUID)
    crypto.randomUUID = () =>
      "10000000-1000-4000-8000-100000000000".replace(/[018]/g, (c) =>
        (
          c ^
          (crypto.getRandomValues(new Uint8Array(1))[0] & (15 >> (c / 4)))
        ).toString(16)
      );
  const waiting = new Map();
  let asked = 0;
  /** One request to the browser app. */
  const bridge = (op, fields = {}) =>
    new Promise((done, fail) => {
      const id = ++asked;
      waiting.set(id, { done, fail });
      globalThis.zeroBridge(JSON.stringify({ id, op, ...fields }));
    });
  globalThis.__zeroReply = (id, ok, value) => {
    const w = waiting.get(id);
    waiting.delete(id);
    if (!w) return;
    if (ok) w.done(value);
    else
      w.fail(
        new Error(
          typeof value === "string"
            ? value
            : value?.message || JSON.stringify(value)
        )
      );
  };

  const listeners = () => {
    const list = [];
    return {
      addListener: (f) => list.push(f),
      removeListener: (f) => list.splice(list.indexOf(f) >>> 0, 1),
      list,
    };
  };
  const onRemoved = listeners();
  const onMessage = listeners(); // content scripts' messages, from their tabs
  const offscreenMessages = listeners(); // the recorder's (offscreen.js, run in this page too)
  const onEvent = listeners();
  const onDetach = listeners();
  const onAlarm = listeners();
  const fire = (event, ...args) =>
    event.list.forEach((f) => {
      try {
        f(...args);
      } catch (e) {
        console.error(e);
      }
    });

  // Groups: which task's each tab is. The extension keeps its own map of task → groups in storage (tabs.js); a tab's
  // task is told to the browser app, which shows the tab in that task's side panel in Zero.
  const WINDOW = 1;
  const groups = new Map(); // id → { id, title, color, windowId }
  const groupOf = new Map(); // tab → group id
  let nextGroup = 1;
  const owners = new Map(); // tab → session told
  const store = {};
  // Kept across Zero Browser's restarts, as Chrome keeps an extension's storage and its tab groups: Zero.app reopens an
  // agent's tabs with their numbers, and they're still the agent's task's.
  try {
    const saved = JSON.parse(globalThis.__zeroSaved || "null");
    if (saved) {
      Object.assign(store, saved.store);
      for (const g of saved.groups || []) groups.set(g.id, g);
      for (const [tab, g] of saved.groupOf || []) groupOf.set(tab, g);
      nextGroup = saved.nextGroup || nextGroup;
    }
  } catch (e) {
    console.error(e);
  }
  let saving = null;
  const save = () => {
    saving ??= setTimeout(() => {
      saving = null;
      const state = {
        store,
        groups: [...groups.values()],
        groupOf: [...groupOf],
        nextGroup,
      };
      bridge("save", { state: JSON.stringify(state) }).catch(() => {});
    }, 200);
  };
  function tellOwners() {
    const byGroup = new Map();
    for (const [key, list] of Object.entries(store.groups || {}))
      for (const g of [].concat(list)) byGroup.set(g, key);
    for (const [tab, group] of groupOf) {
      const session = byGroup.get(group);
      if (session && owners.get(tab) !== session) {
        owners.set(tab, session);
        bridge("owner", { tab, session }).catch(() => {});
      }
    }
  }

  const shaped = (t) => ({
    id: t.id,
    url: t.url,
    title: t.title,
    status: t.loading ? "loading" : "complete",
    active: true, // each tab is in front of its own off-screen page
    windowId: WINDOW,
    index: 0,
    incognito: !!t.isolated,
    groupId: groupOf.get(t.id) ?? -1,
  });
  // A tab just opened is in no group, whatever a tab of its number was in before a restart.
  const fresh = (t) => {
    groupOf.delete(t.id);
    owners.delete(t.id);
    return shaped(t);
  };
  const tabs = async () => (await bridge("tabs")).map(shaped);
  const tab = async (id) => {
    const found = (await tabs()).find((t) => t.id === id);
    if (!found) throw new Error(`No tab with id: ${id}.`);
    return found;
  };

  // In a tab's page, the extension's world: page.js and indicator.js, and what the tools run there. Content scripts'
  // chrome.runtime is a small one: messages from the tools in, nothing out.
  const PRELUDE = `if (!globalThis.__zeroMessage) {
    const heard = [];
    const out = (m) => { try { globalThis.zeroSend?.(JSON.stringify(m)); } catch {} return Promise.resolve(); };
    globalThis.chrome = { runtime: { onMessage: { addListener: (f) => heard.push(f) }, sendMessage: out, id: "zero" } };
    // As Chrome's: no content script listening is an error, which is how the tools know to put theirs in first.
    globalThis.__zeroMessage = (m) => new Promise((answer, fail) => {
      if (!heard.length) return fail(new Error("Could not establish connection. Receiving end does not exist."));
      let open = false;
      for (const f of heard) if (f(m, {}, answer) === true) open = true;
      if (!open) answer(undefined);
    });
  }`;
  const inWorld = (tabId, expression) =>
    bridge("world", { tab: tabId, expression: `${PRELUDE};\n${expression}` });

  globalThis.chrome = {
    runtime: {
      id: "zero-browser",
      lastError: undefined,
      getManifest: () => ({ version: "zero-browser" }),
      getURL: (path) => `zero-tools:///${path}`,
      // To the recorder, the one other page an extension of Zero's has: here, the same page.
      sendMessage: (message) =>
        new Promise((done) => {
          if (message?.target !== "zero-offscreen") return done(undefined);
          let open = false;
          for (const f of offscreenMessages.list)
            if (f(message, {}, done) === true) open = true;
          if (!open) done(undefined);
        }),
      onMessage,
      onStartup: listeners(),
      onInstalled: listeners(),
      reload: () => {},
      // zerod's connection, through the browser app's socket: the native host's framing, as browser.rs relays it.
      connectNative() {
        const onMessage = listeners();
        const onDisconnect = listeners();
        globalThis.__zeroLine = (m) => {
          let out;
          if (m.event === "browserCall")
            out = {
              type: "call",
              call: m.call,
              tool: m.tool,
              args: m.args,
              task: m.task,
            };
          else if (m.event === "browserEvent")
            out = {
              type: "cdp",
              tabId: m.tab,
              method: m.method,
              params: m.params,
            };
          else if (m.event === "browserState")
            out = { type: "state", session: m.session, state: m.state };
          else if (m.id && typeof m.id === "object" && "chrome" in m.id)
            out = {
              type: "reply",
              id: m.id.chrome,
              ok: m.ok,
              result: m.result,
              error: m.error,
            };
          if (out) fire(onMessage, out);
        };
        return {
          onMessage,
          onDisconnect,
          postMessage(message) {
            let line;
            if (message.type === "hello")
              line = {
                id: "attach",
                op: "browserAttach",
                browser: {
                  ...message,
                  id: "zero-browser",
                  name: "Zero Browser",
                },
              };
            else if (message.type === "answer")
              line = { op: "browserAnswer", browser: message };
            else if (message.type === "request")
              line = { ...message.request, id: { chrome: message.id } };
            if (line)
              bridge("zerod", { line: JSON.stringify(line) }).catch(() =>
                fire(onDisconnect)
              );
          },
          disconnect() {},
        };
      },
    },
    storage: {
      local: {
        async get(keys) {
          const wanted = keys == null ? Object.keys(store) : [].concat(keys);
          return Object.fromEntries(
            wanted
              .filter((k) => k in store)
              .map((k) => [k, structuredClone(store[k])])
          );
        },
        async set(values) {
          Object.assign(store, structuredClone(values));
          if ("groups" in values) tellOwners();
          save();
        },
      },
    },
    alarms: {
      create(name, { periodInMinutes = 1 } = {}) {
        setInterval(() => fire(onAlarm, { name }), periodInMinutes * 60000);
      },
      onAlarm,
    },
    extension: { isAllowedIncognitoAccess: async () => true },
    // The recorder runs in this page already (offscreen.js, after this).
    offscreen: {
      hasDocument: async () => true,
      createDocument: async () => {},
    },
    windows: {
      // One off-screen window; "incognito" asks for tabs in a context of their own (cookies apart, in memory).
      async create({ url = "about:blank", incognito = false } = {}) {
        const made = fresh(await bridge("open", { url, isolated: incognito }));
        return {
          id: WINDOW,
          focused: false,
          incognito,
          type: "normal",
          tabs: [made],
        };
      },
      get: async (id) => ({ id, focused: false, type: "normal" }),
      getLastFocused: async () => ({
        id: WINDOW,
        focused: false,
        type: "normal",
      }),
    },
    tabs: {
      query: async (q = {}) =>
        (await tabs()).filter(
          (t) =>
            (q.groupId == null || t.groupId === q.groupId) &&
            (q.windowId == null || t.windowId === q.windowId)
        ),
      get: tab,
      create: async ({ url = "about:blank" } = {}) =>
        fresh(await bridge("open", { url })),
      async update(id, { url } = {}) {
        if (url) await bridge("navigate", { tab: id, url });
        return tab(id);
      },
      remove: async (ids) => {
        for (const id of [].concat(ids)) await bridge("close", { tab: id });
      },
      goBack: (id) => bridge("command", { tab: id, name: "back" }),
      goForward: (id) => bridge("command", { tab: id, name: "forward" }),
      async group({ groupId, tabIds, createProperties } = {}) {
        let id = groupId;
        if (id == null) {
          id = nextGroup++;
          groups.set(id, {
            id,
            title: "",
            color: "grey",
            windowId: createProperties?.windowId ?? WINDOW,
          });
        }
        for (const t of [].concat(tabIds)) groupOf.set(t, id);
        tellOwners();
        save();
        return id;
      },
      async sendMessage(tabId, message) {
        const answer = await inWorld(
          tabId,
          `globalThis.__zeroMessage(${JSON.stringify(message)})`
        );
        return answer;
      },
      async captureVisibleTab(_window, { format = "jpeg", quality = 85 } = {}) {
        const shown = (await tabs()).at(-1);
        const shot = await bridge("cdp", {
          tab: shown.id,
          method: "Page.captureScreenshot",
          params: { format, quality },
        });
        return `data:image/${format};base64,${shot.data}`;
      },
      onRemoved,
    },
    tabGroups: {
      async get(id) {
        const g = groups.get(id);
        if (!g) throw new Error(`No group with id: ${id}.`);
        return { ...g };
      },
      async update(id, properties) {
        const g = groups.get(id);
        if (!g) throw new Error(`No group with id: ${id}.`);
        Object.assign(g, properties);
        save();
        return { ...g };
      },
    },
    scripting: {
      async executeScript({ target, func, args = [], files = [] }) {
        if (func) {
          const value = await inWorld(
            target.tabId,
            `(${func.toString()})(...${JSON.stringify(args)})`
          );
          return [{ frameId: 0, result: value }];
        }
        for (const name of files) {
          const source = globalThis.__zeroFiles?.[name];
          if (source == null) throw new Error(`No file ${name}`);
          await inWorld(target.tabId, `${source}\n;undefined`);
        }
        return [{ frameId: 0, result: undefined }];
      },
    },
    debugger: {
      attach: async ({ tabId }) => bridge("attach", { tab: tabId }),
      detach: async ({ tabId }) => bridge("detach", { tab: tabId }),
      sendCommand: ({ tabId }, method, params = {}) =>
        bridge("cdp", { tab: tabId, method, params }),
      onEvent,
      onDetach,
    },
  };

  // From the browser app: zerod's lines, the debugger's events on tabs the tools have it on, and tabs that went.
  globalThis.__zeroIn = (message, raw) => {
    if (message.kind === "line") globalThis.__zeroLine?.(raw);
    else if (message.kind === "message")
      fire(
        onMessage,
        raw,
        { tab: { id: message.tab }, id: "zero-browser" },
        () => {}
      );
    else if (message.kind === "cdp")
      fire(onEvent, { tabId: message.tab }, message.method, raw);
    else if (message.kind === "removed") {
      groupOf.delete(message.tab);
      owners.delete(message.tab);
      fire(onDetach, { tabId: message.tab }, "target_closed");
      fire(onRemoved, message.tab, {
        windowId: WINDOW,
        isWindowClosing: false,
      });
      save();
    }
  };
  // offscreen.js's own chrome: the recorder's messages only.
  globalThis.__zeroOffscreenChrome = {
    runtime: { onMessage: offscreenMessages },
  };
})();
