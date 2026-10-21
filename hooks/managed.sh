# Sourced by the hooks. A session is Zero's when Zero started it (ZERO_MANAGED=1), when Solo runs it as an agent
# (Zero reaches every Solo agent through Solo), or when it runs beside a drop folder (a bench: no one at the
# keyboard, so Zero is the only way to Arsen). ZERO_MANAGED=0 opts a session out. Everything else, such as
# Arsen typing to Claude in a terminal himself, is left alone. Sets ZERO_CLIENT to the zero to call.
zero_managed() {
  ZERO_CLIENT=$(command -v zero 2>/dev/null || echo "$HOME/.local/bin/zero")
  [ "${ZERO_MANAGED:-}" = 0 ] && return 1
  [ "${ZERO_MANAGED:-}" = 1 ] && return 0
  dir=$(pwd)
  while [ "$dir" != "/" ]; do
    for drop in "$dir"/.zero "$dir"/*/.zero; do
      if [ -x "$drop/zero" ]; then ZERO_CLIENT="$drop/zero"; return 0; fi
    done
    dir=$(dirname "$dir")
  done
  [ "${SOLO_PROCESS_KIND:-}" = agent ] && [ -x "$ZERO_CLIENT" ] && return 0
  return 1
}
