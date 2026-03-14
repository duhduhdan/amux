# amux

Persistent tmux sidebar TUI written in **Zig 0.15.2** using **libvaxis 0.5.1** for terminal rendering. Shows all tmux sessions at a glance with agent-idle signaling for tools like Claude Code and OpenCode.

## Build / test / run

```sh
zig build                    # debug build -> zig-out/bin/amux
zig build --release=fast     # release build
zig build run                # run the sidebar directly
zig build test               # run ALL tests (~88 inline tests)
zig fmt src/                 # format source files
```

## Source layout

```
src/
  main.zig        Vaxis event loop, state machine, filtering, wires modules together
  tmux.zig        Spawn tmux commands, parse session data, Session struct, signal checks
  render.zig      All UI rendering: border, sessions, indicators, scroll, help, theme
  input.zig       Pure key-to-action mapping (vaxis.Key -> Action enum)
scripts/
  toggle.sh       Creates/kills amux pane, session-changed hook, layout save/restore
  run-amux.sh     Wrapper: exit code handling, sessionizer integration
integrations/
  claude/         Claude Code hook (shell script)
  opencode/       OpenCode plugin (JS module)
amux.tmux         TPM entry point, auto-builds binary, registers keybinding
```

## Git workflow

- Use `gh` CLI for all GitHub operations (PRs, merges, releases, issues).
- Branch protection is enabled on `master` — all changes go through PRs.
- Squash merge only (merge commits are disabled).

## Rules

Detailed coding rules are in `.claude/rules/`:

- **code-style.md** — Naming, imports, formatting, visibility, comments, error handling
- **zig.md** — Zig 0.15.2 API differences, libvaxis pitfalls (dangling pointers, background cells, timer threads)
- **testing.md** — Test requirements, libvaxis render testing without TTY, allocator patterns, test helpers
- **architecture.md** — Module responsibilities, signal protocol, race condition pitfalls, shell scripts, CI
- **style.md** — ANSI semantic colors, indicator priority, layout rules, design principles
