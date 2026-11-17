#!/bin/bash
# The Chromium Zero Browser runs on: CEF's minimal arm64 build, one pinned version, checked against its SHA-256 before
# it's unpacked. Unpacked in build/ (`cef` points at it), with libcef_dll_wrapper built beside it. Needs cmake and ninja.
# A new version: change VERSION and SHA256 together (the hash is on cef-builds.spotifycdn.com/index.html).
set -euo pipefail
cd "$(dirname "$0")"
VERSION="156.0.30+g6028375+chromium-156.0.8078.96"
SHA256=731b599e78c71bf33530d65bfa18963f7d1d59902c1f381f5452188e5116b855
NAME="cef_binary_${VERSION}_macosarm64_minimal"
DIR="build/$NAME"
if [ ! -d "$DIR/Release" ]; then
  mkdir -p build
  archive="build/$NAME.tar.bz2"
  [ -f "$archive" ] || curl -fL --proto =https -o "$archive" "https://cef-builds.spotifycdn.com/${NAME//+/%2B}.tar.bz2"
  echo "$SHA256  $archive" | shasum -a 256 -c - >/dev/null || { echo "$archive: wrong SHA-256" >&2; rm -f "$archive"; exit 1; }
  tar -xjf "$archive" -C build
fi
ln -sfn "$DIR" cef
if [ "$(cat build/wrapper/.cef 2>/dev/null)" != "$NAME" ]; then
  rm -rf build/wrapper
  cmake -S cef -B build/wrapper -G Ninja -DCMAKE_BUILD_TYPE=Release -DPROJECT_ARCH=arm64 >/dev/null
  ninja -C build/wrapper libcef_dll_wrapper >/dev/null
  echo "$NAME" > build/wrapper/.cef
fi
echo "CEF $VERSION in $DIR"
