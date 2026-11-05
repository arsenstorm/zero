// Recordings: each tab's screenshots drawn on a canvas as they come, the canvas recorded as a video (MP4 where
// Chrome makes it, else WebM). Idle time is left out: the recorder runs while the page changes or an action is under
// way, and pauses otherwise, so an agent's thinking between steps leaves no trace. The canvas takes the frames' own
// size, at the screen's pixel density, so text stays sharp and nothing is stretched.

const TAIL = 700; // ms kept after the last change, so what changed can be seen
const recordings = new Map(); // key → recording

function start({ key }) {
  recordings.set(key, { element: null, context: null, recorder: null, chunks: [], mime: null, lastChange: 0, activeUntil: Date.now() + 1000,
                        probe: new OffscreenCanvas(48, 32), previous: null, kept: 0, resumedAt: 0, timer: null });
}

/** How much a frame differs from the last, 0 to 255 on average, at a size where a blinking caret is lost. */
function change(r, bitmap) {
  const probe = r.probe.getContext("2d", { willReadFrequently: true });
  probe.drawImage(bitmap, 0, 0, 48, 32);
  const now = probe.getImageData(0, 0, 48, 32).data;
  const before = r.previous;
  r.previous = now;
  if (!before) return 255;
  let sum = 0;
  for (let i = 0; i < now.length; i += 4) sum += Math.abs(now[i] - before[i]) + Math.abs(now[i + 1] - before[i + 1]) + Math.abs(now[i + 2] - before[i + 2]);
  return sum / (now.length / 4) / 3;
}

function begin(r, width, height) {
  r.element = document.createElement("canvas");
  // Even sides: H.264 wants them.
  r.element.width = width - (width % 2);
  r.element.height = height - (height % 2);
  document.body.appendChild(r.element);
  r.context = r.element.getContext("2d");
  r.mime = ["video/mp4;codecs=avc1.640033", "video/mp4;codecs=avc1.4d0033", "video/mp4", "video/webm;codecs=vp9", "video/webm"].find((m) => MediaRecorder.isTypeSupported(m));
  const pixels = r.element.width * r.element.height;
  r.recorder = new MediaRecorder(r.element.captureStream(30), { mimeType: r.mime, videoBitsPerSecond: Math.min(16_000_000, Math.max(4_000_000, pixels * 3)) });
  r.recorder.ondataavailable = (e) => e.data.size && r.chunks.push(e.data);
  r.recorder.start(1000);
  r.resumedAt = Date.now();
  // Paused once nothing has changed for a while and no action is under way.
  r.timer = setInterval(() => {
    const now = Date.now();
    const busy = now < Math.max(r.lastChange + TAIL, r.activeUntil);
    if (!busy && r.recorder.state === "recording") { r.recorder.pause(); r.kept += now - r.resumedAt }
  }, 100);
}

function wake(r) {
  if (r.recorder?.state === "paused") { r.recorder.resume(); r.resumedAt = Date.now() }
}

async function frame({ key, data, width: wanted, height: tall }) {
  const r = recordings.get(key);
  if (!r) return;
  const bitmap = await createImageBitmap(await (await fetch(`data:image/jpeg;base64,${data}`)).blob());
  if (!r.element) begin(r, Math.min(wanted || bitmap.width, bitmap.width), Math.min(tall || bitmap.height, bitmap.height));
  if (change(r, bitmap) > 0.35) { r.lastChange = Date.now(); wake(r) }
  // The frame as it is, centred, if the page was resized since: never stretched.
  const { width, height } = r.element;
  const scale = Math.min(width / bitmap.width, height / bitmap.height);
  const w = bitmap.width * scale, h = bitmap.height * scale;
  if (w < width || h < height) { r.context.fillStyle = "#000"; r.context.fillRect(0, 0, width, height) }
  r.context.drawImage(bitmap, (width - w) / 2, (height - h) / 2, w, h);
}

/** An action is under way in the tab (a click, typing, a page loading): kept, with a moment after it. */
function active({ key, ms = 900 }) {
  const r = recordings.get(key);
  if (!r) return;
  r.activeUntil = Math.max(r.activeUntil, Date.now() + ms);
  wake(r);
}

function stop({ key }) {
  const r = recordings.get(key);
  if (!r) return Promise.resolve({ error: "No recording" });
  recordings.delete(key);
  clearInterval(r.timer);
  if (!r.recorder) return Promise.resolve({ error: "No frames came: the page didn't draw while it was recorded" });
  if (r.recorder.state === "recording") r.kept += Date.now() - r.resumedAt;
  return new Promise((done) => {
    r.recorder.onstop = async () => {
      r.element.remove();
      const blob = new Blob(r.chunks, { type: r.mime });
      const bytes = new Uint8Array(await blob.arrayBuffer());
      let binary = "";
      for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
      done({ data: btoa(binary), extension: r.mime.startsWith("video/mp4") ? "mp4" : "webm", seconds: Math.max(1, Math.round(r.kept / 1000)),
             width: r.element.width, height: r.element.height });
    };
    // A last look at where it ended.
    wake(r);
    setTimeout(() => r.recorder.stop(), 500);
  });
}

chrome.runtime.onMessage.addListener((message, _, answer) => {
  if (message.target !== "zero-offscreen") return;
  if (message.type === "start") { start(message); answer(true) }
  else if (message.type === "frame") { frame(message).then(() => answer(true), () => answer(false)); return true }
  else if (message.type === "active") active(message);
  else if (message.type === "stop") { stop(message).then(answer); return true }
});
