#!/usr/bin/env bash
#
# Toggle the amux sidebar pane on/off.
# Called by the tmux keybinding, the client-session-changed hook,
# and the after-new-window hook.
#
# Sidebar panes are identified by their title ("amux") set via select-pane -T.
# Layout is stored per-window using window-level tmux options (-w).
# Global @amux-enabled controls whether hooks are active.
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

# Find the amux sidebar pane in a given target (defaults to current window).
# Returns the pane ID or empty string if not found.
find_amux_pane() {
    local target="${1:-}"
    if [ -n "$target" ]; then
        tmux list-panes -t "$target" -F '#{pane_id} #{pane_title}' 2>/dev/null \
            | awk '$2 == "amux" { print $1; exit }'
    else
        tmux list-panes -F '#{pane_id} #{pane_title}' 2>/dev/null \
            | awk '$2 == "amux" { print $1; exit }'
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
    tmux select-pane -t "$pane_id" -T "amux"
    # Refocus the original pane (the split steals focus)
    tmux last-pane
}

# --- Recreate mode: called by hook on session switch ---
if [ "$1" = "recreate" ]; then
    ENABLED=$(tmux show-option -gqv @amux-enabled)
    if [ "$ENABLED" != "on" ]; then
        exit 0
    fi

    # Kill ALL amux panes across all windows in all sessions
    # (the old session's windows may have sidebars that need cleaning up)
    for pane in $(tmux list-panes -a -F '#{pane_id} #{pane_title}' 2>/dev/null \
                  | awk '$2 == "amux" { print $1 }'); do
        # Restore that pane's window layout before killing it
        local_window=$(tmux display-message -t "$pane" -p '#{window_id}' 2>/dev/null)
        local_layout=$(tmux show-option -wqv -t "$pane" @amux-saved-layout 2>/dev/null)
        tmux kill-pane -t "$pane" 2>/dev/null
        if [ -n "$local_window" ] && [ -n "$local_layout" ]; then
            tmux select-layout -t "$local_window" "$local_layout" 2>/dev/null
        fi
    done

    # Create sidebar in the current window of the new session
    create_sidebar
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
    fi
    exit 0
fi

# --- Toggle mode: called by keybinding ---
EXISTING=$(find_amux_pane)

if [ -n "$EXISTING" ]; then
    # Sidebar exists in current window — kill it and restore layout
    SAVED_LAYOUT=$(tmux show-option -wqv @amux-saved-layout)
    tmux kill-pane -t "$EXISTING"

    if [ -n "$SAVED_LAYOUT" ]; then
        tmux select-layout "$SAVED_LAYOUT"
    fi
    tmux set-option -wu @amux-saved-layout

    # Check if any amux panes remain anywhere
    REMAINING=$(tmux list-panes -a -F '#{pane_title}' 2>/dev/null | grep -c '^amux$')
    if [ "$REMAINING" -eq 0 ]; then
        # Last sidebar closed — disable globally
        tmux set-option -g @amux-enabled "off"
        tmux set-hook -gu client-session-changed
        tmux set-hook -gu after-new-window
    fi
else
    # Sidebar not visible in current window — create it
    if [ ! -f "$AMUX_BIN" ]; then
        tmux display-message "amux: binary not found. Run 'zig build --release=fast' in the plugin directory."
        exit 1
    fi

    create_sidebar

    # Enable globally if not already
    ENABLED=$(tmux show-option -gqv @amux-enabled)
    if [ "$ENABLED" != "on" ]; then
        tmux set-option -g @amux-enabled "on"
        tmux set-hook -g client-session-changed "run-shell '${CURRENT_DIR}/toggle.sh recreate'"
        tmux set-hook -g after-new-window "run-shell '${CURRENT_DIR}/toggle.sh new-window'"
    fi
fi
