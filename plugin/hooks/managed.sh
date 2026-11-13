# Sourced by the hooks. A session is Zero's when Zero started it (ZERO_MANAGED=1). Everything else, such as the user
# typing to Claude in a terminal themselves, is left alone. Sets ZERO_CLIENT to the zero to call.
zero_managed() {
  [ "${ZERO_MANAGED:-}" = 1 ] || return 1
  ZERO_CLIENT=$(command -v zero 2>/dev/null || echo "$HOME/.local/bin/zero")
}
