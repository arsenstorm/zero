#!/bin/bash
# build/zero-tools.js: Zero Browser's tools page script. The shim (chrome.* of Zero Browser's making), the extension's
# content scripts as text (for scripting.executeScript's files), then the extension's worker and tools, bundled.
set -euo pipefail
cd "$(dirname "$0")/.."
EXT=../chrome
mkdir -p build
bun build "$EXT/worker.js" --format=iife --target=browser --outfile=build/tools-bundle.js >/dev/null
bun -e '
const fs = require("fs");
const [shim, ext, bundle, out] = process.argv.slice(1);
const files = Object.fromEntries(["page.js", "indicator.js"].map((f) => [f, fs.readFileSync(`${ext}/${f}`, "utf8")]));
// The recorder (offscreen.js) in this page too, with a chrome.* of its own that hears only the recorder messages.
const recorder = `((chrome) => {\n${fs.readFileSync(`${ext}/offscreen.js`, "utf8")}\n})(globalThis.__zeroOffscreenChrome);`;
fs.writeFileSync(out, `${fs.readFileSync(shim, "utf8")}\nglobalThis.__zeroFiles = ${JSON.stringify(files)};\n${recorder}\n${fs.readFileSync(bundle, "utf8")}`);
' tools/shim.js "$EXT" build/tools-bundle.js build/zero-tools.js
echo "built build/zero-tools.js ($(wc -c < build/zero-tools.js | tr -d ' ') bytes)"
