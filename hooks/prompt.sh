#!/bin/sh
# Who sent this prompt: Arsen at the keyboard, Zero, or a lead briefing a worker. Zero withdraws questions Arsen
# has now answered in the chat, and the agent is told how to treat the turn. Needs Zero's own CLI on this Mac.
. "$(dirname "$0")/managed.sh"
zero_managed || exit 0
client="$HOME/.local/bin/zero"
[ -x "$client" ] || exit 0
"$client" prompt 2>/dev/null
exit 0
