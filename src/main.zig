const std = @import("std");
const vaxis = @import("vaxis");
const tmux = @import("tmux.zig");
const render = @import("render.zig");
const input = @import("input.zig");

/// Auto-reset terminal on panic
pub const panic = vaxis.Panic.call;

/// Find the index of the current session in the list, or 0 if not found.
fn findCurrentIndex(sessions: []const tmux.Session, current: []const u8) usize {
    for (sessions, 0..) |s, i| {
        if (std.mem.eql(u8, s.name, current)) return i;
    }
    return 0;
}

const Mode = enum { normal, filter };

const max_filter_len: usize = 64;

/// Case-insensitive substring match.
fn containsInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    const end = haystack.len - needle.len + 1;
    for (0..end) |i| {
        var match = true;
        for (0..needle.len) |j| {
            if (toLower(haystack[i + j]) != toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// Filter sessions by name, returning indices into the original slice.
fn filterSessions(
    allocator: std.mem.Allocator,
    sessions: []const tmux.Session,
    needle: []const u8,
) []const usize {
    if (needle.len == 0) {
        // Return all indices
        const all = allocator.alloc(usize, sessions.len) catch return &.{};
        for (0..sessions.len) |i| all[i] = i;
        return all;
    }
    var indices: std.ArrayList(usize) = .{};
    for (sessions, 0..) |s, i| {
        if (containsInsensitive(s.name, needle)) {
            indices.append(allocator, i) catch {};
        }
    }
    return indices.toOwnedSlice(allocator) catch &.{};
}

// Tests for filtering helpers
const testing = std.testing;

test "containsInsensitive: basic substring match" {
    try testing.expect(containsInsensitive("dotfiles", "dot"));
    try testing.expect(containsInsensitive("dotfiles", "file"));
    try testing.expect(containsInsensitive("dotfiles", "dotfiles"));
}

test "containsInsensitive: case insensitive" {
    try testing.expect(containsInsensitive("DotFiles", "dotf"));
    try testing.expect(containsInsensitive("dotfiles", "DOT"));
}

test "containsInsensitive: no match" {
    try testing.expect(!containsInsensitive("dotfiles", "xyz"));
    try testing.expect(!containsInsensitive("abc", "abcd"));
}

test "containsInsensitive: empty needle matches anything" {
    try testing.expect(containsInsensitive("dotfiles", ""));
    try testing.expect(containsInsensitive("", ""));
}

test "filterSessions: filters by substring" {
    const sessions = [_]tmux.Session{
        .{ .name = "dotfiles", .windows = 1, .attached = false, .activity = 0, .path = "" },
        .{ .name = "opencode", .windows = 1, .attached = false, .activity = 0, .path = "" },
        .{ .name = "docs", .windows = 1, .attached = false, .activity = 0, .path = "" },
    };
    const indices = filterSessions(testing.allocator, &sessions, "do");
    defer testing.allocator.free(indices);

    try testing.expectEqual(@as(usize, 2), indices.len);
    try testing.expectEqual(@as(usize, 0), indices[0]); // dotfiles
    try testing.expectEqual(@as(usize, 2), indices[1]); // docs
}

test "filterSessions: empty needle returns all" {
    const sessions = [_]tmux.Session{
        .{ .name = "a", .windows = 1, .attached = false, .activity = 0, .path = "" },
        .{ .name = "b", .windows = 1, .attached = false, .activity = 0, .path = "" },
    };
    const indices = filterSessions(testing.allocator, &sessions, "");
    defer testing.allocator.free(indices);

    try testing.expectEqual(@as(usize, 2), indices.len);
}

/// Exit codes used to communicate intent to the wrapper script.
const EXIT_NORMAL: u8 = 0;
const EXIT_CREATE: u8 = 2;

/// Event union — vaxis dispatches to fields matching known names.
/// Custom variants (auto_refresh) are posted from the timer thread.
const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
    auto_refresh,
};

/// Refresh interval for the auto-refresh timer thread.
const refresh_interval_ns: u64 = 2 * std.time.ns_per_s;

/// Timer thread: posts auto_refresh events at a fixed interval until
/// the quit flag is set.
fn refreshTimer(loop: *vaxis.Loop(Event), quit_flag: *std.atomic.Value(bool)) void {
    while (!quit_flag.load(.acquire)) {
        std.Thread.sleep(refresh_interval_ns);
        if (quit_flag.load(.acquire)) break;
        _ = loop.tryPostEvent(.auto_refresh);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Arena for per-frame session data (reset each frame)
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Init TTY
    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(&tty_buf);
    defer tty.deinit();

    // Init Vaxis
    var vx = try vaxis.init(allocator, .{});
    defer vx.deinit(allocator, tty.writer());

    // Init event loop
    var loop: vaxis.Loop(Event) = .{ .tty = &tty, .vaxis = &vx };
    try loop.init();
    try loop.start();
    defer loop.stop();

    // Enter alt screen, query terminal capabilities
    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), 1 * std.time.ns_per_s);

    // Auto-refresh timer thread
    var quit_flag = std.atomic.Value(bool).init(false);
    const refresh_thread = try std.Thread.spawn(.{}, refreshTimer, .{ &loop, &quit_flag });

    // State — initialize selection to the current session
    var selected: usize = 0;
    var pending_kill: ?usize = null;
    var exit_code: u8 = EXIT_NORMAL;
    var mode: Mode = .normal;
    var filter_buf: [max_filter_len]u8 = undefined;
    var filter_len: usize = 0;
    var scroll_offset: usize = 0;

    // Initial render (also sets selected to current session)
    {
        const frame_alloc = arena.allocator();
        var no_sessions: [0]tmux.Session = .{};
        const sessions = tmux.listSessions(frame_alloc) catch no_sessions[0..];
        tmux.markAgentWaiting(frame_alloc, sessions);
        const current = tmux.getCurrentSession(frame_alloc) catch "";

        selected = findCurrentIndex(sessions, current);

        const win = vx.window();
        win.clear();
        // Adjust scroll to show selected session
        const selected_has_path = if (sessions.len > 0 and selected < sessions.len)
            sessions[selected].path.len > 0
        else
            false;
        render.adjustScroll(&scroll_offset, selected, sessions.len, win.height, selected_has_path);
        render.draw(frame_alloc, win, sessions, selected, current, pending_kill, null, scroll_offset);
        try vx.render(tty.writer());
    }

    // Main event loop
    while (true) {
        const event = loop.nextEvent();

        // Handle event
        var should_quit = false;
        switch (event) {
            .key_press => |key| {
                switch (mode) {
                    .filter => {
                        // In filter mode: handle text input directly
                        if (key.matches(vaxis.Key.escape, .{}) or key.matches('c', .{ .ctrl = true })) {
                            // Cancel filter, return to normal mode
                            mode = .normal;
                            filter_len = 0;
                            selected = 0;
                            scroll_offset = 0;
                        } else if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.right, .{})) {
                            // Select the highlighted session from filtered results
                            _ = arena.reset(.retain_capacity);
                            const frame_alloc = arena.allocator();
                            const sessions = tmux.listSessions(frame_alloc) catch &.{};
                            const indices = filterSessions(frame_alloc, sessions, filter_buf[0..filter_len]);
                            if (indices.len > 0 and selected < indices.len) {
                                tmux.switchSession(sessions[indices[selected]].name) catch {};
                            }
                            mode = .normal;
                            filter_len = 0;
                            selected = 0;
                            scroll_offset = 0;
                        } else if (key.matches(vaxis.Key.backspace, .{})) {
                            if (filter_len > 0) {
                                filter_len -= 1;
                                selected = 0;
                            } else {
                                // Empty filter + backspace = exit filter mode
                                mode = .normal;
                            }
                        } else if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
                            selected += 1; // clamped below
                        } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
                            if (selected > 0) selected -= 1;
                        } else {
                            // Printable ASCII character → append to filter
                            const cp = key.codepoint;
                            if (cp >= 0x20 and cp < 0x7F and filter_len < max_filter_len) {
                                filter_buf[filter_len] = @intCast(cp);
                                filter_len += 1;
                                selected = 0; // reset to top of filtered results
                            }
                        }
                    },
                    .normal => {
                        const action = input.mapKey(key);
                        switch (action) {
                            .quit => {
                                should_quit = true;
                            },
                            .move_up => {
                                pending_kill = null;
                                if (selected > 0) selected -= 1;
                            },
                            .move_down => {
                                pending_kill = null;
                                selected += 1; // clamped below after refresh
                            },
                            .select => {
                                pending_kill = null;
                                _ = arena.reset(.retain_capacity);
                                const frame_alloc = arena.allocator();
                                const sessions = tmux.listSessions(frame_alloc) catch &.{};
                                if (sessions.len > 0 and selected < sessions.len) {
                                    tmux.switchSession(sessions[selected].name) catch {};
                                }
                            },
                            .delete => {
                                if (pending_kill) |pk| {
                                    if (pk == selected) {
                                        _ = arena.reset(.retain_capacity);
                                        const frame_alloc = arena.allocator();
                                        const sessions = tmux.listSessions(frame_alloc) catch &.{};
                                        const current = tmux.getCurrentSession(frame_alloc) catch "";
                                        if (sessions.len > 0 and selected < sessions.len) {
                                            const target = sessions[selected].name;
                                            const is_current = std.mem.eql(u8, target, current);

                                            if (is_current) {
                                                var switched = false;
                                                if (sessions.len > 1) {
                                                    switched = tmux.switchToLastSession();
                                                    if (!switched) {
                                                        for (sessions) |s| {
                                                            if (!std.mem.eql(u8, s.name, target)) {
                                                                tmux.switchSession(s.name) catch {};
                                                                switched = true;
                                                                break;
                                                            }
                                                        }
                                                    }
                                                }
                                                if (switched) {
                                                    tmux.killSession(target) catch {};
                                                }
                                            } else {
                                                tmux.killSession(target) catch {};
                                            }
                                        }
                                        pending_kill = null;
                                    } else {
                                        pending_kill = selected;
                                    }
                                } else {
                                    pending_kill = selected;
                                }
                            },
                            .create => {
                                pending_kill = null;
                                exit_code = EXIT_CREATE;
                                should_quit = true;
                            },
                            .filter => {
                                pending_kill = null;
                                mode = .filter;
                                filter_len = 0;
                                selected = 0;
                                scroll_offset = 0;
                            },
                            .none => {},
                        }
                    },
                }
            },
            .winsize => |ws| try vx.resize(allocator, tty.writer(), ws),
            .auto_refresh => {}, // fall through to re-fetch + render below
            else => {},
        }

        if (should_quit) break;

        // Refresh session data every frame
        _ = arena.reset(.retain_capacity);
        const frame_alloc = arena.allocator();
        var no_sessions: [0]tmux.Session = .{};
        const all_sessions = tmux.listSessions(frame_alloc) catch no_sessions[0..];
        tmux.markAgentWaiting(frame_alloc, all_sessions);
        const current = tmux.getCurrentSession(frame_alloc) catch "";

        // In filter mode, show only matching sessions
        const filter_text: ?[]const u8 = if (mode == .filter) filter_buf[0..filter_len] else null;
        const display_sessions = if (mode == .filter) blk: {
            const indices = filterSessions(frame_alloc, all_sessions, filter_buf[0..filter_len]);
            const filtered = frame_alloc.alloc(tmux.Session, indices.len) catch break :blk all_sessions;
            for (indices, 0..) |idx, i| filtered[i] = all_sessions[idx];
            break :blk @as([]const tmux.Session, filtered);
        } else all_sessions;

        // Clamp selected index
        if (display_sessions.len > 0) {
            if (selected >= display_sessions.len) {
                selected = display_sessions.len - 1;
            }
        } else {
            selected = 0;
        }

        // Invalidate pending_kill if it's out of bounds (session was deleted)
        if (pending_kill) |pk| {
            if (display_sessions.len == 0 or pk >= display_sessions.len) {
                pending_kill = null;
            }
        }

        // Adjust scroll offset to keep selected visible
        const win = vx.window();
        const selected_has_path = if (display_sessions.len > 0 and selected < display_sessions.len)
            display_sessions[selected].path.len > 0
        else
            false;
        render.adjustScroll(&scroll_offset, selected, display_sessions.len, win.height, selected_has_path);

        // Render
        win.clear();
        render.draw(frame_alloc, win, display_sessions, selected, current, pending_kill, filter_text, scroll_offset);
        try vx.render(tty.writer());
    }

    // Clean shutdown: stop the timer thread
    quit_flag.store(true, .release);
    refresh_thread.join();

    // Exit with appropriate code for the wrapper script
    if (exit_code != EXIT_NORMAL) {
        std.process.exit(exit_code);
    }
}
