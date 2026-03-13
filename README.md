# amux

A persistent sidebar for tmux that shows all your sessions at a glance. Built for workflows with many concurrent projects and agentic coding tools.

Written in Zig with [libvaxis](https://github.com/rockorager/libvaxis). Installable via [TPM](https://github.com/tmux-plugins/tpm).

```
┌─ ⊞ amux  ─────────────┐
│ ●  dotfiles          3│
│    ~/dev/dotfiles     │
│ ✸  opencode          2│
│    website           4│
│ ○  api-server        2│
│    docs              1│
│                       │
│ j/k nav  ↵ sel  / flt │
│ n new  d kill  q quit │
└───────────────────────┘
```

- `●` current session
- `✸` agent waiting for input (accent color, requires [integration](#agent-integrations))
- `○` another client attached

## Requirements

- tmux 3.2+
- [Zig 0.15+](https://ziglang.org/download/) (for building from source — not needed with pre-built binaries)

## Installation

### Via TPM

Add to your `tmux.conf`:

```tmux
set -g @plugin 'duhduhdan/amux'
```

Press `prefix + I` to install. The plugin auto-builds the Zig binary on first load.

### Pre-built binaries (no Zig required)

Clone the repo and download a pre-built binary instead of building from source:

```sh
git clone https://github.com/duhduhdan/amux ~/.tmux/plugins/amux
cd ~/.tmux/plugins/amux
# Download the binary for your platform from:
# https://github.com/duhduhdan/amux/releases
mkdir -p zig-out/bin
tar -xzf amux-v*.tar.gz -C zig-out/bin
```

Add to your `tmux.conf`:

```tmux
run-shell ~/.tmux/plugins/amux/amux.tmux
```

### Build from source

```sh
git clone https://github.com/duhduhdan/amux ~/.tmux/plugins/amux
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

| Key                | Action                          |
| ------------------ | ------------------------------- |
| `prefix + S`       | Toggle sidebar on/off           |
| `j` / `k`          | Move selection down / up        |
| `Enter` / `Right`  | Switch to selected session      |
| `d`                | Kill session (press twice)      |
| `n`                | Create new session (via fzf)    |
| `/`                | Filter sessions by name         |
| `Esc`              | Cancel filter / close sidebar   |
| `q`                | Close sidebar                   |

The sidebar follows you across session switches via a `client-session-changed` hook. The session list auto-refreshes every 2 seconds.

## Configuration

All options are set via tmux global options in your `tmux.conf`:

```tmux
# Toggle keybinding (default: S)
set-option -g @amux-key "S"

# Sidebar width in columns (default: 30)
set-option -g @amux-width "30"

# Sidebar position: left or right (default: left)
set-option -g @amux-position "left"
```

## Agent Integrations

amux can show when an AI agent is idle and waiting for your input. A `✸` indicator appears in accent color next to the session name when the agent is done.

This works via a simple file-based signal protocol. Integrations for Claude Code and OpenCode are included. Any tool that writes `$XDG_RUNTIME_DIR/amux/<session>.waiting` files will work.

### Claude Code

Add the following to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.tmux/plugins/amux/integrations/claude/amux-signal.sh"
          }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "idle_prompt",
        "hooks": [
          {
            "type": "command",
            "command": "~/.tmux/plugins/amux/integrations/claude/amux-signal.sh"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.tmux/plugins/amux/integrations/claude/amux-signal.sh"
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.tmux/plugins/amux/integrations/claude/amux-signal.sh"
          }
        ]
      }
    ]
  }
}
```

Adjust the path if amux is installed elsewhere.

### OpenCode

Symlink the plugin into your global plugins directory (note: the `.js` extension is required):

```sh
ln -s ~/.tmux/plugins/amux/integrations/opencode/amux-signal.js \
      ~/.config/opencode/plugins/amux-signal.js
```

### Signal Protocol

Integrations write signal files to `$XDG_RUNTIME_DIR/amux/`:

- `touch <dir>/<session-name>.waiting` — agent is idle, waiting for input
- `rm <dir>/<session-name>.waiting` — agent is busy or session ended

amux checks this directory every 2 seconds (on each auto-refresh). To add support for another tool, write a hook/plugin that creates and removes these files based on the tool's lifecycle events.

## How it works

1. **Toggle script** (`scripts/toggle.sh`) creates or kills a tmux pane running the amux binary. Saves and restores window layouts so other panes aren't resized.
2. **amux binary** uses libvaxis to render a TUI, querying `tmux list-sessions` on every event and every 2 seconds via a timer thread.
3. **Session switching** runs `tmux switch-client -t <name>`. A `client-session-changed` hook re-creates the sidebar pane in the new session.
4. **New session** (`n` key) exits the binary with code 2. The wrapper script (`scripts/run-amux.sh`) catches this and runs `tmux-sessionizer` for fzf-based directory selection, then restarts.
5. **State** is stored in tmux global options (`@amux-enabled`, `@amux-pane-id`, `@amux-saved-layout`).

## Development

```sh
zig build              # debug build
zig build --release=fast  # release build
zig build test         # run tests (88 tests)
zig build run          # run directly
```

### Project structure

```
src/
  main.zig        Entry point, vaxis event loop, filter logic, scroll management
  tmux.zig        Spawn tmux commands, parse session list, agent signal checks
  render.zig      Sidebar rendering: border, sessions, indicators, scroll, help text
  input.zig       Key-to-action mapping
scripts/
  toggle.sh       Toggle sidebar pane, manage hooks, layout save/restore
  run-amux.sh     Wrapper: exit code handling, sessionizer integration
integrations/
  claude/         Claude Code hook (shell script)
  opencode/       OpenCode plugin (JS module)
amux.tmux         TPM entry point (auto-builds on first load)
```

## License

MIT
