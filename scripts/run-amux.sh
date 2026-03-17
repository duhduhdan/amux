#!/usr/bin/env bash
#
# Wrapper that runs the amux binary inside its pane.
# When the binary exits (q, Enter, Esc), this script cleans up
# and restores the original window layout.
#

AMUX_BIN="$1"
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/log.sh"

# Path to tmux-sessionizer (from dotfiles)
SESSIONIZER="$HOME/scripts/tmux-sessionizer"
if [ ! -x "$SESSIONIZER" ]; then
    SESSIONIZER="$HOME/.local/bin/tmux-sessionizer"
fi

# Ensure log directory exists for stderr capture
mkdir -p "$AMUX_LOG_DIR" 2>/dev/null

# Log binary identity for debugging
BIN_SIZE=$(wc -c < "$AMUX_BIN" 2>/dev/null | tr -d ' ')
BIN_DATE=$(date -r "$AMUX_BIN" +%Y-%m-%dT%H:%M:%S 2>/dev/null || stat -c %y "$AMUX_BIN" 2>/dev/null | cut -d. -f1)
amux_log "binary path=$AMUX_BIN size=$BIN_SIZE date=$BIN_DATE"

# Run the sidebar binary in a loop.
# Exit code 0 = normal quit (q/Esc), exit code 2 = create session (n).
while true; do
    "$AMUX_BIN" 2>> "$AMUX_LOG"
    EXIT_CODE=$?
    amux_log "binary exited code=$EXIT_CODE"

    if [ "$EXIT_CODE" -eq 2 ] && [ -x "$SESSIONIZER" ]; then
        # User pressed n — run sessionizer (fzf) in this pane.
        # If the user picks a directory, sessionizer creates the session
        # and switches to it. The hook will recreate the sidebar in the
        # new session, so we just need to exit this pane cleanly.
        "$SESSIONIZER"
        SESSIONIZER_EXIT=$?

        if [ "$SESSIONIZER_EXIT" -eq 0 ]; then
            # Sessionizer ran successfully. If it switched sessions, the
            # client-session-changed hook will handle sidebar recreation.
            # We need to check if we're still in the same session — if
            # the user cancelled fzf, just restart the sidebar.
            # Give the hook a moment to fire if a switch happened.
            sleep 0.1
            ENABLED=$(tmux show-option -gqv @amux-enabled)
            if [ "$ENABLED" = "on" ]; then
                # Hook didn't fire (user cancelled fzf or picked existing
                # session we're already in) — restart the sidebar.
                continue
            fi
        fi
        # Hook fired and will handle cleanup, or sessionizer failed — exit.
        break
    else
        # Normal quit — exit the loop.
        break
    fi
done

# If sidebar is still marked as enabled, clean up this window's sidebar.
ENABLED=$(tmux show-option -gqv @amux-enabled)
if [ "$ENABLED" != "on" ]; then
    # Hook already handled cleanup — just exit.
    exit 0
fi

# Restore this window's layout
SAVED_LAYOUT=$(tmux show-option -wqv @amux-saved-layout)
PANE_ID=$(tmux display-message -p '#{pane_id}')

# Clear per-window tracking options
tmux set-option -wu @amux-pane-id
tmux set-option -wu @amux-saved-layout

# Check if any other windows still have amux sidebars
HAS_REMAINING=false
for win_id in $(tmux list-windows -a -F '#{window_id}' 2>/dev/null); do
    pid=$(tmux show-option -wqv -t "$win_id" @amux-pane-id 2>/dev/null)
    if [ -n "$pid" ] && tmux list-panes -t "$win_id" -F '#{pane_id}' 2>/dev/null | grep -q "^${pid}$"; then
        HAS_REMAINING=true
        break
    fi
done

if [ "$HAS_REMAINING" = false ]; then
    # Last sidebar — disable globally
    amux_log "cleanup last_sidebar pane=$PANE_ID disabling_globally"
    tmux set-option -g @amux-enabled "off"
    tmux set-hook -gu client-session-changed
    tmux set-hook -gu after-new-window
else
    amux_log "cleanup pane=$PANE_ID sidebars_remaining"
fi

# Kill this pane and restore layout via a background tmux command.
# We use run-shell so the select-layout happens after the pane is gone.
tmux run-shell -b "tmux kill-pane -t $PANE_ID 2>/dev/null; tmux select-layout '$SAVED_LAYOUT' 2>/dev/null"
