#!/usr/bin/env bash
#
# TPM entry point for amux.
# This file is sourced by TPM on tmux start.
#

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$CURRENT_DIR/zig-out/bin/amux"

# Auto-build if binary doesn't exist
if [ ! -f "$BIN" ]; then
    if command -v zig &>/dev/null; then
        tmux display-message "amux: building..."
        (cd "$CURRENT_DIR" && zig build --release=fast 2>/dev/null)
        if [ $? -eq 0 ]; then
            tmux display-message "amux: build complete"
        else
            tmux display-message "amux: build failed — run 'zig build' manually"
        fi
    else
        tmux display-message "amux: zig not found — install zig 0.15+"
    fi
fi

# Register toggle keybinding
AMUX_KEY=$(tmux show-option -gqv @amux-key)
AMUX_KEY=${AMUX_KEY:-S}

tmux bind-key "$AMUX_KEY" run-shell "$CURRENT_DIR/scripts/toggle.sh"

# Restore sidebar if it was enabled before tmux restart (works with tmux-resurrect)
ENABLED=$(tmux show-option -gqv @amux-enabled)
if [ "$ENABLED" = "on" ] && [ -f "$BIN" ]; then
    "$CURRENT_DIR/scripts/toggle.sh"
fi
