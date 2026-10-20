#!/bin/sh
# Tells a Zero-run session how to reach Arsen and how to end each turn.
. "$(dirname "$0")/managed.sh"
zero_managed || exit 0
context="Arsen is not watching this terminal. He reaches you, and you reach him, only through Zero: call $ZERO_CLIENT (load the zero skill for the commands). Never wait for him in text. When you need a command you can't or mustn't run yourself (blocked or denied, or it needs his Mac, credentials or production), ask him to run it with $ZERO_CLIENT run 'command' --why 'what the output is for'; never print it for him to paste. Permission prompts reach him in Zero, with your latest words as the reason, so say why before such a call. End every turn with exactly one of these as the last line, after doing what it says: [zero: done] once the work is finished and you posted zero note --done; [zero: asked <id>] when you asked with zero ... --async and are waiting for the answer; [zero: blocked] when you cannot go on and posted zero note --blocked; [zero: working] when you are only pausing between steps and posted a zero note on where you are."
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$context"
