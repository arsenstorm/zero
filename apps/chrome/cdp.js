import { alerted } from "./tabs.js";

// Chrome's debugger on a task's tabs: attached when a tool needs it, detached after a while unused (Chrome shows a
// banner while any tab is debugged). Keeps each tab's console, requests and open dialog while attached.
// In Firefox, which has no debugger for extensions, each command goes to Zero instead, which does it through
// Firefox's remote control (zerod's firefox.rs) and sends Firefox's events back shaped as Chrome's (`event` below).

/** No debugger of the browser's own: Zero does the commands. */
const remote = !globalThis.chrome?.debugger;
let zero = null; // (op, fields) => Promise: a request to zerod, set by the worker
const marked = new Set(); // tabs Zero knows: their mark was found

/** How a request reaches zerod (the worker's connection). */
export function useZero(ask) { zero = ask }

/** One command done by Zero, in Firefox. The first for a tab marks its page so Zero can tell which tab it is. */
async function remoteCommand(tabId, method, params) {
  if (!zero) throw new Error("Zero isn't connected");
  if (marked.has(tabId)) {
    try { return await zero("firefox", { args: { tab: tabId, method, params } }) }
    catch (error) { if (!/mark/.test(String(error?.message))) throw error; marked.delete(tabId) }
  }
  const nonce = crypto.randomUUID();
  await chrome.scripting.executeScript({ target: { tabId }, func: (n) => document.documentElement.setAttribute("data-zero-tab", n), args: [nonce] });
  const result = await zero("firefox", { args: { tab: tabId, nonce, method, params } });
  marked.add(tabId);
  return result;
}

const command = (tabId, method, params = {}) => remote ? remoteCommand(tabId, method, params) : chrome.debugger.sendCommand({ tabId }, method, params);

const IDLE = 30000;
const LOG_LIMIT = 1000;
const attached = new Map(); // tabId → idle timer
const logs = new Map(); // tabId → { host, console: [], network: Map }
const dialogs = new Map(); // tabId → { type, message }

function log(tabId) {
  if (!logs.has(tabId)) logs.set(tabId, { host: "", console: [], network: new Map() });
  return logs.get(tabId);
}

const held = new Set(); // tabs being recorded: never detached for being idle
const frameListeners = new Map(); // tabId → (data, metadata) => void

/** Keeps the debugger on a tab while it's recorded; its screencast frames to `listener`, or none to stop. */
export function hold(tabId, listener) {
  if (listener) { held.add(tabId); frameListeners.set(tabId, listener) } else { held.delete(tabId); frameListeners.delete(tabId) }
}

function idle(tabId) { return setTimeout(() => { if (!held.has(tabId)) detach(tabId); else attached.set(tabId, idle(tabId)) }, IDLE) }

export async function attach(tabId) {
  if (attached.has(tabId)) {
    clearTimeout(attached.get(tabId));
    attached.set(tabId, idle(tabId));
    return;
  }
  try {
    if (!remote) await chrome.debugger.attach({ tabId }, "1.3");
  } catch (error) {
    const why = String(error?.message || error);
    if (/already attached/i.test(why)) throw new Error("Another debugger has this tab (DevTools, or another extension): close it and try again");
    throw new Error(`Can't use this tab: ${why}`);
  }
  attached.set(tabId, idle(tabId));
  await command(tabId, "Page.enable");
  await command(tabId, "Runtime.enable");
  await command(tabId, "Network.enable", { maxPostDataSize: 0 }).catch(() => {});
  // A tab in a window behind others still renders and takes input.
  await command(tabId, "Emulation.setFocusEmulationEnabled", { enabled: true }).catch(() => {});
  // A size the agent set (browser_resize) outlives the debugger letting go between tools.
  const size = sizes.get(tabId);
  if (size) await command(tabId, "Emulation.setDeviceMetricsOverride", { ...size, deviceScaleFactor: 0, mobile: false }).catch(() => {});
}

const sizes = new Map(); // tabId → { width, height }: the page's size as an agent set it

/** The page laid out at width × height points in its tab, as DevTools' device mode does; none for the tab's own. */
export async function setSize(tabId, size) {
  if (size) sizes.set(tabId, size); else sizes.delete(tabId);
  await attach(tabId);
  if (size) await command(tabId, "Emulation.setDeviceMetricsOverride", { ...size, deviceScaleFactor: 0, mobile: false });
  else await command(tabId, "Emulation.clearDeviceMetricsOverride");
}

export function detach(tabId) {
  clearTimeout(attached.get(tabId));
  attached.delete(tabId);
  if (!remote) chrome.debugger.detach({ tabId }).catch(() => {});
}

export async function send(tabId, method, params = {}) {
  await attach(tabId);
  const open = dialogs.get(tabId);
  if (open && method !== "Page.handleJavaScriptDialog") {
    throw new Error(`The page has ${open.type === "alert" ? "an" : "a"} ${open.type} open: “${open.message}”. Answer it with browser_dialog first`);
  }
  try {
    return await command(tabId, method, params);
  } catch (error) {
    // Detached under us (the tab navigated to another process): once more, attached again.
    if (/not attached|detached/i.test(String(error?.message))) {
      attached.delete(tabId);
      await attach(tabId);
      return command(tabId, method, params);
    }
    throw error;
  }
}

export function dialog(tabId) { return dialogs.get(tabId) }

if (!remote) chrome.debugger.onDetach.addListener(({ tabId }) => { clearTimeout(attached.get(tabId)); attached.delete(tabId); dialogs.delete(tabId) });
chrome.tabs.onRemoved.addListener((tabId) => { attached.delete(tabId); logs.delete(tabId); dialogs.delete(tabId); sizes.delete(tabId); marked.delete(tabId) });

if (!remote) chrome.debugger.onEvent.addListener(({ tabId }, method, params) => event(tabId, method, params));

/** One of the debugger's events on a tab: Chrome's own, or Firefox's as Zero passes them on. */
export function event(tabId, method, params) {
  if (!tabId) return;
  if (method === "Page.screencastFrame") {
    command(tabId, "Page.screencastFrameAck", { sessionId: params.sessionId }).catch(() => {});
    frameListeners.get(tabId)?.(params.data, params.metadata);
  } else if (method === "Page.javascriptDialogOpening") { dialogs.set(tabId, { type: params.type, message: params.message }); alerted(tabId, true) }
  else if (method === "Page.javascriptDialogClosed") { dialogs.delete(tabId); alerted(tabId, false) }
  else if (method === "Page.frameNavigated" && !params.frame.parentId) {
    // Logs are a site's (its subdomains alike: app.example.com and example.com): another site starts them afresh.
    const host = site(params.frame.url);
    const kept = log(tabId);
    if (kept.host !== host) { kept.host = host; kept.console = []; kept.network = new Map() }
  } else if (method === "Runtime.consoleAPICalled") {
    const text = params.args.map((a) => a.value ?? a.description ?? a.unserializableValue ?? a.type).join(" ");
    push(log(tabId).console, { level: params.type, text, at: params.timestamp });
  } else if (method === "Runtime.exceptionThrown") {
    const d = params.exceptionDetails;
    push(log(tabId).console, { level: "exception", text: d.exception?.description || d.text, at: params.timestamp });
  } else if (method === "Network.requestWillBeSent") {
    const network = log(tabId).network;
    network.set(params.requestId, { method: params.request.method, url: params.request.url, type: params.type, status: null });
    if (network.size > LOG_LIMIT) network.delete(network.keys().next().value);
  } else if (method === "Network.responseReceived") {
    const request = log(tabId).network.get(params.requestId);
    if (request) request.status = params.response.status;
  } else if (method === "Network.loadingFailed") {
    const request = log(tabId).network.get(params.requestId);
    if (request) request.status = params.canceled ? "canceled" : `failed: ${params.errorText}`;
  }
}

/** A URL's site: its host's last two labels (three where the second-last is short, as in example.co.uk). */
function site(url) {
  let host;
  try { host = new URL(url).hostname } catch { return "" }
  const labels = host.split(".");
  const keep = labels.length > 2 && labels[labels.length - 2].length <= 3 && labels[labels.length - 1].length === 2 ? 3 : 2;
  return labels.slice(-keep).join(".");
}

function push(list, entry) {
  list.push(entry);
  if (list.length > LOG_LIMIT) list.shift();
}

export function consoleOf(tabId) { return log(tabId).console }
export function networkOf(tabId) { return log(tabId).network }
