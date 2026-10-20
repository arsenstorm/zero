# Sourced by the hooks. A session is Zero's when Zero started it (ZERO_MANAGED=1) or when it runs beside a
# drop folder (a bench: no one at the keyboard, so Zero is the only way to Arsen). Everything else, such as
# Arsen typing to Claude himself, is left alone. Sets ZERO_CLIENT to the zero to call.
zero_managed() {
  ZERO_CLIENT=zero
  [ "${ZERO_MANAGED:-}" = 1 ] && return 0
  dir=$(pwd)
  while [ "$dir" != "/" ]; do
    for drop in "$dir"/.zero "$dir"/*/.zero; do
      if [ -x "$drop/zero" ]; then ZERO_CLIENT="$drop/zero"; return 0; fi
    done
    dir=$(dirname "$dir")
  done
  return 1
}
