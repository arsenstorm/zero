#!/bin/sh
# A Zero-run turn may only end on Zero's ending line; otherwise the agent is sent back once to finish properly.
# The ending is the reliable signal: a need parked in prose ("waiting for your go") has none.
. "$(dirname "$0")/managed.sh"
zero_managed || exit 0
input=$(cat)
case "$input" in *'"stop_hook_active":true'*) exit 0 ;; esac # already sent back once: let it stop
# Arsen typed this turn's prompt in the terminal, or a lead runs this worker: neither needs a Zero ending.
session=$(printf '%s' "$input" | sed -n 's/.*"session_id":"\([^"]*\)".*/\1/p')
presence=$(cat "$HOME/.zero/presence/$session" 2>/dev/null)
case "$presence" in human|worker) exit 0 ;; esac
ending='\[zero: (done|asked [A-Za-z0-9]+|blocked|working)\]'
# The input carries the turn's last message; the transcript may not have it written yet when this runs.
last_message=$(printf '%s' "$input" | sed -n 's/.*"last_assistant_message":"\(.*\)".*/\1/p')
if printf '%s' "$last_message" | grep -Eq "$ending"; then exit 0; fi
transcript=$(printf '%s' "$input" | sed -n 's/.*"transcript_path":"\([^"]*\)".*/\1/p')
[ -f "$transcript" ] || exit 0
for wait in 0 1 2; do
  sleep "$wait"
  last=$(tail -n 400 "$transcript" | grep '"type":"assistant"' | tail -n 1)
  if printf '%s' "$last" | grep -Eq "$ending"; then exit 0; fi
done
reason="This turn has no Zero ending. If you need Arsen, ask him now with $ZERO_CLIENT ask or $ZERO_CLIENT approve (use --async if you must end the turn) and end with [zero: asked <id>]. If the work is finished, run $ZERO_CLIENT note --done and end with [zero: done]. If you cannot go on, run $ZERO_CLIENT note --blocked and end with [zero: blocked]. If you are only pausing between steps, end with [zero: working] (a note is optional; post one only when something changed)."
printf '{"decision":"block","reason":"%s"}\n' "$reason"
