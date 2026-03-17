#!/usr/bin/env bash
#
# Shared logging helper for amux shell scripts.
# Source this file to get the amux_log function.
#
# Log location: $XDG_STATE_HOME/amux/amux.log
# Fallback:     ~/.local/state/amux/amux.log
#

AMUX_LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/amux"
AMUX_LOG="$AMUX_LOG_DIR/amux.log"

amux_log() {
    mkdir -p "$AMUX_LOG_DIR" 2>/dev/null
    echo "$(date +%Y-%m-%dT%H:%M:%S) [info] $*" >> "$AMUX_LOG" 2>/dev/null
}

amux_log_err() {
    mkdir -p "$AMUX_LOG_DIR" 2>/dev/null
    echo "$(date +%Y-%m-%dT%H:%M:%S) [error] $*" >> "$AMUX_LOG" 2>/dev/null
}
