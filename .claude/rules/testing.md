# Testing

## Requirements

- Every change to `src/` must include tests. No exceptions.
- Run `zig build test` before considering any change complete. All tests must pass with zero leaks.
- Tests live in the same file as the code they test, at the bottom of the file after a `// ---------------------------------------------------------------------------` separator.
- There is no way to run a single test file or single test by name with the current `build.zig` — `zig build test` runs all tests from the root module. Tests are fast, so always run the full suite.

## Test naming

Test names follow the format `"function_name: specific behavior description"`:

```zig
test "parseSessions: malformed line (missing fields) is skipped" { ... }
test "adjustScroll: no change when all sessions fit" { ... }
test "draw: agent_waiting session shows star glyph and accent name" { ... }
```

## libvaxis render testing (no TTY required)

libvaxis has no documented testing API. This pattern was discovered by reading libvaxis's own test suite:

```zig
// 1. Create a Screen (allocates a real cell buffer, no TTY needed)
var screen = try vaxis.Screen.init(testing.allocator, .{
    .cols = 30,
    .rows = 15,
    .x_pixel = 0,
    .y_pixel = 0,
});
defer screen.deinit(testing.allocator);

// 2. Construct a Window as a struct literal (all offsets = 0)
const win: vaxis.Window = .{
    .x_off = 0,
    .y_off = 0,
    .parent_x_off = 0,
    .parent_y_off = 0,
    .width = screen.width,
    .height = screen.height,
    .screen = &screen,
};

// 3. Call your render function
draw(testing.allocator, win, &sessions, selected, current, ...);

// 4. Assert on cells using readCell
const cell = win.readCell(col, row).?;
try testing.expectEqual(theme.accent, cell.style.fg);
try testing.expect(cell.style.bold);

// 5. Check grapheme content
try testing.expectEqualStrings("e", readGrapheme(win, col, row));
```

The `createTestWindow` helper in `render.zig` wraps steps 1-2. Use it for all render tests.

## Allocator usage in tests

- Use `testing.allocator` for tests that free all allocations (it detects leaks).
- Use `ArenaAllocator` wrapping `testing.allocator` for code designed for arena usage (functions that allocate with `allocPrint` and expect the caller to reset the arena). This avoids false leak reports. Example:

```zig
var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
defer arena.deinit();
const result = checkAgentWaiting(arena.allocator(), "some-session");
```

## Test helpers

`render.zig` provides these helpers for constructing test sessions:

- `testSession(name, windows, attached, activity)` — basic session
- `testSessionWithPath(name, windows, attached, activity, path)` — session with a path
- `testSessionWaiting(name, windows, attached, activity)` — session with `agent_waiting = true`
- `testSessionFull(name, windows, attached, activity, path, agent_waiting)` — all fields

`readGrapheme(win, col, row)` extracts the grapheme string from a cell for assertions.
