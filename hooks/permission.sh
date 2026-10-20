#!/bin/sh
# Claude Code wants permission for a tool call in a session Zero runs, where nobody sees its prompt: ask Arsen
# in Zero instead, and answer Claude Code with what he said. If Zero can't be reached or the ask expires, say
# nothing, so Claude Code's own permission flow carries on.
. "$(dirname "$0")/managed.sh"
zero_managed || exit 0
err=$(mktemp)
"$ZERO_CLIENT" permission >/dev/null 2>"$err"
code=$?
reason=$(sed -n 's/^declined: //p' "$err" | head -1 | sed 's/\\/\\\\/g; s/"/\\"/g')
rm -f "$err"
case $code in
  0) printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}\n' ;;
  2) printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Arsen said no in Zero%s"}}}\n' \
       "${reason:+: $reason}" ;;
esac
exit 0
