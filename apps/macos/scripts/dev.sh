#!/bin/bash
# Builds Zero Dev (build-dev/Zero Dev.app): Zero's app and zerod built for testing beside the user's own Zero
# (Swift's ZERO_DEV, zerod's `dev` feature). Its own bundle id (com.arsen.zero.dev), state (~/.zero-dev), Zero
# Browser (com.arsen.zero.dev.browser) and build folders; no Keychain, LaunchAgent, control bar, zero:// links or
# install script; never in /Applications. Signed as the Makefile signs.
set -eu
cd "$(dirname "$0")/../../.."
APP="build-dev/Zero Dev.app"
# Never rebuilt under a running Zero Dev: its processes would find their bundle gone or signed anew mid-run.
if pgrep -f "$PWD/$APP/" >/dev/null; then echo "Zero Dev is running: stop it first (make dev-stop)" >&2; exit 1; fi
SIGN=${SIGN:-$(security find-identity -v -p codesigning | grep -m1 -o '"\(Developer ID Application\|Apple Development\)[^"]*"' | tr -d '"')}
CS="codesign --force --options runtime --sign"
MACOS=apps/macos
ZERO_PRIVATE=${ZERO_PRIVATE:-../zero-private}
if ls $ZERO_PRIVATE/icons/macos/*.svg >/dev/null 2>&1; then ICONS=Nucleo ICONS_DIR=$ZERO_PRIVATE/icons/macos; else ICONS=Lucide ICONS_DIR=$MACOS/Resources/lucide; fi

# Build folders of its own: the shared ones are what `make install` copies into the user's Zero.
export CARGO_TARGET_DIR="$PWD/build-dev/cargo"
SCRATCH="$PWD/build-dev/swift"
cargo build --release -p zerod --features dev 2>&1 | { grep -E "^error|Finished" || true; }; [ "${PIPESTATUS[0]}" = 0 ]
swift build -c release --package-path $MACOS --scratch-path "$SCRATCH" -Xswiftc -DZERO_DEV 2>&1 | { grep -E "error:|Build complete" || true; }; [ "${PIPESTATUS[0]}" = 0 ]
BIN="$SCRATCH/release"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN/ZeroApp" "$APP/Contents/MacOS/Zero"
cp "$BIN/zero" "$APP/Contents/MacOS/zero-cli"
cp "$BIN/zero-full" "$APP/Contents/MacOS/zero-full"
cp "$CARGO_TARGET_DIR/release/zerod" "$APP/Contents/MacOS/zerod"
cp $MACOS/Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.arsen.zero.dev' -c 'Set :CFBundleName Zero Dev' \
  -c 'Add :CFBundleDisplayName string Zero Dev' -c 'Delete :CFBundleURLTypes' -c "Add :ZeroIcons string $ICONS" "$APP/Contents/Info.plist"
cp $MACOS/Resources/icons/*.png "$APP/Contents/Resources/"
(cd $MACOS/Resources && cp AppIcon.icns logo/menubar.png logo/menubar@2x.png logo/mark.svg logo/mark-small.svg "$OLDPWD/$APP/Contents/Resources/")
cp -R "$ICONS_DIR" "$APP/Contents/Resources/icons"
cp /System/Library/Sounds/*.aiff "$APP/Contents/Resources/"
cp -R plugin "$APP/Contents/Resources/plugin"
for b in zero-cli zero-full zerod; do $CS "$SIGN" "$APP/Contents/MacOS/$b" 2>/dev/null; done
# Zero Dev's own Zero Browser: only a dev zerod starts it, it serves only Zero Dev, and its profile is its own.
SIGN="$SIGN" apps/browser/helper.sh "$PWD/$APP" com.arsen.zero.dev.browser "Zero Dev Browser"
$CS "$SIGN" "$APP" 2>/dev/null
codesign --verify --deep --strict "$APP"
echo "built: $APP ($(codesign -dv "$APP" 2>&1 | grep -o 'Identifier=.*' | head -1))"
