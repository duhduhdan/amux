# Architecture

## Module responsibilities

Each source file has a single responsibility. Do not mix concerns across modules.

| Module       | Responsibility                                                                                               | Does NOT do                                  |
| ------------ | ------------------------------------------------------------------------------------------------------------ | -------------------------------------------- |
| `tmux.zig`   | Spawn tmux commands, parse session list, `Session` struct, path helpers, signal file checks                  | Rendering, input handling                    |
| `render.zig` | All UI rendering: border, session rows, indicators, scroll, help text, `adjustScroll`                        | tmux commands, input handling                |
| `input.zig`  | Pure key-to-action mapping. Returns an `Action` enum                                                         | Side effects, state mutation                 |
| `main.zig`   | Vaxis event loop, state management (selected, scroll_offset, mode, filter), wires together tmux/render/input | Direct rendering logic, tmux command details |

## Separation pattern

- `tmux.zig` exposes parsing functions separately from command execution for testability (e.g., `parseSessions` is public and tested independently from `listSessions`).
- `render.zig` exports `maxVisibleRows` and `adjustScroll` so `main.zig` can manage scroll state without duplicating rendering math.
- `input.zig` is a pure function from `vaxis.Key` to `Action`. Adding a new keybinding means adding a case to `mapKey` and a variant to the `Action` enum.

## Agent signal protocol

Integrations communicate with the core amux binary through signal files:

- **Directory**: `$XDG_RUNTIME_DIR/amux/` (fallback: `/tmp/amux-<uid>/`)
- **Signal file**: `<tmux-session-name>.waiting`
- **File present** = agent is idle, waiting for user input
- **File absent** = agent is busy or no agent running
- amux checks this directory every 2 seconds (on each auto-refresh cycle)

### Integration conventions

Each integration lives in `integrations/<tool-name>/` and must:

1. Create the signal directory if it doesn't exist
2. Get the tmux session name via `tmux display-message -p '#S'`
3. Create `<session>.waiting` when the agent finishes its turn
4. Remove `<session>.waiting` when the agent starts processing again
5. Clean up on session end

### Known pitfall: race conditions on idle

Some agent tools fire multiple events in rapid succession when the agent goes idle. For example, OpenCode fires `session.idle` followed by `message.updated` ~95ms later (for the final assistant message being committed). If the clearing event fires too soon after the idle event, the signal file is created and immediately deleted before amux can see it (2-second refresh interval).

**Fix**: Only clear the signal on events that genuinely indicate the agent is working again (e.g., user submitted a new prompt, session status changed to non-idle). Do NOT clear on generic message update events.

## Shell scripts

- `scripts/toggle.sh`: Creates/kills the amux pane, manages the `client-session-changed` hook for session following, saves/restores window layouts via `tmux select-layout`.
- `scripts/run-amux.sh`: Wrapper that catches exit codes from the amux binary (exit 2 = create session via `tmux-sessionizer`) and restarts the sidebar.
- `amux.tmux`: TPM entry point. Auto-builds the binary if missing, registers the toggle keybinding.

State is stored in tmux global options: `@amux-enabled`, `@amux-pane-id`, `@amux-saved-layout`, `@amux-key`, `@amux-width`, `@amux-position`.

## Exit code protocol

The amux binary communicates with the wrapper shell script via exit codes:

- `0` = normal exit (quit)
- `2` = create session (wrapper runs `tmux-sessionizer`, then restarts sidebar)

## CI

GitHub Actions release workflow (`.github/workflows/release.yml`) triggers on `v*` tags. Builds for 4 targets: x86_64-linux, aarch64-linux, x86_64-macos, aarch64-macos. No CI for tests or linting on PRs currently.
