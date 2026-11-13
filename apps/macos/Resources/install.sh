#!/bin/sh
# Installs the Zero.app at $1 over /Applications/Zero.app: the app quits and opens again where the user was. With
# "restart" as $2, zerod restarts gracefully as the new build: turns under way pause between steps (a running command
# finishes first), the new zerod takes over and they carry on. `make install` and the app's updater both use it.
new=$1
restart=$2
app=/Applications/Zero.app

pid=$(ps -axo pid=,comm= | awk -v exe="$app/Contents/MacOS/Zero" '$2 == exe {print $1}')
[ -z "$pid" ] || kill "$pid"
for _ in $(seq 1 50); do [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1 || break; sleep 0.1; done
rm -rf "$app"
cp -R "$new" "$app"
mkdir -p "$HOME/.local/bin" && ln -sf "$app/Contents/MacOS/zero-cli" "$HOME/.local/bin/zero"
if [ "$restart" = restart ] && printf '{"op":"restart"}\n' | nc -U "$HOME/.zero/zerod.sock" 2>/dev/null | grep -q restarting; then
	echo "zerod: restarting as the new build, the agents running on through it"
fi
open -g "$app" --args --restore
