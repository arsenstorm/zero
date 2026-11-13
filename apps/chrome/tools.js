// The browser_ tools, as Claude in Chrome has them: what each does in a task's tab. Pages are read and changed through
// page.js (refs, the tree, forms); the mouse, keys, screenshots and scripts through Chrome's debugger (cdp.js).

import {
  send,
  attach,
  dialog,
  consoleOf,
  networkOf,
  hold,
  setSize,
  replaceDialogs,
  standingIn,
  answerDialogs,
  dialogCalls,
} from "./cdp.js";
import {
  tabsOf,
  own,
  newTab,
  firstTab,
  share,
  sessionOf,
  blocked,
} from "./tabs.js";

const MAX_PX = 1568;
const PX_PER_TOKEN = 28;
const MAX_TOKENS = 1568;
const frames = new Map(); // tabId → { width, height, viewWidth, viewHeight }: the last screenshot's frame

const text = (words) => ({ content: [{ type: "text", text: words }] });
/** A step that may stall (a page that doesn't answer, a frame that never comes), given up on with its name. */
const within = (ms, promise, what) =>
  Promise.race([
    promise,
    new Promise((_, fail) =>
      setTimeout(() => fail(new Error(`${what} took over ${ms / 1000} s`)), ms)
    ),
  ]);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Claude in Chrome's names, for batches and habits carried over.
const ALIASES = {
  tabs_context_mcp: "browser_tabs",
  tabs_create_mcp: "browser_tab_new",
  tabs_close_mcp: "browser_tab_close",
  navigate: "browser_navigate",
  computer: "browser_computer",
  read_page: "browser_read",
  find: "browser_find",
  get_page_text: "browser_text",
  form_input: "browser_form",
  javascript_tool: "browser_js",
  read_console_messages: "browser_console",
  read_network_requests: "browser_network",
  resize_window: "browser_resize",
  file_upload: "browser_upload",
  browser_batch: "browser_batch",
};

export async function run(tool, args, task) {
  const name =
    ALIASES[tool] || (tool.startsWith("browser_") ? tool : "browser_" + tool);
  const handler = TOOLS[name];
  if (!handler) throw new Error(`No tool ${tool}`);
  replaceDialogs(task.dialogs);
  const result = await handler(args, task);
  // What the page's dialogs asked meanwhile, where they're stand-ins: told with the tool's own answer.
  const said = typeof args.tabId === "number" ? dialogCalls(args.tabId) : "";
  if (said)
    result.content = [...(result.content || []), { type: "text", text: said }];
  return result;
}

/** The session driving a tab, when the user presses Stop on it. */
export async function stopped(tabId) {
  indicate(tabId, null);
  return sessionOf(tabId);
}

/** A tab of the task's that a tool may act on now: its own, not on a blocked site. */
async function usable(task, tabId) {
  const tab = await own(task, tabId);
  if (blocked(tab.url, task.blocked))
    throw new Error(
      `${new URL(tab.url).hostname} is on the user's blocked sites`
    );
  indicate(tab.id, task.name);
  busy(tab.id);
  return tab;
}

/** Something is happening in the tab: a recording of it keeps this stretch. */
function busy(tabId, ms = 900) {
  if (recordings.has(tabId))
    chrome.runtime
      .sendMessage({
        target: "zero-offscreen",
        type: "active",
        key: String(tabId),
        ms,
      })
      .catch(() => {});
}

/** While a tab is recorded, the pointer glides to where it acts before it acts, as a person's would. */
async function glide(tabId, { x, y }) {
  if (!recordings.has(tabId)) return;
  busy(tabId, 1500);
  await chrome.tabs
    .sendMessage(tabId, { type: "zero-cursor", x, y })
    .catch(() => {});
  await sleep(420);
}

// The page's indicator: a border and a pill naming the task, with Stop.
const lastUse = new Map();
function indicate(tabId, name) {
  clearTimeout(lastUse.get(tabId));
  // Whether it's being recorded goes with it: a page loaded since the recording began doesn't know.
  const message = {
    type: "zero-driving",
    name,
    recording: recordings.has(tabId),
  };
  chrome.tabs.sendMessage(tabId, message).catch(() => {
    if (!name) return;
    chrome.scripting
      .executeScript({ target: { tabId }, files: ["indicator.js"] })
      .then(() => chrome.tabs.sendMessage(tabId, message))
      .catch(() => {});
  });
  if (name)
    lastUse.set(
      tabId,
      setTimeout(
        () =>
          chrome.tabs
            .sendMessage(tabId, { type: "zero-driving", name: null })
            .catch(() => {}),
        15000
      )
    );
}

/** Runs one of page.js's functions in the tab's page (its top frame). A page opened before the extension last
 * loaded has no page.js or indicator: they're put in first. */
async function page(tabId, fn, ...args) {
  const call = () =>
    chrome.scripting.executeScript({
      target: { tabId },
      func: (fn, args) => {
        const zero = globalThis.__zero;
        if (!zero) return { missing: true };
        try {
          return { value: zero[fn](...args) };
        } catch (error) {
          return { error: String(error?.message || error) };
        }
      },
      args: [fn, args],
    });
  let [result] = await call();
  if (result?.result?.missing) {
    await chrome.scripting.executeScript({
      target: { tabId },
      files: ["page.js", "indicator.js"],
    });
    [result] = await call();
  }
  if (result?.result?.missing)
    throw new Error("The page isn't ready yet: try again in a moment");
  if (result?.result?.error) throw new Error(result.result.error);
  return result?.result?.value;
}

async function loaded(tabId, timeout = 30000) {
  const start = Date.now();
  await sleep(150);
  while (Date.now() - start < timeout) {
    const tab = await chrome.tabs.get(tabId);
    if (tab.status === "complete") return tab;
    await sleep(150);
  }
  return chrome.tabs.get(tabId);
}

function describeTab(tab) {
  return `${tab.title || "(untitled)"} (${tab.url})`;
}

async function viewport(tabId) {
  const metrics = await send(tabId, "Page.getLayoutMetrics");
  const v = metrics.cssVisualViewport || metrics.visualViewport;
  return {
    width: v.clientWidth,
    height: v.clientHeight,
    x: v.pageX,
    y: v.pageY,
  };
}

/** The size an image of width × height is sent at: at most 1568 px a side and 1568 tokens of 28 px squares. */
function fit(width, height) {
  let scale = Math.min(1, MAX_PX / Math.max(width, height));
  while (
    Math.ceil((width * scale) / PX_PER_TOKEN) *
      Math.ceil((height * scale) / PX_PER_TOKEN) >
    MAX_TOKENS
  )
    scale *= 0.95;
  return {
    width: Math.max(1, Math.round(width * scale)),
    height: Math.max(1, Math.round(height * scale)),
  };
}

/** The image at width × height; with `crop` (fractions of it: x, y, w, h), only that part. */
async function resized(
  base64,
  width,
  height,
  crop = { x: 0, y: 0, w: 1, h: 1 }
) {
  const bitmap = await createImageBitmap(
    await (await fetch(`data:image/jpeg;base64,${base64}`)).blob()
  );
  const canvas = new OffscreenCanvas(width, height);
  const context = canvas.getContext("2d");
  context.imageSmoothingQuality = "high";
  context.drawImage(
    bitmap,
    crop.x * bitmap.width,
    crop.y * bitmap.height,
    crop.w * bitmap.width,
    crop.h * bitmap.height,
    0,
    0,
    width,
    height
  );
  const blob = await canvas.convertToBlob({ type: "image/jpeg", quality: 0.8 });
  const bytes = new Uint8Array(await blob.arrayBuffer());
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000)
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}

/** The viewport as an image, and the frame its coordinates are in. `region` (in that frame) zooms into part of it;
 * `fullPage` takes the whole page (kept on disk at full size, shown shrunk); `keep` saves the image as a file. */
async function screenshot(
  tabId,
  { scale = 1, region, fullPage = false, keep = false } = {}
) {
  await within(
    1000,
    chrome.tabs.sendMessage(tabId, { type: "zero-hide", hidden: true }),
    "Hiding the indicator"
  ).catch(() => {});
  try {
    const view = await within(
      10000,
      viewport(tabId),
      "Reading the page's size"
    );
    if (fullPage) {
      const metrics = await send(tabId, "Page.getLayoutMetrics");
      const size = metrics.cssContentSize || metrics.contentSize;
      const height = Math.min(size.height, 16000);
      const shot = await send(tabId, "Page.captureScreenshot", {
        format: "jpeg",
        quality: 85,
        captureBeyondViewport: true,
        fromSurface: true,
        clip: { x: 0, y: 0, width: size.width, height, scale: 1 },
      });
      const shown = fit(size.width, height);
      const data = await resized(
        shot.data,
        Math.round(shown.width * scale),
        Math.round(shown.height * scale)
      );
      return {
        content: [
          {
            type: "text",
            text: `The whole page of tab ${tabId}, ${Math.round(size.width)}×${Math.round(height)}, shown shrunk. Coordinates for clicks still refer to the view (take a plain screenshot).`,
          },
          { type: "image", data, mimeType: "image/jpeg" },
        ],
        keep: [{ data: shot.data, extension: "jpg" }],
      };
    }
    // The whole view, cropped here: simpler than Chrome's clip, and right at any density.
    let part = { x: 0, y: 0, w: 1, h: 1 },
      width = view.width,
      height = view.height;
    if (region) {
      const frame = frames.get(tabId) || {
        ...fit(view.width, view.height),
        viewWidth: view.width,
        viewHeight: view.height,
      };
      const [x0, y0, x1, y1] = region.map(Number);
      part = {
        x: x0 / frame.width,
        y: y0 / frame.height,
        w: Math.max(1, x1 - x0) / frame.width,
        h: Math.max(1, y1 - y0) / frame.height,
      };
      width = part.w * view.width;
      height = part.h * view.height;
    }
    const shot = await within(
      20000,
      send(tabId, "Page.captureScreenshot", {
        format: "jpeg",
        quality: 85,
        fromSurface: true,
      }),
      "Chrome's screenshot"
    );
    const size = fit(width, height);
    if (!region)
      frames.set(tabId, {
        ...size,
        viewWidth: view.width,
        viewHeight: view.height,
      });
    const shown = {
      width: Math.max(1, Math.round(size.width * scale)),
      height: Math.max(1, Math.round(size.height * scale)),
    };
    const data = await within(
      10000,
      resized(shot.data, shown.width, shown.height, part),
      "Sizing the screenshot"
    );
    const about = region
      ? `Zoomed into (${region.join(", ")}).`
      : `Screenshot of tab ${tabId}, ${size.width}×${size.height}${scale < 1 ? `, shown at ${shown.width}×${shown.height}` : ""}: coordinates are in the ${size.width}×${size.height} frame.`;
    const kept =
      keep &&
      (region
        ? await resized(
            shot.data,
            Math.round(width * 2),
            Math.round(height * 2),
            part
          )
        : shot.data);
    return {
      content: [
        { type: "text", text: about },
        { type: "image", data, mimeType: "image/jpeg" },
      ],
      ...(keep ? { keep: [{ data: kept, extension: "jpg" }] } : {}),
    };
  } finally {
    within(
      1000,
      chrome.tabs.sendMessage(tabId, { type: "zero-hide", hidden: false }),
      "Showing the indicator"
    ).catch(() => {});
  }
}

/** A point the agent gave, in the last screenshot's frame, in the page's CSS pixels; or a ref's centre. */
async function point(tabId, args, which = "coordinate") {
  if (args.ref && which === "coordinate")
    return page(tabId, "center", args.ref);
  const at = args[which];
  if (!Array.isArray(at) || at.length !== 2)
    throw new Error(`Where? ${which} [x, y], or a ref`);
  let frame = frames.get(tabId);
  if (!frame) {
    const view = await viewport(tabId);
    frame = {
      ...fit(view.width, view.height),
      viewWidth: view.width,
      viewHeight: view.height,
    };
    frames.set(tabId, frame);
  }
  const [x, y] = at.map(Number);
  if (x < 0 || y < 0 || x > frame.width || y > frame.height)
    throw new Error(
      `(${x}, ${y}) is outside the ${frame.width}×${frame.height} screenshot`
    );
  return {
    x: (x * frame.viewWidth) / frame.width,
    y: (y * frame.viewHeight) / frame.height,
  };
}

function modifierBits(modifiers = "") {
  let bits = 0;
  for (const m of String(modifiers)
    .toLowerCase()
    .split("+")
    .map((s) => s.trim())) {
    if (m === "alt" || m === "option") bits |= 1;
    else if (m === "ctrl" || m === "control") bits |= 2;
    else if (
      m === "cmd" ||
      m === "meta" ||
      m === "command" ||
      m === "win" ||
      m === "windows" ||
      m === "super"
    )
      bits |= 4;
    else if (m === "shift") bits |= 8;
  }
  return bits;
}

/** Whether Chrome refuses the debugger this tab: another extension's frame is in it. */
async function shut(tabId) {
  try {
    await attach(tabId);
    return false;
  } catch (error) {
    return /different extension/i.test(String(error?.message));
  }
}

/** The tab as it shows on screen, without the debugger: only when it's the one in front in its window. */
async function glimpse(tab) {
  if (!tab.active)
    throw new Error(
      "Chrome keeps the debugger off this tab (another extension has a frame in it), and it isn't in front for a plain screenshot: read it with browser_read or browser_text"
    );
  const url = await chrome.tabs.captureVisibleTab(tab.windowId, {
    format: "jpeg",
    quality: 85,
  });
  return {
    content: [
      {
        type: "text",
        text: `Tab ${tab.id} as it shows (Chrome keeps the debugger off it while another extension has a frame in it: click by ref).`,
      },
      { type: "image", data: url.split(",")[1], mimeType: "image/jpeg" },
    ],
  };
}

async function click(
  tabId,
  { x, y },
  { button = "left", count = 1, modifiers = 0 } = {}
) {
  const buttons = { left: 1, right: 2, middle: 4 }[button];
  await glide(tabId, { x, y });
  // A ripple where it lands: the user sees it, and so does a recording.
  chrome.tabs.sendMessage(tabId, { type: "zero-click", x, y }).catch(() => {});
  await send(tabId, "Input.dispatchMouseEvent", {
    type: "mouseMoved",
    x,
    y,
    modifiers,
  });
  for (let n = 1; n <= count; n++) {
    await send(tabId, "Input.dispatchMouseEvent", {
      type: "mousePressed",
      x,
      y,
      button,
      buttons,
      clickCount: n,
      modifiers,
    });
    await send(tabId, "Input.dispatchMouseEvent", {
      type: "mouseReleased",
      x,
      y,
      button,
      buttons: 0,
      clickCount: n,
      modifiers,
    });
  }
}

const KEYS = {
  enter: ["Enter", "Enter", 13, "\r"],
  return: ["Enter", "Enter", 13, "\r"],
  tab: ["Tab", "Tab", 9],
  backspace: ["Backspace", "Backspace", 8],
  delete: ["Delete", "Delete", 46],
  escape: ["Escape", "Escape", 27],
  esc: ["Escape", "Escape", 27],
  space: [" ", "Space", 32, " "],
  up: ["ArrowUp", "ArrowUp", 38],
  down: ["ArrowDown", "ArrowDown", 40],
  left: ["ArrowLeft", "ArrowLeft", 37],
  right: ["ArrowRight", "ArrowRight", 39],
  arrowup: ["ArrowUp", "ArrowUp", 38],
  arrowdown: ["ArrowDown", "ArrowDown", 40],
  arrowleft: ["ArrowLeft", "ArrowLeft", 37],
  arrowright: ["ArrowRight", "ArrowRight", 39],
  home: ["Home", "Home", 36],
  end: ["End", "End", 35],
  pageup: ["PageUp", "PageUp", 33],
  pagedown: ["PageDown", "PageDown", 34],
};
for (let i = 1; i <= 12; i++) KEYS["f" + i] = ["F" + i, "F" + i, 111 + i];
// What Chrome on a Mac does for these chords; synthetic keys don't reach its menu shortcuts by themselves.
const MAC_COMMANDS = {
  "4a": "selectAll",
  "4c": "copy",
  "4v": "paste",
  "4x": "cut",
  "4z": "undo",
  "12z": "redo",
};

function keyOf(name) {
  const known = KEYS[name.toLowerCase()];
  if (known)
    return { key: known[0], code: known[1], keyCode: known[2], text: known[3] };
  if (name.length === 1) {
    const upper = name.toUpperCase();
    const code = /[A-Z]/.test(upper)
      ? "Key" + upper
      : /[0-9]/.test(name)
        ? "Digit" + name
        : undefined;
    return { key: name, code, keyCode: upper.charCodeAt(0), text: name };
  }
  throw new Error(`Which key is “${name}”?`);
}

async function press(tabId, chord) {
  const parts = chord.split("+");
  const name = parts.pop();
  const modifiers = modifierBits(parts.join("+"));
  if ((modifiers & 4 || modifiers & 2) && ["=", "-", "0", "+"].includes(name))
    throw new Error(
      "Page zoom keys aren't allowed: use the zoom action to look closer"
    );
  const key = keyOf(name);
  const commands = MAC_COMMANDS[`${modifiers}${name.toLowerCase()}`];
  const text = modifiers & ~8 ? undefined : key.text;
  await send(tabId, "Input.dispatchKeyEvent", {
    type: text ? "keyDown" : "rawKeyDown",
    key: key.key,
    code: key.code,
    windowsVirtualKeyCode: key.keyCode,
    modifiers,
    text,
    unmodifiedText: text,
    commands: commands ? [commands] : undefined,
  });
  await send(tabId, "Input.dispatchKeyEvent", {
    type: "keyUp",
    key: key.key,
    code: key.code,
    windowsVirtualKeyCode: key.keyCode,
    modifiers,
  });
}

async function type(tabId, words) {
  // Long text goes in at once; short text key by key, so pages that listen to keys hear them.
  if (words.length > 200)
    return send(tabId, "Input.insertText", { text: words });
  busy(tabId, 900 + words.length * 40);
  for (const ch of words) {
    if (ch === "\n") {
      await press(tabId, "Enter");
      continue;
    }
    await send(tabId, "Input.dispatchKeyEvent", {
      type: "keyDown",
      key: ch,
      text: ch,
      unmodifiedText: ch,
    });
    await send(tabId, "Input.dispatchKeyEvent", { type: "keyUp", key: ch });
  }
}

const TOOLS = {
  async browser_tabs({ createIfEmpty, window }, task) {
    let tabs = await tabsOf(task);
    if (!tabs.length && createIfEmpty) {
      await newTab(task, "about:blank", window);
      tabs = await tabsOf(task);
    }
    if (!tabs.length)
      return text(
        "This task has no tabs yet: browser_tab_new opens one, or browser_tabs with createIfEmpty."
      );
    const groups = new Map();
    for (const t of tabs)
      if (t.groupId >= 0 && !groups.has(t.groupId))
        groups.set(
          t.groupId,
          (await chrome.tabGroups.get(t.groupId).catch(() => null))?.title
        );
    return text(
      JSON.stringify(
        tabs.map((t) => ({
          tabId: t.id,
          title: t.title,
          url: t.url,
          ...(t.incognito ? { incognito: true } : {}),
          ...(t.given
            ? { givenByTheUser: true }
            : { group: groups.get(t.groupId) }),
        })),
        null,
        1
      )
    );
  },

  async browser_tab_new({ window }, task) {
    const tab = await newTab(task, "about:blank", window);
    return text(
      `Opened tab ${tab.id}. This task's tabs: ${(await tabsOf(task)).map((t) => t.id).join(", ")}`
    );
  },

  async browser_tab_close({ tabId }, task) {
    const tab = await own(task, tabId);
    if (tab.given) {
      await share(tab.id, null);
      return text(`Gave tab ${tab.id} back to the user.`);
    }
    await chrome.tabs.remove(tab.id);
    return text(`Closed tab ${tab.id}.`);
  },

  async browser_navigate({ url, tabId }, task) {
    if (!url) throw new Error("Where to? A URL, back or forward");
    const tab = tabId == null ? await firstTab(task) : await own(task, tabId);
    indicate(tab.id, task.name);
    if (url === "back" || url === "forward") {
      await (url === "back"
        ? chrome.tabs.goBack(tab.id)
        : chrome.tabs.goForward(tab.id));
    } else {
      const target = /^[a-z][a-z0-9+.-]*:/i.test(url) ? url : "https://" + url;
      if (blocked(target, task.blocked))
        throw new Error(
          `${new URL(target).hostname} is on the user's blocked sites`
        );
      // The debugger first, so the page's own load is in its network and console logs.
      await attach(tab.id).catch(() => {});
      await chrome.tabs.update(tab.id, { url: target });
    }
    busy(tab.id, 2500);
    const now = await loaded(tab.id);
    busy(tab.id, 1200);
    if (blocked(now.url, task.blocked)) {
      await chrome.tabs.update(tab.id, { url: "about:blank" });
      throw new Error(
        `It went to ${new URL(now.url).hostname}, which is on the user's blocked sites`
      );
    }
    frames.delete(tab.id);
    return text(`Tab ${tab.id}: ${describeTab(now)}`);
  },

  async browser_computer(args, task) {
    const tab = await usable(task, args.tabId);
    const id = tab.id;
    const modifiers = modifierBits(args.modifiers);
    switch (args.action) {
      case "screenshot":
        if (await shut(id)) return glimpse(tab);
        return screenshot(id, {
          scale: args.scale ?? 1,
          fullPage: !!args.full_page,
          keep: !!args.save_to_disk,
        });
      case "zoom":
        if (!Array.isArray(args.region) || args.region.length !== 4)
          throw new Error("Zoom into what? region [x0, y0, x1, y1]");
        return screenshot(id, {
          region: args.region,
          scale: args.scale ?? 1,
          keep: !!args.save_to_disk,
        });
      case "left_click":
      case "right_click":
      case "double_click":
      case "triple_click": {
        // Another extension's frame in the page (a password manager's menu) and Chrome keeps the debugger out of the
        // whole tab: an element named by its ref is still clicked, from inside the page.
        if (args.ref && args.action === "left_click" && (await shut(id))) {
          await page(id, "press", args.ref);
          return text(
            "Clicked it (from inside the page: Chrome keeps the debugger off this tab while another extension has a frame in it)."
          );
        }
        const at = await point(id, args);
        const button = args.action === "right_click" ? "right" : "left";
        const count = { double_click: 2, triple_click: 3 }[args.action] || 1;
        await click(id, at, { button, count, modifiers });
        return text(
          `Clicked${count > 1 ? ` ${count} times` : ""} at (${Math.round(at.x)}, ${Math.round(at.y)}) in the page.`
        );
      }
      case "hover": {
        const at = await point(id, args);
        await glide(id, at);
        await send(id, "Input.dispatchMouseEvent", {
          type: "mouseMoved",
          x: at.x,
          y: at.y,
          modifiers,
        });
        return text("Moved the mouse there.");
      }
      case "left_click_drag": {
        const from = await point(id, args, "start_coordinate");
        const to = await point(id, args);
        await glide(id, from);
        await send(id, "Input.dispatchMouseEvent", {
          type: "mouseMoved",
          x: from.x,
          y: from.y,
        });
        await send(id, "Input.dispatchMouseEvent", {
          type: "mousePressed",
          x: from.x,
          y: from.y,
          button: "left",
          buttons: 1,
          clickCount: 1,
        });
        for (let i = 1; i <= 10; i++) {
          await send(id, "Input.dispatchMouseEvent", {
            type: "mouseMoved",
            x: from.x + ((to.x - from.x) * i) / 10,
            y: from.y + ((to.y - from.y) * i) / 10,
            button: "left",
            buttons: 1,
          });
        }
        await send(id, "Input.dispatchMouseEvent", {
          type: "mouseReleased",
          x: to.x,
          y: to.y,
          button: "left",
          buttons: 0,
          clickCount: 1,
        });
        return text("Dragged.");
      }
      case "type":
        if (typeof args.text !== "string") throw new Error("Type what? text");
        await type(id, args.text);
        return text(`Typed ${args.text.length} characters.`);
      case "key": {
        if (!args.text)
          throw new Error('Which keys? text, such as "Enter" or "cmd+a"');
        const times = Math.max(1, Math.min(100, Number(args.repeat) || 1));
        for (let i = 0; i < times; i++)
          for (const chord of String(args.text).split(/\s+/).filter(Boolean))
            await press(id, chord);
        return text(
          `Pressed ${args.text}${times > 1 ? ` ${times} times` : ""}.`
        );
      }
      case "scroll": {
        const at = await point(id, args);
        await glide(id, at);
        busy(id, 1500);
        const ticks = Math.max(
          1,
          Math.min(10, Number(args.scroll_amount) || 3)
        );
        const direction = args.scroll_direction || "down";
        const dx =
          direction === "left"
            ? -100 * ticks
            : direction === "right"
              ? 100 * ticks
              : 0;
        const dy =
          direction === "up"
            ? -100 * ticks
            : direction === "down"
              ? 100 * ticks
              : 0;
        await send(id, "Input.dispatchMouseEvent", {
          type: "mouseWheel",
          x: at.x,
          y: at.y,
          deltaX: dx,
          deltaY: dy,
          modifiers,
        });
        await sleep(300);
        return screenshot(id);
      }
      case "scroll_to":
        if (!args.ref) throw new Error("Scroll to what? A ref");
        await page(id, "center", args.ref);
        return text(`Scrolled ${args.ref} into view.`);
      case "wait":
        await sleep(
          Math.max(0, Math.min(10, Number(args.duration) || 1)) * 1000
        );
        return text("Waited.");
      default:
        throw new Error(`No action ${args.action}`);
    }
  },

  async browser_read(
    { tabId, filter = "all", depth = 15, ref_id, max_chars = 50000 },
    task
  ) {
    const tab = await usable(task, tabId);
    const tree = await page(tab.id, "tree", {
      filter,
      depth,
      ref: ref_id,
      maxChars: max_chars,
    });
    return text(`${describeTab(tab)}\n${tree}`);
  },

  async browser_find({ tabId, query }, task) {
    const tab = await usable(task, tabId);
    if (!query) throw new Error("Find what? query");
    return text(await page(tab.id, "find", query));
  },

  async browser_text({ tabId, max_chars = 50000 }, task) {
    const tab = await usable(task, tabId);
    return text(
      `${describeTab(tab)}\n\n${await page(tab.id, "text", max_chars)}`
    );
  },

  async browser_form({ tabId, ref, value }, task) {
    const tab = await usable(task, tabId);
    return text(await page(tab.id, "form", ref, value));
  },

  async browser_js({ tabId, text: code }, task) {
    const tab = await usable(task, tabId);
    if (!code) throw new Error("Run what? text");
    const evaluate = (expression) =>
      send(tab.id, "Runtime.evaluate", {
        expression,
        replMode: true,
        awaitPromise: true,
        returnByValue: true,
        userGesture: true,
      });
    let result = await evaluate(code);
    // A top-level return reads as the agent meant: the code's own function.
    if (
      result.exceptionDetails &&
      /Illegal return/i.test(
        result.exceptionDetails.exception?.description || ""
      )
    )
      result = await evaluate(`(async () => {\n${code}\n})()`);
    if (result.exceptionDetails)
      throw new Error(
        result.exceptionDetails.exception?.description ||
          result.exceptionDetails.text
      );
    const value =
      result.result.value === undefined
        ? (result.result.description ?? "undefined")
        : scrub(result.result.value);
    const shown =
      typeof value === "string" ? value : JSON.stringify(value, null, 1);
    return text(
      shown.length > 50000
        ? shown.slice(0, 50000) + `\n… (${shown.length} characters in all)`
        : shown
    );
  },

  async browser_console(
    { tabId, pattern, onlyErrors, clear, limit = 100 },
    task
  ) {
    const tab = await usable(task, tabId);
    await send(tab.id, "Runtime.enable");
    const all = consoleOf(tab.id);
    let match = pattern ? new RegExp(pattern, "i") : null;
    const picked = all
      .filter(
        (m) =>
          (!onlyErrors || m.level === "error" || m.level === "exception") &&
          (!match || match.test(m.text))
      )
      .slice(-limit);
    if (clear) all.length = 0;
    return text(
      picked.length
        ? picked.map((m) => `[${m.level}] ${m.text}`).join("\n")
        : "No messages (they're kept from when a tool first used this tab on this site)."
    );
  },

  async browser_network({ tabId, urlPattern, clear, limit = 100 }, task) {
    const tab = await usable(task, tabId);
    await send(tab.id, "Network.enable", { maxPostDataSize: 0 }).catch(
      () => {}
    );
    const all = networkOf(tab.id);
    const seen = [...all.values()];
    // The page's own record too (its resource timing), for what it fetched before Zero was watching: no method, but
    // the status where Chrome has it.
    const known = new Set(seen.map((r) => r.url));
    const timed = await send(tab.id, "Runtime.evaluate", {
      returnByValue: true,
      expression: `performance.getEntriesByType("navigation").concat(performance.getEntriesByType("resource")).map((e) => ({ url: e.name, type: e.initiatorType || e.entryType, status: e.responseStatus || null }))`,
    })
      .then((r) => r.result?.value || [])
      .catch(() => []);
    const earlier = timed
      .filter((r) => !known.has(r.url))
      .map((r) => ({
        method: "(before)",
        url: r.url,
        status: r.status,
        type: r.type,
      }));
    const picked = [...earlier, ...seen]
      .filter((r) => !urlPattern || r.url.includes(urlPattern))
      .slice(-limit);
    if (clear) all.clear();
    return text(
      picked.length
        ? picked
            .map((r) => `${r.method} ${r.status ?? "pending"} ${r.url}`)
            .join("\n")
        : urlPattern
          ? `No requests to URLs containing “${urlPattern}”.`
          : "No requests."
    );
  },

  async browser_resize({ tabId, width, height, reset }, task) {
    const tab = await usable(task, tabId);
    frames.delete(tab.id);
    // The page's size in its tab, as DevTools' device mode sets it: the window (often the user's, maybe full screen)
    // stays as it is.
    if (reset) {
      await setSize(tab.id, null);
      return text("The page has its tab's own size again.");
    }
    const w = Math.round(Math.min(7680, Math.max(200, Number(width)))),
      h = Math.round(Math.min(4320, Math.max(200, Number(height))));
    await setSize(tab.id, { width: w, height: h });
    return text(
      `The page is now laid out at ${w}×${h}, in its tab; the window is left as it is. browser_resize with reset undoes it.`
    );
  },

  async browser_upload({ tabId, ref, coordinate, files }, task) {
    const tab = await usable(task, tabId);
    if (!files?.length) throw new Error("Upload which files?");
    let at = null;
    if (!ref) {
      if (!coordinate)
        throw new Error(
          "Where to? A file field's ref, or a coordinate to drop them at"
        );
      at = await point(tab.id, { coordinate });
    }
    return text(await page(tab.id, "upload", ref || null, at, files));
  },

  async browser_record({ tabId, action, max_seconds = 300 }, task) {
    const tab = await usable(task, tabId);
    if (action === "start") {
      if (recordings.has(tab.id))
        throw new Error(
          `Tab ${tab.id} is being recorded already: stop it first`
        );
      await offscreen();
      const view = await viewport(tab.id);
      // The screen's own pixels (a Retina screen's two per point), so the video is as sharp as the screen. Forcing two
      // per point on a screen with one garbles the page once it redraws, so it isn't done.
      const density =
        (
          await send(tab.id, "Runtime.evaluate", {
            expression: "devicePixelRatio",
            returnByValue: true,
          })
        ).result?.value || 1;
      const scale = Math.min(density, 2560 / view.width, 1600 / view.height);
      const size = {
        width: Math.round(view.width * scale),
        height: Math.round(view.height * scale),
      };
      await chrome.runtime.sendMessage({
        target: "zero-offscreen",
        type: "start",
        key: String(tab.id),
      });
      const stopAt = setTimeout(
        () => finish(tab.id),
        Math.min(600, Math.max(1, max_seconds)) * 1000
      );
      recordings.set(tab.id, { stopAt, started: Date.now() });
      hold(tab.id, true);
      chrome.tabs
        .sendMessage(tab.id, { type: "zero-recording", on: true })
        .catch(() => {});
      capture(tab.id, size);
      return text(
        `Recording tab ${tab.id}. Act in it, then browser_record stop. It stops by itself after ${max_seconds} s.`
      );
    }
    if (action === "stop") {
      const video = await stopRecording(tab.id);
      return {
        content: [
          {
            type: "text",
            text: `Recorded ${video.seconds} s of tab ${tab.id}, ${video.width}×${video.height} ${video.extension.toUpperCase()}, idle time left out.`,
          },
        ],
        keep: [{ data: video.data, extension: video.extension }],
      };
    }
    throw new Error("start or stop?");
  },

  async browser_dialog({ tabId, accept, text: answer }, task) {
    const tab = await own(task, tabId);
    await attach(tab.id);
    const open = dialog(tab.id);
    if (!open && standingIn(tab.id)) {
      await answerDialogs(tab.id, { accept: !!accept, text: answer });
      return text(
        accept
          ? `This tab's confirm and prompt answer OK from now on${answer === undefined ? "" : `, prompt with “${answer}”`}.`
          : "This tab's confirm and prompt answer Cancel from now on."
      );
    }
    if (!open) return text("No dialog is open.");
    await send(tab.id, "Page.handleJavaScriptDialog", {
      accept: !!accept,
      promptText: answer,
    });
    return text(`${accept ? "Accepted" : "Dismissed"} the ${open.type}.`);
  },

  async browser_batch({ actions }, task) {
    if (!Array.isArray(actions) || !actions.length)
      throw new Error("Which actions? [{name, input}, …]");
    const content = [],
      keep = [];
    for (const [i, { name, input }] of actions.entries()) {
      if (name === "browser_batch")
        throw new Error("A batch can't hold a batch");
      try {
        const result = await run(name, input || {}, task);
        content.push(...result.content);
        keep.push(...(result.keep || []));
      } catch (error) {
        content.push({
          type: "text",
          text: `Step ${i + 1} (${name}) failed: ${error.message}. The rest didn't run.`,
        });
        return { content, isError: true, ...(keep.length ? { keep } : {}) };
      }
    }
    return { content, ...(keep.length ? { keep } : {}) };
  },
};

// Recordings: the tab's screenshots, drawn into a video in an offscreen page.
const recordings = new Map(); // tabId → { stopAt, started, capturing: Promise, finished?: Promise of the video }

async function offscreen() {
  if (await chrome.offscreen.hasDocument()) return;
  await chrome.offscreen.createDocument({
    url: "offscreen.html",
    reasons: ["BLOBS"],
    justification: "Records a tab's frames into a video",
  });
}

/** A recording's frames: the tab's screenshots, about fifteen a second, at the screen's density. Unlike Chrome's
 * screencast, they come even when nothing moves, so a recording always has its first frame; frames that change
 * nothing are left out of the video by the offscreen page. */
function capture(tabId, size) {
  const recording = recordings.get(tabId);
  recording.capturing = (async () => {
    while (recordings.get(tabId) === recording && !recording.finished) {
      const started = Date.now();
      try {
        const shot = await send(tabId, "Page.captureScreenshot", {
          format: "jpeg",
          quality: 90,
          fromSurface: true,
        });
        await chrome.runtime.sendMessage({
          target: "zero-offscreen",
          type: "frame",
          key: String(tabId),
          data: shot.data,
          width: size.width,
          height: size.height,
        });
      } catch {}
      await sleep(Math.max(0, 66 - (Date.now() - started)));
    }
  })();
}

/** Ends a tab's recording: the capture stopped, the video made. Once only, by its clock or by stop. */
function finish(tabId) {
  const recording = recordings.get(tabId);
  if (!recording.finished) {
    clearTimeout(recording.stopAt);
    recording.finished = (async () => {
      await recording.capturing;
      hold(tabId, false);
      chrome.tabs
        .sendMessage(tabId, { type: "zero-recording", on: false })
        .catch(() => {});
      return chrome.runtime.sendMessage({
        target: "zero-offscreen",
        type: "stop",
        key: String(tabId),
      });
    })();
  }
  return recording.finished;
}

/** Stops a tab's recording, or takes the one that stopped by itself: the video, in base64, and how long. */
async function stopRecording(tabId) {
  if (!recordings.has(tabId))
    throw new Error(
      `Tab ${tabId} isn't being recorded: browser_record start first`
    );
  const video = await finish(tabId);
  recordings.delete(tabId);
  if (!video?.data)
    throw new Error(video?.error || "The recording came out empty");
  return video;
}

/** A value from the page without what looks like a secret: keys named for one, and strings shaped like one. */
function scrub(value, depth = 0) {
  if (depth > 20) return value;
  if (typeof value === "string")
    return /^eyJ[\w-]+\.[\w-]+\.[\w-]+$/.test(value) ||
      /^(sk|pk|ghp|gho|xox[abp])[-_]/.test(value)
      ? "[left out: looks like a secret]"
      : value;
  if (Array.isArray(value)) return value.map((v) => scrub(v, depth + 1));
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([k, v]) => [
        k,
        /pass(word)?|secret|token|api[-_]?key|authori[sz]ation|cookie|session/i.test(
          k
        )
          ? "[left out]"
          : scrub(v, depth + 1),
      ])
    );
  }
  return value;
}
