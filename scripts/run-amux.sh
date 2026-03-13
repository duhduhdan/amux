#!/usr/bin/env bash
#
# Wrapper that runs the amux binary inside its pane.
# When the binary exits (q, Enter, Esc), this script cleans up
# and restores the original window layout.
#

AMUX_BIN="$1"
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Path to tmux-sessionizer (from dotfiles)
SESSIONIZER="$HOME/scripts/tmux-sessionizer"
if [ ! -x "$SESSIONIZER" ]; then
    SESSIONIZER="$HOME/.local/bin/tmux-sessionizer"
fi

# Run the sidebar binary in a loop.
# Exit code 0 = normal quit (q/Esc), exit code 2 = create session (n).
while true; do
    "$AMUX_BIN"
    EXIT_CODE=$?

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

# If sidebar is still marked as enabled, the hook didn't handle cleanup.
# Do it ourselves.
ENABLED=$(tmux show-option -gqv @amux-enabled)
if [ "$ENABLED" != "on" ]; then
    # Hook already handled cleanup — just exit.
    exit 0
fi

SAVED_LAYOUT=$(tmux show-option -gqv @amux-saved-layout)

# Binary exited normally. Pane is still alive because this script is still running.
# Clean up state.
tmux set-option -g @amux-pane-id ""
tmux set-option -g @amux-enabled "off"
tmux set-option -g @amux-saved-layout ""
tmux set-hook -gu client-session-changed

# Kill this pane and restore layout via a background tmux command.
# We use run-shell so the select-layout happens after the pane is gone.
PANE_ID=$(tmux display-message -p '#{pane_id}')
tmux run-shell -b "tmux kill-pane -t $PANE_ID 2>/dev/null; tmux select-layout '$SAVED_LAYOUT' 2>/dev/null"
