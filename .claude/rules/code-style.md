# Code Style

## Formatting

Use `zig fmt`. No additional configuration. The project relies entirely on Zig's canonical formatter.

## Naming conventions

| Element                   | Convention            | Example                                                 |
| ------------------------- | --------------------- | ------------------------------------------------------- |
| Functions                 | `camelCase`           | `findCurrentIndex`, `parseSessions`, `drawBorder`       |
| Variables                 | `snake_case`          | `scroll_offset`, `filter_buf`, `frame_alloc`            |
| Types (struct/enum/union) | `PascalCase`          | `Session`, `Mode`, `Action`, `Event`                    |
| Constants                 | `snake_case`          | `selection_bg`, `max_filter_len`, `refresh_interval_ns` |
| Files                     | single lowercase word | `main.zig`, `tmux.zig`, `render.zig`                    |

Exception: `EXIT_NORMAL`, `EXIT_CREATE` use `SCREAMING_CASE` because they are exit codes communicated to an external shell script.

## Import ordering

Imports go at the top of each file in this order with no blank lines between groups:

1. Standard library (`const std = @import("std");`)
2. External dependencies (`const vaxis = @import("vaxis");`)
3. Local project modules (`const tmux = @import("tmux.zig");`)

Type aliases for frequently-used nested types may follow immediately after imports (see `render.zig`).

## Visibility

Only mark symbols `pub` when used by other modules. Internal helpers, test helpers, and test functions are private.

## Comments and documentation

- Every `pub fn` gets a `///` doc comment (single sentence describing what + constraints).
- Section headers use `// -- Title --` with em-dash delimiters.
- Pitfalls/gotchas use `// NOTE:` prefix.
- Test sections are separated by a full-width `// ---------------------------------------------------------------------------` line.

## Error handling

- **`try`** for propagation in `main()` and functions where failure is terminal.
- **`catch fallback`** for resilience — the sidebar must never crash from a tmux query failure. Example: `tmux.listSessions(alloc) catch &.{}`.
- **Return `bool`** when failure is an expected outcome, not an error (e.g., `switchToLastSession`, `checkAgentWaiting`).
- **Custom error sets** from process exit codes via `switch` on `Term` (see `tmux.zig`).
- **`catch 0`** / **`catch ""`** for parsing fallbacks where a default is safe.
- Fire-and-forget: `tmux.switchSession(...) catch {};` for non-critical side effects.
