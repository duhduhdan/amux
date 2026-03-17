const std = @import("std");

/// Mutex protects the shared format buffer from concurrent access
/// (main thread + timer thread could both trigger logging).
var mutex: std.Thread.Mutex = .{};

/// Initialize the logger. No-op — logging writes to stderr which is
/// redirected to the log file by run-amux.sh. This avoids dual file
/// descriptor issues from opening the same file in both shell and binary.
pub fn init() void {}

/// Close the logger. No-op — stderr is managed by the shell.
pub fn deinit() void {}

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

    // Write to stderr (redirected to log file by run-amux.sh)
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
    stderr.writeAll(fmt_buf[0 .. prefix.len + msg.len]) catch return;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "init and deinit: does not crash" {
    init();
    defer deinit();
    info("test message key={s}", .{"value"});
    err("test error code={d}", .{42});
}

test "write without init: does not crash" {
    info("this should not crash", .{});
    err("this should not crash either", .{});
}
