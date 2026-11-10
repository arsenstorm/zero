// While a task uses this tab: a soft border round the page and a pill naming the task, with Stop, which interrupts the
// task. Hidden while a screenshot is taken.

(() => {
  if (globalThis.__zeroIndicator) return;
  globalThis.__zeroIndicator = true;
  let host = null,
    shadow = null,
    hiddenForShot = false,
    name = null;

  function build() {
    host = document.createElement("zero-indicator");
    host.style.cssText =
      "all: initial; position: fixed; inset: 0; pointer-events: none; z-index: 2147483647;";
    shadow = host.attachShadow({ mode: "closed" });
    shadow.innerHTML = `
      <style>
        .border { position: fixed; inset: 0; box-shadow: inset 0 0 0 2px rgba(249, 115, 22, .9), inset 0 0 24px 4px rgba(249, 115, 22, .35); border-radius: 0; pointer-events: none; }
        .pill { position: fixed; bottom: 16px; left: 50%; transform: translateX(-50%); display: flex; align-items: center; gap: 10px;
                padding: 6px 6px 6px 14px; border-radius: 999px; background: rgba(28, 28, 30, .92); color: #fff; pointer-events: auto;
                font: 500 13px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; box-shadow: 0 6px 24px rgba(0,0,0,.25); }
        .dot { width: 8px; height: 8px; border-radius: 50%; background: #f97316; animation: pulse 1.6s ease-in-out infinite; }
        @keyframes pulse { 50% { opacity: .35 } }
        @media (prefers-reduced-motion: reduce) { .dot { animation: none } }
        .name { max-width: 320px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        button { all: unset; cursor: pointer; padding: 5px 12px; border-radius: 999px; background: #fff; color: #1c1c1e; font-weight: 600; }
        button:hover { background: #e5e5ea; }
      </style>
      <div class="border"></div>
      <div class="pill"><span class="dot"></span><span class="name"></span><button>Stop</button></div>`;
    shadow.querySelector("button").addEventListener("click", () => {
      chrome.runtime.sendMessage({ type: "zero-stop" });
      show(null);
    });
  }

  function show(task) {
    name = task;
    if (!name) {
      host?.remove();
      return;
    }
    if (!host) build();
    shadow.querySelector(".name").textContent = `${name} is using this tab`;
    for (const part of shadow.querySelectorAll(".border, .pill"))
      part.style.display = recording ? "none" : "";
    host.style.display = hiddenForShot ? "none" : "block";
    if (!host.isConnected) document.documentElement.appendChild(host);
  }

  let recording = false;

  // Where a click landed: a ring that grows and fades, for the user and for a recording.
  function ripple(x, y) {
    if (!host) build();
    if (!host.isConnected) document.documentElement.appendChild(host);
    host.style.display = "block";
    for (const part of shadow.querySelectorAll(".border, .pill"))
      part.style.display = recording || !name ? "none" : "";
    const ring = document.createElement("div");
    ring.style.cssText = `position: fixed; left: ${x - 14}px; top: ${y - 14}px; width: 28px; height: 28px; border-radius: 50%;
      border: 3px solid rgba(249, 115, 22, .95); background: rgba(249, 115, 22, .2); pointer-events: none; transition: transform .45s ease-out, opacity .45s ease-out;`;
    shadow.appendChild(ring);
    requestAnimationFrame(() => {
      ring.style.transform = "scale(1.8)";
      ring.style.opacity = "0";
    });
    setTimeout(() => ring.remove(), 600);
  }

  // While recording: a pointer that glides to where the agent acts, so the video reads as someone using the page.
  let cursor = null;
  function glide(x, y) {
    if (!host) build();
    if (!host.isConnected) document.documentElement.appendChild(host);
    host.style.display = "block";
    for (const part of shadow.querySelectorAll(".border, .pill"))
      part.style.display = recording || !name ? "none" : "";
    if (!cursor) {
      cursor = document.createElement("div");
      cursor.innerHTML = `<svg width="22" height="26" viewBox="0 0 22 26"><path d="M2 2 L2 21 L7.2 16.6 L10.6 24 L14 22.4 L10.7 15.2 L17.6 15.2 Z" fill="#111" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/></svg>`;
      cursor.style.cssText = `position: fixed; left: 0; top: 0; width: 22px; height: 26px; pointer-events: none; filter: drop-shadow(0 1px 2px rgba(0,0,0,.35));
        transform: translate(${innerWidth / 2}px, ${innerHeight / 2}px); transition: transform .38s cubic-bezier(.3, .7, .25, 1);`;
      shadow.appendChild(cursor);
      cursor.getBoundingClientRect();
    }
    cursor.style.transform = `translate(${x - 2}px, ${y - 2}px)`;
  }

  chrome.runtime.onMessage.addListener((message, _, answer) => {
    if (message.type === "zero-cursor") glide(message.x, message.y);
    if (message.type === "zero-recording" && !message.on && cursor) {
      cursor.remove();
      cursor = null;
    }
    if (message.type === "zero-click") ripple(message.x, message.y);
    // While recording, the border and pill stay out of the video; the clicks' ripples stay in.
    if (message.type === "zero-recording") {
      recording = message.on;
      if (shadow)
        for (const part of shadow.querySelectorAll(".border, .pill"))
          part.style.display = recording ? "none" : "";
    }
    if (message.type === "zero-driving") {
      if (typeof message.recording === "boolean") recording = message.recording;
      show(message.name);
    }
    if (message.type === "zero-hide") {
      hiddenForShot = message.hidden;
      if (host) host.style.display = hiddenForShot ? "none" : "block";
      // A frame for the change to be drawn before the screenshot.
      requestAnimationFrame(() => requestAnimationFrame(() => answer(true)));
      return true;
    }
  });
})();
