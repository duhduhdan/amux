# amux

A persistent sidebar for tmux that shows all your sessions at a glance. Built for workflows with many concurrent projects and agentic coding tools.

Written in Zig with [libvaxis](https://github.com/rockorager/libvaxis). Installable via [TPM](https://github.com/tmux-plugins/tpm).

```
 Sessions
──────────────────────────────

 ●  dotfiles            3
    opencode            2
    website             4
 ○  api-server          2
    docs                1

 j/k nav  enter select
 n new  d kill  q close
```

- `●` current (attached) session
- `○` another client attached

## Requirements

- tmux 3.2+
- [Zig 0.15+](https://ziglang.org/download/) (for building from source)

## Installation

### Via TPM

Add to your `tmux.conf`:

```tmux
set -g @plugin 'your-user/amux'
```

Then press `prefix + I` to install. The plugin auto-builds the Zig binary on first load.

### Manual

```sh
git clone https://github.com/your-user/amux ~/.tmux/plugins/amux
cd ~/.tmux/plugins/amux
zig build --release=fast
```

Add to your `tmux.conf`:

```tmux
run-shell ~/.tmux/plugins/amux/amux.tmux
```

Reload tmux config:

```sh
tmux source-file ~/.tmux.conf
```

## Usage

| Key                     | Action                         |
| ----------------------- | ------------------------------ |
| `prefix + S`            | Toggle sidebar on/off          |
| `j` / `Down`            | Move selection down            |
| `k` / `Up`              | Move selection up              |
| `Enter` / `Right`       | Switch to selected session     |
| `d`                     | Kill session (press twice)     |
| `n`                     | Create new session (via fzf)   |
| `q` / `Esc`             | Close sidebar                  |

The sidebar opens as a narrow pane on the left side of your current window. When you switch sessions via the sidebar, it automatically re-creates itself in the new session (via a `client-session-changed` hook). The session list auto-refreshes every 2 seconds.

## Configuration

All options are set via tmux global options in your `tmux.conf`:

```tmux
# Change the toggle keybinding (default: S)
set -g @amux-key "S"

# Change the sidebar width in columns (default: 30)
set -g @amux-width "30"
```

## How it works

1. **Toggle script** (`scripts/toggle.sh`) creates or kills a narrow tmux pane on the left running the amux binary.
2. **amux binary** (`src/main.zig`) uses libvaxis to render a TUI list of all tmux sessions, querying `tmux list-sessions` on every event and every 2 seconds via a timer thread.
3. **Session switching** runs `tmux switch-client -t <name>`. A `client-session-changed` hook re-creates the sidebar pane in the new session so it follows you.
4. **New session** (`n` key) exits the binary and shells out to `tmux-sessionizer` for fzf-based directory selection, then restarts.
5. **State** is stored in tmux global options (`@amux-enabled`, `@amux-pane-id`).

## Development

```sh
# Build (debug)
zig build

# Build (release)
zig build --release=fast

# Run tests
zig build test

# Run directly (outside of tmux pane toggle)
zig build run
```

### Project structure

```
src/
  main.zig        Entry point, vaxis event loop, timer thread, arena-per-frame refresh
  tmux.zig        Spawn tmux commands, parse session list
  render.zig      ANSI-themed sidebar rendering (border, list, indicators, help)
  input.zig       Key-to-action mapping
scripts/
  toggle.sh       Toggle sidebar pane on/off, manage hooks
  run-amux.sh     Wrapper: handles exit codes, sessionizer integration, cleanup
amux.tmux         TPM entry point
```

### Tests

39 tests across 3 modules:

- **render.zig** (17 tests) — Uses real libvaxis `Screen`/`Window` to verify cell contents, styles, layout, truncation, and edge cases (zero-size window, overflow, pending kill visual).
- **tmux.zig** (11 tests) — Pure parsing of `list-sessions` output, current session name, activity timestamps. No tmux dependency at test time.
- **input.zig** (11 tests) — Key mapping for all bindings, unbound keys, modifier handling.

## Roadmap

### Phase 1 — MVP (done)

- [x] Zig + libvaxis TUI showing all tmux sessions
- [x] j/k navigation, Enter to switch, q to quit
- [x] Current session indicator, activity indicator
- [x] ANSI semantic color scheme (adapts to terminal theme)
- [x] Toggle via `prefix + S`
- [x] Sidebar follows session switches via hook
- [x] TPM integration with auto-build
- [x] Tests for parsing, input, and rendering
- [x] `d` to kill session (with double-press confirmation)
- [x] `n` to create session (via tmux-sessionizer / fzf)
- [x] Auto-refresh via timer thread (2s interval)
- [x] Highlight follows current session on switch

### Phase 2 — Persistence

- [ ] Scroll offset when session list exceeds visible area (currently truncated)
- [ ] Restore sidebar position after tmux-resurrect
- [ ] Handle edge case: sidebar pane killed externally (detect stale `@amux-pane-id`)

### Phase 3 — Polish

- [ ] `/` to fuzzy filter sessions by name
- [ ] Show working directory per session (`#{session_path}`)
- [ ] Show active pane command per session (`#{pane_current_command}`)
- [ ] Right-side placement option (`@amux-position left|right`)
- [ ] Pre-built release binaries (GitHub Actions for linux-x86_64, linux-aarch64, macos-x86_64, macos-aarch64)
- [ ] Mouse click to select/switch session

## License

MIT
