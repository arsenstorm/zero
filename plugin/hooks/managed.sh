# Sourced by the hooks. A session is Zero's when Zero started it (ZERO_MANAGED=1), when Solo runs it as an agent
# (Zero reaches every Solo agent through Solo), or when it runs beside a drop folder (a bench: no one at the
# keyboard, so Zero is the only way to the user). ZERO_MANAGED=0 opts a session out. Everything else, such as
# the user typing to Claude in a terminal themselves, is left alone. Sets ZERO_CLIENT to the zero to call: Zero's own
# CLI when it is on this Mac, so the name stays the same as the agent moves between folders; a drop's client
# only where it isn't (a bench machine).
zero_managed() {
  # Opted out first: nothing else to work out (every prompt and every stop runs this).
  [ "${ZERO_MANAGED:-}" = 0 ] && return 1
  local_client="$HOME/.local/bin/zero"
  ZERO_CLIENT=$(command -v zero 2>/dev/null || echo "$local_client")
  [ "${ZERO_MANAGED:-}" = 1 ] && return 0
  dir=$PWD
  while [ "$dir" != "/" ] && [ -n "$dir" ]; do
    for drop in "$dir"/.zero "$dir"/*/.zero; do
      if [ -x "$drop/zero" ]; then [ -x "$local_client" ] && ZERO_CLIENT="$local_client" || ZERO_CLIENT="$drop/zero"; return 0; fi
    done
    dir=${dir%/*}
  done
  [ "${SOLO_PROCESS_KIND:-}" = agent ] && [ -x "$ZERO_CLIENT" ] && return 0
  return 1
}
