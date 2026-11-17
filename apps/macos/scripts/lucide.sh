#!/bin/sh
# Regenerates Resources/lucide from lucide.txt: for each of Zero's labels, Lucide's icon saved as <label>-outline.svg
# (a glyph asked for falls back to the outline), its stroke as thin as Nucleo's. Lucide comes from npm, unpacked in a
# scratch folder: nothing installed.
# Run from anywhere: sh apps/macos/scripts/lucide.sh
set -eu
version=1.72.0
here=$(cd "$(dirname "$0")" && pwd)
out="$here/../Resources/lucide"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
(cd "$scratch" && npm pack --silent "lucide-static@$version" >/dev/null && tar -xzf lucide-static-*.tgz)
rm -rf "$out" && mkdir -p "$out"
grep -v '^#' "$here/lucide.txt" | while read -r label lucide _; do
    # At 1.333 on Lucide's 24 point grid, the 1 on 18 Nucleo's draw at (CoreSVG doesn't read their var()).
    [ -z "$label" ] || sed 's/stroke-width="2"/stroke-width="1.333"/' "$scratch/package/icons/$lucide.svg" > "$out/$label-outline.svg"
done
echo "$(ls "$out" | wc -l | tr -d ' ') icons from lucide-static $version in Resources/lucide"
