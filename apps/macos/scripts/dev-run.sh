#!/bin/bash
# dev-run.sh start [app arguments…] | stop: Zero Dev and its own zerod, apart from the user's Zero. zerod's HOME is
# ~/.zero-dev/home, so its socket, sessions and Claude folders are there; the app keeps its state in ~/.zero-dev.
# Started in the background, without focus. stop ends every process inside build-dev's bundle, and only those.
cd "$(dirname "$0")/../../.."
DEV="$HOME/.zero-dev"
APP="$PWD/build-dev/Zero Dev.app"
stop() {
  pkill -TERM -f "$APP/" 2>/dev/null
  for _ in $(seq 1 20); do pgrep -f "$APP/" >/dev/null || return 0; sleep 0.25; done
  pkill -KILL -f "$APP/" 2>/dev/null
  sleep 0.3
}
case "${1:-start}" in
  stop) stop ;;
  start)
    shift || true
    [ -d "$APP" ] || { echo "no $APP: make dev first" >&2; exit 1; }
    stop
    mkdir -p "$DEV/home"
    Z="$DEV/home/.zero-dev"
    HOME="$DEV/home" nohup "$APP/Contents/MacOS/zerod" >"$DEV/zerod.log" 2>&1 &
    for _ in $(seq 1 40); do [ -S "$Z/zerod.sock" ] && break; sleep 0.25; done
    [ -S "$Z/zerod.sock" ] || { echo "Zero Dev's zerod didn't start: $DEV/zerod.log" >&2; stop; exit 1; }
    open -g -n "$APP" --env ZERO_DAEMON="$Z/zerod.sock" --env ZERO_SOCKET="$Z/zero.sock" --env ZERO_DEV_HOME="$DEV/home" --args "$@"
    echo "Zero Dev started (zerod at $Z/zerod.sock)"
    ;;
esac
