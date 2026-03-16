const vaxis = @import("vaxis");

pub const Action = enum {
    move_up,
    move_down,
    select,
    delete,
    create,
    filter,
    watch,
    quit,
    none,
};

/// Map a vaxis key press to a sidebar action.
pub fn mapKey(key: vaxis.Key) Action {
    // Quit
    if (key.matches('q', .{})) return .quit;
    if (key.matches(vaxis.Key.escape, .{})) return .quit;
    if (key.matches('c', .{ .ctrl = true })) return .quit;

    // Navigation
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) return .move_down;
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) return .move_up;

    // Selection
    if (key.matches(vaxis.Key.enter, .{})) return .select;
    if (key.matches(vaxis.Key.right, .{})) return .select;

    // Delete
    if (key.matches('d', .{})) return .delete;

    // Create
    if (key.matches('n', .{})) return .create;

    // Watch
    if (key.matches('w', .{})) return .watch;

    // Filter
    if (key.matches('/', .{})) return .filter;

    return .none;
}

/// Helper to construct a Key for testing.
fn testKey(codepoint: u21, mods: vaxis.Key.Modifiers) vaxis.Key {
    return .{ .codepoint = codepoint, .mods = mods };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = @import("std").testing;

test "mapKey: j and down arrow map to move_down" {
    try testing.expectEqual(Action.move_down, mapKey(testKey('j', .{})));
    try testing.expectEqual(Action.move_down, mapKey(testKey(vaxis.Key.down, .{})));
}

test "mapKey: k and up arrow map to move_up" {
    try testing.expectEqual(Action.move_up, mapKey(testKey('k', .{})));
    try testing.expectEqual(Action.move_up, mapKey(testKey(vaxis.Key.up, .{})));
}

test "mapKey: enter and right arrow map to select" {
    try testing.expectEqual(Action.select, mapKey(testKey(vaxis.Key.enter, .{})));
    try testing.expectEqual(Action.select, mapKey(testKey(vaxis.Key.right, .{})));
}

test "mapKey: l is unbound" {
    try testing.expectEqual(Action.none, mapKey(testKey('l', .{})));
}

test "mapKey: q and escape map to quit" {
    try testing.expectEqual(Action.quit, mapKey(testKey('q', .{})));
    try testing.expectEqual(Action.quit, mapKey(testKey(vaxis.Key.escape, .{})));
}

test "mapKey: ctrl+c maps to quit" {
    try testing.expectEqual(Action.quit, mapKey(testKey('c', .{ .ctrl = true })));
}

test "mapKey: d maps to delete" {
    try testing.expectEqual(Action.delete, mapKey(testKey('d', .{})));
}

test "mapKey: n maps to create" {
    try testing.expectEqual(Action.create, mapKey(testKey('n', .{})));
}

test "mapKey: w maps to watch" {
    try testing.expectEqual(Action.watch, mapKey(testKey('w', .{})));
}

test "mapKey: / maps to filter" {
    try testing.expectEqual(Action.filter, mapKey(testKey('/', .{})));
}

test "mapKey: unbound key maps to none" {
    try testing.expectEqual(Action.none, mapKey(testKey('x', .{})));
    try testing.expectEqual(Action.none, mapKey(testKey('a', .{})));
    try testing.expectEqual(Action.none, mapKey(testKey(' ', .{})));
}

test "mapKey: modifier without binding maps to none" {
    // ctrl+j should not match plain j
    try testing.expectEqual(Action.none, mapKey(testKey('j', .{ .ctrl = true })));
}
