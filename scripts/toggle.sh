#!/usr/bin/env bash
#
# Toggle the amux sidebar pane on/off.
# Called by the tmux keybinding and by the client-session-changed hook.
#

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AMUX_BIN="$CURRENT_DIR/../zig-out/bin/amux"
WRAPPER="$CURRENT_DIR/run-amux.sh"

AMUX_WIDTH=$(tmux show-option -gqv @amux-width)
AMUX_WIDTH=${AMUX_WIDTH:-30}

AMUX_POSITION=$(tmux show-option -gqv @amux-position)
AMUX_POSITION=${AMUX_POSITION:-left}

# Build split-window flags based on position:
#   -h  horizontal split
#   -b  "before" (left side) — omitted for right
#   -f  full-height (span entire window height)
if [ "$AMUX_POSITION" = "right" ]; then
    SPLIT_FLAGS="-hfPF"
else
    SPLIT_FLAGS="-hbfPF"
fi

# --- Recreate mode: called by hook on session switch ---
if [ "$1" = "recreate" ]; then
    ENABLED=$(tmux show-option -gqv @amux-enabled)
    if [ "$ENABLED" != "on" ]; then
        exit 0
    fi

    # Kill the old sidebar pane (from previous session) and restore its window layout
    OLD_PANE=$(tmux show-option -gqv @amux-pane-id)
    OLD_SAVED_LAYOUT=$(tmux show-option -gqv @amux-saved-layout)
    if [ -n "$OLD_PANE" ]; then
        # Get the window the old pane belongs to so we can restore its layout after killing
        OLD_WINDOW=$(tmux display-message -t "$OLD_PANE" -p '#{window_id}' 2>/dev/null)
        tmux kill-pane -t "$OLD_PANE" 2>/dev/null
        # Restore the old window's layout so its panes don't progressively shrink
        if [ -n "$OLD_WINDOW" ] && [ -n "$OLD_SAVED_LAYOUT" ]; then
            tmux select-layout -t "$OLD_WINDOW" "$OLD_SAVED_LAYOUT" 2>/dev/null
        fi
    fi

    # Save the NEW session's layout before splitting, then create new sidebar
    LAYOUT=$(tmux display-message -p '#{window_layout}')
    tmux set-option -g @amux-saved-layout "$LAYOUT"
    PANE_ID=$(tmux split-window $SPLIT_FLAGS '#{pane_id}' -l "$AMUX_WIDTH" "$WRAPPER $AMUX_BIN")
    tmux set-option -g @amux-pane-id "$PANE_ID"
    exit 0
fi

# --- Toggle mode: called by keybinding ---
PANE_ID=$(tmux show-option -gqv @amux-pane-id)

# Check if sidebar pane exists
if [ -n "$PANE_ID" ] && tmux list-panes -a -F '#{pane_id}' | grep -q "^${PANE_ID}$"; then
    # Sidebar is visible — kill it and restore layout
    SAVED_LAYOUT=$(tmux show-option -gqv @amux-saved-layout)
    tmux kill-pane -t "$PANE_ID"

    if [ -n "$SAVED_LAYOUT" ]; then
        tmux select-layout "$SAVED_LAYOUT"
    fi

    tmux set-option -g @amux-pane-id ""
    tmux set-option -g @amux-enabled "off"
    tmux set-option -g @amux-saved-layout ""
    tmux set-hook -gu client-session-changed
else
    # Sidebar is not visible — create it
    if [ ! -f "$AMUX_BIN" ]; then
        tmux display-message "amux: binary not found. Run 'zig build --release=fast' in the plugin directory."
        exit 1
    fi

    # Save layout before splitting so we can restore on close
    LAYOUT=$(tmux display-message -p '#{window_layout}')
    tmux set-option -g @amux-saved-layout "$LAYOUT"

    PANE_ID=$(tmux split-window $SPLIT_FLAGS '#{pane_id}' -l "$AMUX_WIDTH" "$WRAPPER $AMUX_BIN")
    tmux set-option -g @amux-pane-id "$PANE_ID"
    tmux set-option -g @amux-enabled "on"

    # Set hook to re-create sidebar when switching sessions
    tmux set-hook -g client-session-changed "run-shell '${CURRENT_DIR}/toggle.sh recreate'"
fi
