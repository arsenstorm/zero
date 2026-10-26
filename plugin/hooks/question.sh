#!/bin/sh
# Claude Code is about to show its own question picker (AskUserQuestion) in a session Zero runs: Zero asks Arsen
# instead and hands the answers back. If he is at the keyboard, or Zero can't be reached, the picker shows as usual.
. "$(dirname "$0")/managed.sh"
zero_managed || exit 0
input=$(cat)
session=$(printf '%s' "$input" | sed -n 's/.*"session_id":"\([^"]*\)".*/\1/p')
case "$(cut -d' ' -f1 "$HOME/.zero/presence/$session" 2>/dev/null)" in human) exit 0 ;; esac
printf '%s' "$input" | "$ZERO_CLIENT" question 2>/dev/null
exit 0
