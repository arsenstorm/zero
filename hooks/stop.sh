#!/bin/sh
# A Zero-run turn may only end on Zero's ending line; otherwise the agent is sent back once to finish properly.
# The ending is the reliable signal: a need parked in prose ("waiting for your go") has none.
. "$(dirname "$0")/managed.sh"
zero_managed || exit 0
input=$(cat)
case "$input" in *'"stop_hook_active":true'*) exit 0 ;; esac # already sent back once: let it stop
transcript=$(printf '%s' "$input" | sed -n 's/.*"transcript_path":"\([^"]*\)".*/\1/p')
[ -f "$transcript" ] || exit 0
last=$(tail -n 400 "$transcript" | grep '"type":"assistant"' | tail -n 1)
if printf '%s' "$last" | grep -Eq '\[zero: (done|asked [A-Za-z0-9]+|blocked|working)\]'; then exit 0; fi
reason="This turn has no Zero ending. If you need Arsen, ask him now with $ZERO_CLIENT ask or $ZERO_CLIENT approve (use --async if you must end the turn) and end with [zero: asked <id>]. If the work is finished, run $ZERO_CLIENT note --done and end with [zero: done]. If you cannot go on, run $ZERO_CLIENT note --blocked and end with [zero: blocked]. If you are pausing between steps, post a $ZERO_CLIENT note and end with [zero: working]."
printf '{"decision":"block","reason":"%s"}\n' "$reason"
