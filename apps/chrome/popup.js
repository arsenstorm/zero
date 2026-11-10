// The toolbar's popup: whether Zero is connected, and the user's tab given to a task (or taken back). The task is told.

import { share, sharedWith } from "./tabs.js";

const ask = (op, fields = {}) =>
  chrome.runtime.sendMessage({ type: "zero-ask", op, fields }).then((r) => {
    if (!r?.ok) throw new Error(r?.error);
    return r.result;
  });

async function draw() {
  const { connected } = await chrome.runtime.sendMessage({
    type: "zero-status",
  });
  const state = document.getElementById("state");
  state.textContent = connected ? "Connected" : "Not connected";
  state.className = "state " + (connected ? "on" : "off");
  const about = document.getElementById("about");
  if (!connected) {
    about.textContent =
      "Open Zero, and turn the browser on in Settings › Agents.";
    return;
  }
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab || !/^https?:/.test(tab.url || "")) {
    about.textContent =
      "Agents use their own tabs. Open a web page to give one to a task.";
    return;
  }
  const given = await sharedWith(tab.id);
  const rows = (await ask("board")).filter(
    (row) => row.online || row.state !== "offline"
  );
  about.textContent = given
    ? "A task can use this tab. Pick it again to take the tab back."
    : "A task you pick can use this tab, and is told so.";
  document.getElementById("heading").hidden = false;
  const list = document.getElementById("tasks");
  list.replaceChildren(
    ...rows.map((row) => {
      const button = document.createElement("button");
      button.className = "task";
      button.innerHTML = `<span class="title"></span>${row.session === given ? '<span class="tick">✓</span>' : ""}`;
      button.querySelector(".title").textContent = row.task;
      button.addEventListener("click", async () => {
        if (row.session === given) {
          await share(tab.id, null);
        } else {
          await share(tab.id, row.session);
          await ask("notify", {
            session: row.session,
            text: `The user gave you a Chrome tab to use: ${tab.title} (${tab.url}), tab ${tab.id}. Use it with the browser_ tools; browser_tab_close gives it back.`,
          }).catch(() => {});
        }
        window.close();
      });
      return button;
    })
  );
  if (!rows.length) about.textContent = "No tasks are open in Zero.";
}

draw();
