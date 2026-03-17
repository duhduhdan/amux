const std = @import("std");

/// Global log state — opened once at startup, closed on deinit.
var file: ?std.fs.File = null;
var mutex: std.Thread.Mutex = .{};

/// Initialize the logger. Opens (or creates) the log file at
/// $XDG_STATE_HOME/amux/amux.log (fallback: ~/.local/state/amux/amux.log).
/// Silently does nothing if the file cannot be opened.
pub fn init() void {
    const dir_path = getLogDir() orelse return;
    std.fs.makeDirAbsolute(dir_path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return,
    };
    const path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/amux.log", .{dir_path}) catch return;
    file = std.fs.openFileAbsolute(path, .{ .mode = .write_only }) catch |e| switch (e) {
        error.FileNotFound => std.fs.createFileAbsolute(path, .{}) catch return,
        else => return,
    };
    if (file) |f| f.seekFromEnd(0) catch {};
}

/// Close the log file.
pub fn deinit() void {
    mutex.lock();
    defer mutex.unlock();
    if (file) |f| {
        f.close();
        file = null;
    }
}

/// Log an info-level message.
pub fn info(comptime fmt: []const u8, args: anytype) void {
    write("info", fmt, args);
}

/// Log an error-level message.
pub fn err(comptime fmt: []const u8, args: anytype) void {
    write("error", fmt, args);
}

/// Buffer for formatting log lines (protected by mutex).
var fmt_buf: [4096]u8 = undefined;

fn write(level: []const u8, comptime fmt: []const u8, args: anytype) void {
    mutex.lock();
    defer mutex.unlock();
    const f = file orelse return;

    // Timestamp
    const epoch = std.time.timestamp();
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(epoch) };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();

    // Format prefix into buffer
    const prefix = std.fmt.bufPrint(&fmt_buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2} [{s}] ", .{
        yd.year,
        @as(u16, md.month.numeric()),
        @as(u16, md.day_index + 1),
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
        level,
    }) catch return;

    // Format message into remainder of buffer
    const rest = fmt_buf[prefix.len..];
    const msg = std.fmt.bufPrint(rest, fmt ++ "\n", args) catch return;

    // Write prefix + message in one shot
    f.writeAll(fmt_buf[0 .. prefix.len + msg.len]) catch return;
}

/// Resolve the log directory path. Returns a page_allocator-owned string.
fn getLogDir() ?[]const u8 {
    if (std.posix.getenv("XDG_STATE_HOME")) |xsh| {
        return std.fmt.allocPrint(std.heap.page_allocator, "{s}/amux", .{xsh}) catch null;
    }
    if (std.posix.getenv("HOME")) |home| {
        return std.fmt.allocPrint(std.heap.page_allocator, "{s}/.local/state/amux", .{home}) catch null;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "getLogDir: uses XDG_STATE_HOME when set" {
    // getLogDir reads environment variables — we can't override them in tests,
    // but we can verify it returns a non-null value (HOME is always set).
    const dir = getLogDir();
    try testing.expect(dir != null);
    // Should end with /amux
    try testing.expect(std.mem.endsWith(u8, dir.?, "/amux"));
}

test "init and deinit: does not crash" {
    // Integration test — opens a real file.
    // If XDG_STATE_HOME or HOME is set, this creates the log directory.
    init();
    defer deinit();
    // Write a test message
    info("test message key={s}", .{"value"});
    err("test error code={d}", .{42});
}

test "write to closed log: does not crash" {
    // Ensure writing when file is null (not initialized) is safe.
    deinit(); // ensure closed
    info("this should not crash", .{});
    err("this should not crash either", .{});
}
