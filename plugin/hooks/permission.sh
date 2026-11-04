#!/bin/sh
# Claude Code wants permission for a tool call in a session Zero runs, where nobody sees its prompt: Zero asks
# the user and prints Claude Code's decision. If Zero can't be reached or the ask expires, it prints nothing, so
# Claude Code's own permission flow carries on.
. "$(dirname "$0")/managed.sh"
zero_managed || exit 0
"$ZERO_CLIENT" permission 2>/dev/null
exit 0
