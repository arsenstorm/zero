#!/bin/sh
# Seed corpora from zerod's recorded sessions (tests/fixtures): `./seeds.sh corpus` before `cargo fuzz run`.
# A seed's first byte picks the provider: 0 Claude, 1 Codex, 2 OpenCode.
set -eu
out=$1
here=$(dirname "$0")
mkdir -p "$out/adapters" "$out/transcript" "$out/ending" "$out/ask"
for fixture in "$here"/../tests/fixtures/*.jsonl; do
  name=$(basename "$fixture" .jsonl)
  case $name in claude-*) p=0 ;; codex-*) p=1 ;; *) p=2 ;; esac
  { echo "$p"; cat "$fixture"; } > "$out/transcript/$name"
  { echo "$p"; sed -n 's/^{"in":\(.*\)}$/\1/p' "$fixture"; } > "$out/adapters/$name"
done
printf 'All tests pass.\n\n[zero: done]\n' > "$out/ending/done"
printf 'Ship it?\n[zero: asked abc234]\n' > "$out/ending/asked"
printf -- '- Merge it?**\n| a |\n# h\n[zero: asked]' > "$out/ending/bare"
printf '%s' '{"id":"abc234","kind":"choice","title":"Ship it?","options":["Yes","No…"],"agent":{"name":"a","host":"h","ref":"r"},"createdAt":"2026-10-26T12:00:00Z","expiresAt":"2026-10-26T13:00:00.250+01:00","state":"waiting","choice":1,"blocks":true}' > "$out/ask/choice"
