#!/usr/bin/env bash
#
# amux signal hook for Claude Code.
#
# Writes/removes signal files so amux knows when an agent is waiting for input.
# Install by adding hook entries to ~/.claude/settings.json pointing to this script.
#
# Events handled:
#   Stop / Notification(idle_prompt) -> create signal (agent idle)
#   UserPromptSubmit / SessionEnd    -> remove signal (agent busy / gone)
#

set -euo pipefail

SIGNAL_DIR="${XDG_RUNTIME_DIR:-/tmp/amux-$(id -u)}/amux"
SESSION=$(tmux display-message -p '#S' 2>/dev/null || true)

# No tmux session — nothing to signal
[ -z "$SESSION" ] && exit 0

mkdir -p "$SIGNAL_DIR"

# Read the hook event name from the JSON on stdin.
# Use jq if available, otherwise fall back to a simple grep.
if command -v jq &>/dev/null; then
    EVENT=$(jq -r '.hook_event_name // empty')
else
    EVENT=$(grep -o '"hook_event_name":"[^"]*"' | head -1 | cut -d'"' -f4)
fi

case "$EVENT" in
    Stop|Notification)
        touch "$SIGNAL_DIR/$SESSION.waiting"
        ;;
    UserPromptSubmit|SessionEnd)
        rm -f "$SIGNAL_DIR/$SESSION.waiting"
        ;;
esac

exit 0
