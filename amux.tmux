#!/usr/bin/env bash
#
# TPM entry point for amux.
# This file is sourced by TPM on tmux start.
#

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$CURRENT_DIR/zig-out/bin/amux"

# Auto-build if binary is missing or source is newer than the binary
NEEDS_BUILD=false
if [ ! -f "$BIN" ]; then
    NEEDS_BUILD=true
elif [ -n "$(find "$CURRENT_DIR/src" -name '*.zig' -newer "$BIN" 2>/dev/null | head -1)" ]; then
    NEEDS_BUILD=true
fi

if [ "$NEEDS_BUILD" = true ]; then
    if command -v zig &>/dev/null; then
        (cd "$CURRENT_DIR" && zig build --release=fast 2>/dev/null)
    fi
fi

# Only register keybinding and hooks when tmux server is ready.
# On fresh boot /tmp/tmux-UID/ is cleared so the server socket doesn't exist yet.
# TPM sources this file on every tmux start, including before the socket exists.
if tmux has-session 2>/dev/null; then
    AMUX_KEY=$(tmux show-option -gqv @amux-key)
    AMUX_KEY=${AMUX_KEY:-S}

    tmux bind-key "$AMUX_KEY" run-shell "$CURRENT_DIR/scripts/toggle.sh"

    # Restore sidebar if it was enabled before tmux restart (works with tmux-resurrect)
    ENABLED=$(tmux show-option -gqv @amux-enabled)
    if [ "$ENABLED" = "on" ] && [ -f "$BIN" ]; then
        # Re-register hooks (lost on tmux restart)
        tmux set-hook -g client-session-changed "run-shell '$CURRENT_DIR/scripts/toggle.sh recreate'"
        tmux set-hook -g after-new-window "run-shell '$CURRENT_DIR/scripts/toggle.sh new-window'"
        "$CURRENT_DIR/scripts/toggle.sh"
    fi
fi
