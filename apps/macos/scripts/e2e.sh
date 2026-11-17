#!/bin/bash
# Builds Zero Dev, runs its end-to-end checks (DevE2E: Zero Dev drives its own window, never the user's mouse,
# keyboard, browser or Zero, and takes no focus), stops it, and prints the results (build-dev/e2e/results.md).
cd "$(dirname "$0")/../../.."
S=apps/macos/scripts
OUT="$PWD/build-dev/e2e"
"$S/dev.sh" || exit 1
rm -rf "$OUT"; mkdir -p "$OUT"
trap '"$S/dev-run.sh" stop' EXIT INT TERM
"$S/dev-run.sh" start --e2e "$OUT" || exit 1
# The checks take about two minutes; a run that hangs is stopped at ten.
for _ in $(seq 1 1200); do [ -f "$OUT/results.json" ] && break; sleep 0.5; done
sleep 1
if [ -f "$OUT/results.md" ]; then cat "$OUT/results.md"; else echo "no results (hung or crashed):"; tail -5 "$OUT/log.txt" 2>/dev/null; fi
grep -q '"failed":0' "$OUT/results.json" 2>/dev/null
