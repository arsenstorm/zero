#!/bin/bash
# Zero Browser.app, into the app at $1 (Contents/Helpers), as $2 (its bundle id) named $3:
# the browser app, CEF, its helpers and the tools page. Signed as Zero's Makefile signs (hardened runtime, inside out,
# never --deep; allow-jit on the Renderer helper only); the app around it is signed after. Builds what it needs first.
set -euo pipefail
cd "$(dirname "$0")"
APP=$1 ID=$2 NAME=$3
SIGN=${SIGN:-$(security find-identity -v -p codesigning | grep -m1 -o '"Developer ID Application[^"]*"' | tr -d '"')}
CS="codesign --force --options runtime ${SIGNFLAGS:-} --sign"
BIN=.build/release
B="$APP/Contents/Helpers/Zero Browser.app"
./cef.sh >/dev/null
swift build -c release 2>&1 | grep -E 'error|Build comp'
./tools/build.sh >/dev/null

plist() { # path id exe name
  cat > "$1" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleExecutable</key><string>$3</string>
<key>CFBundleName</key><string>$4</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.0.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>A website asks to sign you in with a passkey from your phone, which is found over Bluetooth.</string>
</dict></plist>
P
  # In the form Chromium writes it back in when it checks its own signature (ProcessRequirement): otherwise the
  # bytes it hashes differ from the signed file's and it logs errSecCSInfoPlistFailed (-67030).
  plutil -convert xml1 "$1"
}

rm -rf "$B"
mkdir -p "$B/Contents/MacOS" "$B/Contents/Frameworks" "$B/Contents/Resources"
cp "$BIN/ZeroBrowser" "$B/Contents/MacOS/Zero Browser"
# Its name names its Keychain item ("<name> Safe Storage").
plist "$B/Contents/Info.plist" "$ID" "Zero Browser" "$NAME"
cp -R "cef/Release/Chromium Embedded Framework.framework" "$B/Contents/Frameworks/"
cp build/zero-tools.js "$B/Contents/Resources/zero-tools.js"
cp cef/LICENSE.txt "$B/Contents/Resources/CEF LICENSE.txt"
cp cef/CREDITS.html "$B/Contents/Resources/Chromium CREDITS.html"
for v in "" " (GPU)" " (Renderer)" " (Plugin)" " (Alerts)"; do
  h="$B/Contents/Frameworks/Zero Browser Helper$v.app"
  mkdir -p "$h/Contents/MacOS"
  cp "$BIN/ZeroBrowserHelper" "$h/Contents/MacOS/Zero Browser Helper$v"
  plist "$h/Contents/Info.plist" "$ID.$(echo "helper$v" | tr -d ' ()' | tr 'A-Z' 'a-z')" "Zero Browser Helper$v" "Zero Browser Helper$v"
done

F="$B/Contents/Frameworks/Chromium Embedded Framework.framework"
for lib in "$F/Libraries/"*.dylib; do $CS "$SIGN" "$lib" 2>/dev/null; done
$CS "$SIGN" "$F" 2>/dev/null
for v in "" " (GPU)" " (Plugin)" " (Alerts)"; do $CS "$SIGN" "$B/Contents/Frameworks/Zero Browser Helper$v.app" 2>/dev/null; done
$CS "$SIGN" --entitlements ent/Renderer.plist "$B/Contents/Frameworks/Zero Browser Helper (Renderer).app" 2>/dev/null
$CS "$SIGN" "$B" 2>/dev/null
codesign --verify --deep --strict "$B" && echo "Zero Browser ($ID) in $APP"
