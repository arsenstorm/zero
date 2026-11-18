#!/bin/sh
# Runs a one-off AppKit probe (a .swift or .m file, or a built program) with every window it makes kept off every
# display and activation turned off (probe/Offscreen.m), so nothing shows on the user's screen. Menus, alerts run
# from another process and system prompts (TCC) are not covered: a probe must not open them.
#   apps/macos/scripts/probe.sh probe.swift [args...]
#   apps/macos/scripts/probe.sh ./program [args...]
set -e
here=$(cd "$(dirname "$0")" && pwd)
out="$here/../../../build-dev/probe"
mkdir -p "$out"
lib="$out/libzeroprobe.dylib"
if [ ! -f "$lib" ] || [ "$here/probe/Offscreen.m" -nt "$lib" ]; then
  clang -dynamiclib -fobjc-arc -framework AppKit "$here/probe/Offscreen.m" -o "$lib"
fi
src=$1; shift
case "$src" in
  *.swift) bin="$out/$(basename "$src" .swift)"; swiftc -O "$src" -o "$bin" ;;
  *.m) bin="$out/$(basename "$src" .m)"; clang -fobjc-arc -framework AppKit -framework ApplicationServices "$src" -o "$bin" ;;
  *) bin=$src ;;
esac
DYLD_INSERT_LIBRARIES="$lib" exec "$bin" "$@"
