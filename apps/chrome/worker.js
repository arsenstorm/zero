// Zero for Chrome's service worker: the connection to Zero (through the native host, which is zerod), and each call
// a task makes, run by tools.js. An open native port keeps the worker alive; an alarm reconnects it if it ever drops.

import { run, stopped } from "./tools.js";
import { setLight } from "./tabs.js";
import { event, useZero } from "./cdp.js";

/** Which browser this is: Firefox has the extension too, its debugger commands done by Zero. */
const BROWSER = navigator.userAgent.includes("Firefox/") ? "Firefox" : "Chrome";

const HOST = "dev.zero.browser";
let port = null;
let wait = 1000;
let asked = 0;
const replies = new Map();

async function deviceId() {
  const { device } = await chrome.storage.local.get("device");
  if (device) return device;
  const id = BROWSER.toLowerCase() + "-" + crypto.randomUUID().slice(0, 8);
  await chrome.storage.local.set({ device: id });
  return id;
}

async function connect() {
  if (port) return;
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch (error) {
    port = null;
    return retry();
  }
  port.onMessage.addListener(received);
  port.onDisconnect.addListener(() => {
    // Read, so Chrome doesn't report it as unchecked: the host ending is expected (Zero restarting, Chrome reloading us).
    void chrome.runtime.lastError;
    port = null;
    for (const [, { fail }] of replies) fail(new Error("Zero went away"));
    replies.clear();
    retry();
  });
  port.postMessage({
    type: "hello",
    id: await deviceId(),
    name: BROWSER,
    version: chrome.runtime.getManifest().version,
  });
  wait = 1000;
}

function retry() {
  setTimeout(connect, wait);
  wait = Math.min(wait * 2, 30000);
}

async function received(message) {
  if (message.type === "call") {
    const { call, tool, args, task } = message;
    try {
      port?.postMessage({
        type: "answer",
        call,
        result: await run(tool, args || {}, task || {}),
      });
    } catch (error) {
      port?.postMessage({
        type: "answer",
        call,
        error: String(error?.message || error),
      });
    }
  } else if (message.type === "cdp") {
    event(message.tabId, message.method, message.params);
  } else if (message.type === "state") {
    setLight(message.session, message.state).catch(() => {});
  } else if (message.type === "reply") {
    const waiting = replies.get(message.id);
    replies.delete(message.id);
    if (!waiting) return;
    if (message.ok) waiting.done(message.result);
    else waiting.fail(new Error(message.error || "Zero refused"));
  }
}

/** One request to zerod (its socket's ops: board, interrupt, notify…). */
export function ask(op, fields = {}) {
  return new Promise((done, fail) => {
    if (!port) return fail(new Error("Zero isn't connected"));
    const id = ++asked;
    replies.set(id, { done, fail });
    port.postMessage({ type: "request", id, request: { op, ...fields } });
  });
}

useZero(ask);

// From the popup and the page's Stop button.
chrome.runtime.onMessage.addListener((message, sender, answer) => {
  if (message.type === "zero-status") {
    answer({ connected: !!port });
    return;
  }
  if (message.type === "zero-ask") {
    ask(message.op, message.fields).then(
      (result) => answer({ ok: true, result }),
      (error) => answer({ ok: false, error: String(error.message) })
    );
    return true;
  }
  if (message.type === "zero-stop" && sender.tab) {
    stopped(sender.tab.id).then(
      (session) => session && ask("interrupt", { session }).catch(() => {})
    );
  }
});

// An unpacked extension isn't reloaded when its files change: when Zero installs a newer one, it reloads itself.
async function updated() {
  try {
    const onDisk = await (
      await fetch(chrome.runtime.getURL("manifest.json"), { cache: "no-store" })
    ).json();
    if (onDisk.version !== chrome.runtime.getManifest().version)
      chrome.runtime.reload();
  } catch {}
}

chrome.alarms.create("zero-reconnect", { periodInMinutes: 1 });
chrome.alarms.onAlarm.addListener(() => {
  connect();
  updated();
});
chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
connect();
