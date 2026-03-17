#!/usr/bin/env bash
#
# Toggle the amux sidebar pane on/off.
# Called by the tmux keybinding, the client-session-changed hook,
# and the after-new-window hook.
#
# Sidebar panes are tracked per-window via @amux-pane-id (window option).
# Layout is stored per-window via @amux-saved-layout (window option).
# Global @amux-enabled controls whether hooks are active.
#

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/log.sh"
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

# Find the amux sidebar pane in the current window.
# Reads the per-window @amux-pane-id option and verifies the pane still exists.
# Returns the pane ID or empty string.
find_amux_pane() {
    local pane_id
    pane_id=$(tmux show-option -wqv @amux-pane-id)
    if [ -n "$pane_id" ] && tmux list-panes -F '#{pane_id}' 2>/dev/null | grep -q "^${pane_id}$"; then
        echo "$pane_id"
    fi
}

# Create a sidebar in the current window.
create_sidebar() {
    # Save layout before splitting so we can restore on close
    local layout
    layout=$(tmux display-message -p '#{window_layout}')
    tmux set-option -w @amux-saved-layout "$layout"

    local pane_id
    pane_id=$(tmux split-window $SPLIT_FLAGS '#{pane_id}' -l "$AMUX_WIDTH" "$WRAPPER $AMUX_BIN")
    # Track this pane in a per-window option (atomic, no race)
    tmux set-option -w @amux-pane-id "$pane_id"
    # Refocus the original pane (the split steals focus)
    tmux last-pane
}

# Check if any window in any session has an amux sidebar.
any_amux_panes() {
    # Iterate all windows and check their @amux-pane-id option
    tmux list-windows -a -F '#{window_id}' 2>/dev/null | while read -r win_id; do
        local pid
        pid=$(tmux show-option -wqv -t "$win_id" @amux-pane-id 2>/dev/null)
        if [ -n "$pid" ] && tmux list-panes -t "$win_id" -F '#{pane_id}' 2>/dev/null | grep -q "^${pid}$"; then
            echo "found"
            return
        fi
    done
}

# --- Recreate mode: called by hook on session switch ---
if [ "$1" = "recreate" ]; then
    ENABLED=$(tmux show-option -gqv @amux-enabled)
    if [ "$ENABLED" != "on" ]; then
        exit 0
    fi

    # Kill amux panes in all windows by checking per-window @amux-pane-id
    tmux list-windows -a -F '#{window_id}' 2>/dev/null | while read -r win_id; do
        pid=$(tmux show-option -wqv -t "$win_id" @amux-pane-id 2>/dev/null)
        if [ -n "$pid" ]; then
            local_layout=$(tmux show-option -wqv -t "$win_id" @amux-saved-layout 2>/dev/null)
            tmux kill-pane -t "$pid" 2>/dev/null
            if [ -n "$local_layout" ]; then
                tmux select-layout -t "$win_id" "$local_layout" 2>/dev/null
            fi
            tmux set-option -wu -t "$win_id" @amux-pane-id 2>/dev/null
            tmux set-option -wu -t "$win_id" @amux-saved-layout 2>/dev/null
        fi
    done

    # Create sidebar in the current window of the new session
    create_sidebar
    amux_log "recreate session=$(tmux display-message -p '#S') window=$(tmux display-message -p '#{window_id}')"
    exit 0
fi

# --- New window mode: called by after-new-window hook ---
if [ "$1" = "new-window" ]; then
    ENABLED=$(tmux show-option -gqv @amux-enabled)
    if [ "$ENABLED" != "on" ]; then
        exit 0
    fi

    # Only create if the new window doesn't already have a sidebar
    EXISTING=$(find_amux_pane)
    if [ -z "$EXISTING" ]; then
        create_sidebar
        amux_log "new-window window=$(tmux display-message -p '#{window_id}')"
    fi
    exit 0
fi

# --- Toggle mode: called by keybinding ---
EXISTING=$(find_amux_pane)

if [ -n "$EXISTING" ]; then
    # Sidebar exists in current window — kill it and restore layout
    amux_log "toggle off window=$(tmux display-message -p '#{window_id}') pane=$EXISTING"
    SAVED_LAYOUT=$(tmux show-option -wqv @amux-saved-layout)
    tmux kill-pane -t "$EXISTING"

    if [ -n "$SAVED_LAYOUT" ]; then
        tmux select-layout "$SAVED_LAYOUT"
    fi
    tmux set-option -wu @amux-pane-id
    tmux set-option -wu @amux-saved-layout

    # Check if any amux panes remain anywhere
    if [ -z "$(any_amux_panes)" ]; then
        # Last sidebar closed — disable globally
        tmux set-option -g @amux-enabled "off"
        tmux set-hook -gu client-session-changed
        tmux set-hook -gu after-new-window
    fi
else
    # Sidebar not visible in current window — create it
    if [ ! -f "$AMUX_BIN" ]; then
        amux_log_err "binary not found at $AMUX_BIN"
        tmux display-message "amux: binary not found. Run 'zig build --release=fast' in the plugin directory."
        exit 1
    fi

    create_sidebar
    amux_log "toggle on window=$(tmux display-message -p '#{window_id}')"

    # Enable globally if not already
    ENABLED=$(tmux show-option -gqv @amux-enabled)
    if [ "$ENABLED" != "on" ]; then
        tmux set-option -g @amux-enabled "on"
        tmux set-hook -g client-session-changed "run-shell '${CURRENT_DIR}/toggle.sh recreate'"
        tmux set-hook -g after-new-window "run-shell '${CURRENT_DIR}/toggle.sh new-window'"
    fi
fi
