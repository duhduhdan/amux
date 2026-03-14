# Zig 0.15.2 and libvaxis

## Critical: libvaxis `print()` dangling pointer bug

`win.print()` stores **references** to text grapheme slices in cells, not copies. If the source buffer goes out of scope, cells contain dangling pointers and render garbage.

**Wrong** (stack buffer goes out of scope):

```zig
var buf: [32]u8 = undefined;
const text = std.fmt.bufPrint(&buf, "{d}", .{count}) catch "";
_ = win.print(&.{.{ .text = text }}, .{ .row_offset = row });
// buf is on the stack — cells now point to freed memory
```

**Correct** (arena-allocated, outlives the frame):

```zig
const text = std.fmt.allocPrint(frame_alloc, "{d}", .{count}) catch "";
_ = win.print(&.{.{ .text = text }}, .{ .row_offset = row });
// text lives in the arena, which is reset next frame
```

Always use `allocPrint` with the frame arena allocator for any dynamically formatted text passed to `print`.

## Arena-per-frame pattern

The main event loop uses an `ArenaAllocator` that is reset each frame with `arena.reset(.retain_capacity)`. All session data, formatted strings, and temporary allocations for rendering go through this arena. Never use the GPA directly for per-frame data.

## Background cell rendering

Setting `.style.bg` on a cell does **not** cause the terminal to render the background color unless the cell has content. You must write an explicit space character:

```zig
cell.* = .{
    .char = .{ .grapheme = " ", .width = 1 },
    .style = .{ .bg = theme.selection_bg },
};
```

Just setting `cell.style.bg = some_color` on an empty cell does nothing visible.

## Zig 0.15.2 API differences

Most online Zig examples target 0.13 or 0.14. Key differences in 0.15.2:

- `std.ArrayList` is **unmanaged**: zero-init with `.{}`, pass allocator to every method call (`.append(allocator, item)`, `.toOwnedSlice(allocator)`). There is no `.init(allocator)`.
- `std.process.Child.StdIo` uses **PascalCase**: `.Pipe`, `.Ignore`, `.inherit` does not exist — use `.Inherit`.
- `Term` is `union(enum) { .Exited, .Signal, .Stopped, .Unknown }` — not lowercase.
- `build.zig`: use `b.createModule()` for the root module. The old `b.addExecutable(.{ .root_source_file = ... })` pattern is gone.
- `build.zig.zon`: requires a `.fingerprint` field. Zig suggests one on first build if missing.

## libvaxis Key struct

- `key.codepoint` is `u21` (not optional)
- `key.shifted_codepoint` and `key.base_layout_codepoint` are `?u21`
- Use `key.matches(codepoint, modifiers)` for key comparison

## Auto-refresh timer thread

libvaxis `Loop` supports `tryPostEvent` which is thread-safe (mutex + condition protected). The timer thread calls `std.Thread.sleep()` then `loop.tryPostEvent(.auto_refresh)`. There is no timeout-based poll in libvaxis — you must use a dedicated thread.

Use `std.atomic.Value(bool)` for the quit flag shared between the main thread and timer thread.
