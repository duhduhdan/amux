const std = @import("std");
const vaxis = @import("vaxis");
const tmux = @import("tmux.zig");

const Cell = vaxis.Cell;
const Style = Cell.Style;
const Color = Cell.Color;

// Semantic color palette — uses ANSI indices so the sidebar adapts to
// whatever terminal theme is active (Nord, Catppuccin, Tokyo Night, etc.).
const theme = struct {
    const selection_bg: Color = .{ .index = 8 }; // bright black — subtle surface color
    const dim: Color = .{ .index = 8 }; // bright black — borders, help text, counts
    const text: Color = .default; // terminal default fg — session names
    const text_bright: Color = .{ .index = 15 }; // bright white — selected session
    const accent: Color = .{ .index = 14 }; // bright cyan — title, glyph
    const current: Color = .{ .index = 2 }; // green — current session indicator
    const kill_bg: Color = .{ .index = 1 }; // red — pending kill background
    const kill_fg: Color = .{ .index = 15 }; // bright white — pending kill text
};

/// Draw the full sidebar UI into the given window.
/// The allocator is used for temporary strings (e.g. formatted window counts)
/// that must outlive the render call because libvaxis stores grapheme references
/// rather than copies. Use an arena allocator that is reset each frame.
/// Compute the number of session rows that fit in the visible area.
/// Exported so main.zig can use it for scroll offset calculations.
pub fn maxVisibleRows(height: usize) usize {
    const help_rows: usize = 2;
    return if (height > help_rows + 2) height - help_rows - 2 else 0;
}

/// Adjust scroll_offset so that `selected` remains visible, accounting for
/// the ▲/▼ indicators and the path row that appears below the selected session.
///
/// Parameters:
///   scroll_offset: current scroll offset (mutated in place)
///   selected: currently selected session index
///   session_count: total number of sessions in the list
///   height: terminal window height (rows)
///   selected_has_path: whether the selected session has a non-empty path
pub fn adjustScroll(
    scroll_offset: *usize,
    selected: usize,
    session_count: usize,
    height: usize,
    selected_has_path: bool,
) void {
    const max_vis = maxVisibleRows(height);
    if (max_vis == 0 or session_count == 0) {
        scroll_offset.* = 0;
        return;
    }

    // Scroll up: if selected is above the visible window, snap to it
    if (selected < scroll_offset.*) {
        scroll_offset.* = selected;
        return;
    }

    // Scroll down: compute how many rows the visible sessions actually consume.
    // Start from scroll_offset and count rows until we exceed max_vis.
    // The ▲ indicator takes 1 row when scroll_offset > 0.
    // The ▼ indicator takes 1 row when there are sessions below the visible area.
    // The path row takes 1 extra row below the selected session.
    //
    // We need: selected must be within the rendered sessions (not pushed off
    // the bottom by indicators or the path row).

    // How many content rows are available for sessions?
    var avail = max_vis;

    // ▲ indicator steals a row if we're scrolled down
    if (scroll_offset.* > 0) {
        if (avail > 0) avail -= 1;
    }

    // Count rows consumed by sessions from scroll_offset up to and including selected
    var rows_needed: usize = 0;
    var i = scroll_offset.*;
    while (i <= selected) : (i += 1) {
        rows_needed += 1; // the session row itself
        if (i == selected and selected_has_path) {
            rows_needed += 1; // path row below selected
        }
    }

    // ▼ indicator: if there are sessions after selected, reserve 1 row
    const has_more_below = selected + 1 < session_count;
    if (has_more_below) {
        if (avail > 0) avail -= 1;
    }

    // If rows_needed exceeds available space, scroll down
    if (rows_needed > avail) {
        const deficit = rows_needed - avail;
        scroll_offset.* += deficit;

        // After adjusting, we now have scroll_offset > 0, so ▲ indicator is active.
        // Re-check: if scroll was previously 0, the ▲ indicator wasn't accounted for.
        // Recalculate with the ▲ row included.
        if (scroll_offset.* > 0) {
            var avail2 = max_vis - 1; // ▲ row
            if (has_more_below and avail2 > 0) avail2 -= 1; // ▼ row

            var rows2: usize = 0;
            i = scroll_offset.*;
            while (i <= selected) : (i += 1) {
                rows2 += 1;
                if (i == selected and selected_has_path) rows2 += 1;
            }
            if (rows2 > avail2) {
                scroll_offset.* += rows2 - avail2;
            }
        }
    }

    // Safety: never scroll past the selected item
    if (scroll_offset.* > selected) {
        scroll_offset.* = selected;
    }
}

/// pending_kill_index: if non-null, this session index is marked for deletion
/// (first `d` pressed, waiting for confirmation).
/// filter_text: if non-null, filter mode is active — show the filter input line.
/// scroll_offset: index of the first session to display (for scrolling).
/// watched: set of session names the user is watching for agent notifications.
pub fn draw(
    allocator: std.mem.Allocator,
    win: vaxis.Window,
    sessions: []const tmux.Session,
    selected: usize,
    current_session: []const u8,
    pending_kill_index: ?usize,
    filter_text: ?[]const u8,
    scroll_offset: usize,
    watched: *const std.StringHashMapUnmanaged(void),
) void {
    const width: usize = win.width;
    const height: usize = win.height;
    if (width < 3 or height < 3) return;

    // -- Border frame with ◆ amux title --
    drawBorder(win, width, height);

    // Content area sits inside the border: cols 1..width-2, rows 1..height-2
    const content_left: usize = 1;
    const content_width: usize = width - 2;

    // -- Session list (row 1 is the first content row) --
    const list_start: usize = 1;
    const help_rows: usize = 2;
    // max_visible = content rows available for sessions
    // Content rows total: height - 2 (border top + border bottom)
    // Subtract help_rows from that: height - 2 - help_rows
    const max_visible = if (height > help_rows + 2) height - help_rows - 2 else 0;

    if (sessions.len == 0) {
        _ = win.print(&.{.{
            .text = " No sessions",
            .style = .{ .fg = theme.dim, .italic = true },
        }}, .{ .row_offset = @intCast(list_start), .col_offset = @intCast(content_left) });
    } else {
        // Show scroll-up indicator if there are sessions above the view
        const has_scroll_up = scroll_offset > 0;
        const has_scroll_down_potential = sessions.len > scroll_offset + max_visible;
        var effective_start: usize = list_start;

        if (has_scroll_up and max_visible > 0) {
            // Draw ▲ indicator on first content row
            _ = win.print(&.{.{
                .text = " \xE2\x96\xB2",
                .style = .{ .fg = theme.dim },
            }}, .{ .row_offset = @intCast(list_start), .col_offset = @intCast(content_left) });
            effective_start = list_start + 1;
        }

        // The selected session gets an extra row below it for the path.
        // Sessions after the selected one are shifted down by 1.
        var row: usize = effective_start;
        var rendered_to: usize = scroll_offset; // track last rendered session index
        for (sessions[scroll_offset..], scroll_offset..) |session, i| {
            // Reserve 1 row for scroll-down indicator if needed
            const reserve_down: usize = if (has_scroll_down_potential and i + 1 < sessions.len) 1 else 0;
            if (row >= list_start + max_visible - reserve_down) break;

            const is_selected = i == selected;
            const is_current = std.mem.eql(u8, session.name, current_session);
            const is_pending_kill = if (pending_kill_index) |pk| pk == i else false;
            const is_watched = watched.contains(session.name);

            drawSessionRow(allocator, win, row, content_left, content_width, session, is_selected, is_current, is_pending_kill, is_watched);
            row += 1;
            rendered_to = i + 1;

            // Draw path below the selected session
            if (is_selected and session.path.len > 0 and row < list_start + max_visible - reserve_down) {
                const path_max = if (content_width > 4) content_width - 4 else 0;
                if (path_max > 0) {
                    const short_path = tmux.shortenPath(allocator, session.path, path_max);
                    _ = win.print(&.{.{
                        .text = short_path,
                        .style = .{ .fg = theme.dim, .italic = true },
                    }}, .{
                        .row_offset = @intCast(row),
                        .col_offset = @intCast(content_left + 3),
                        .wrap = .none,
                    });
                    row += 1;
                }
            }
        }

        // Show scroll-down indicator if there are sessions below the view
        if (rendered_to < sessions.len and row < list_start + max_visible) {
            _ = win.print(&.{.{
                .text = " \xE2\x96\xBC",
                .style = .{ .fg = theme.dim },
            }}, .{ .row_offset = @intCast(row), .col_offset = @intCast(content_left) });
        }
    }

    // -- Help text / filter input (last 2 content rows, above bottom border) --
    if (height >= 5) {
        const help_row: u16 = @intCast(height - 3);

        if (filter_text) |ft| {
            // Filter mode: show filter input on the last content row
            // Build " / query" display string using arena allocator
            const filter_display = std.fmt.allocPrint(allocator, " / {s}", .{ft}) catch " / ";
            _ = win.print(&.{.{
                .text = filter_display,
                .style = .{ .fg = theme.accent },
            }}, .{ .row_offset = help_row + 1, .col_offset = @intCast(content_left) });

            // Draw a cursor block after the text
            const cursor_col: u16 = @intCast(content_left + 3 + ft.len);
            if (cursor_col < @as(u16, @intCast(content_left + content_width))) {
                win.writeCell(cursor_col, help_row + 1, .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = .{ .bg = theme.accent, .fg = .default },
                });
            }

            // First help row: show filter-mode hints
            _ = win.print(&.{.{
                .text = " esc cancel  enter select",
                .style = .{ .fg = theme.dim },
            }}, .{ .row_offset = help_row, .col_offset = @intCast(content_left) });
        } else {
            // Normal mode help text — two lines, keys in accent, labels in dim
            _ = win.print(&.{
                .{ .text = " ", .style = .{ .fg = theme.dim } },
                .{ .text = "j/k", .style = .{ .fg = theme.accent } },
                .{ .text = " nav  ", .style = .{ .fg = theme.dim } },
                .{ .text = "\xE2\x86\xB5", .style = .{ .fg = theme.accent } },
                .{ .text = " sel  ", .style = .{ .fg = theme.dim } },
                .{ .text = "/", .style = .{ .fg = theme.accent } },
                .{ .text = " filter", .style = .{ .fg = theme.dim } },
            }, .{ .row_offset = help_row, .col_offset = @intCast(content_left) });

            _ = win.print(&.{
                .{ .text = " ", .style = .{ .fg = theme.dim } },
                .{ .text = "w", .style = .{ .fg = theme.accent } },
                .{ .text = " watch  ", .style = .{ .fg = theme.dim } },
                .{ .text = "n", .style = .{ .fg = theme.accent } },
                .{ .text = " new  ", .style = .{ .fg = theme.dim } },
                .{ .text = "d", .style = .{ .fg = theme.accent } },
                .{ .text = " kill", .style = .{ .fg = theme.dim } },
            }, .{ .row_offset = help_row + 1, .col_offset = @intCast(content_left) });
        }
    }
}

fn drawBorder(win: vaxis.Window, width: usize, height: usize) void {
    const border_fg: Color = theme.dim;
    const w: u16 = @intCast(width);
    const h: u16 = @intCast(height);

    // -- Top border: ┌─ ◆ amux ─────┐ --
    win.writeCell(0, 0, .{
        .char = .{ .grapheme = "\u{250C}", .width = 1 },
        .style = .{ .fg = border_fg },
    });
    {
        var col: u16 = 1;
        while (col < w - 1) : (col += 1) {
            win.writeCell(col, 0, .{
                .char = .{ .grapheme = "\u{2500}", .width = 1 },
                .style = .{ .fg = border_fg },
            });
        }
    }
    win.writeCell(w - 1, 0, .{
        .char = .{ .grapheme = "\u{2510}", .width = 1 },
        .style = .{ .fg = border_fg },
    });
    // Overlay title text if it fits (needs ~10 cols: ┌─ ◆ amux ─┐)
    if (width >= 10) {
        _ = win.print(&.{
            .{ .text = " \u{229E}", .style = .{ .fg = theme.accent, .bold = true } },
            .{ .text = " amux ", .style = .{ .fg = theme.accent, .bold = true } },
        }, .{ .row_offset = 0, .col_offset = 2 });
    }

    // -- Bottom border: └──────┘ --
    win.writeCell(0, h - 1, .{
        .char = .{ .grapheme = "\u{2514}", .width = 1 },
        .style = .{ .fg = border_fg },
    });
    {
        var col: u16 = 1;
        while (col < w - 1) : (col += 1) {
            win.writeCell(col, h - 1, .{
                .char = .{ .grapheme = "\u{2500}", .width = 1 },
                .style = .{ .fg = border_fg },
            });
        }
    }
    win.writeCell(w - 1, h - 1, .{
        .char = .{ .grapheme = "\u{2518}", .width = 1 },
        .style = .{ .fg = border_fg },
    });

    // -- Side borders: │ on every content row --
    {
        var row: u16 = 1;
        while (row < h - 1) : (row += 1) {
            win.writeCell(0, row, .{
                .char = .{ .grapheme = "\u{2502}", .width = 1 },
                .style = .{ .fg = border_fg },
            });
            win.writeCell(w - 1, row, .{
                .char = .{ .grapheme = "\u{2502}", .width = 1 },
                .style = .{ .fg = border_fg },
            });
        }
    }
}

fn drawSessionRow(
    allocator: std.mem.Allocator,
    win: vaxis.Window,
    row: usize,
    left_col: usize,
    content_width: usize,
    session: tmux.Session,
    is_selected: bool,
    is_current: bool,
    is_pending_kill: bool,
    is_watched: bool,
) void {
    const row_u16: u16 = @intCast(row);
    const left: u16 = @intCast(left_col);

    // Determine styles — pending kill overrides selection highlight
    const bg: Color = if (is_pending_kill) theme.kill_bg else if (is_selected) theme.selection_bg else .default;
    const name_fg: Color = if (is_pending_kill) theme.kill_fg else if (session.agent_waiting) theme.accent else if (is_selected) theme.text_bright else theme.text;
    const count_fg: Color = if (is_pending_kill) theme.kill_fg else if (is_selected) theme.text else theme.dim;
    const use_strikethrough = is_pending_kill;

    // Fill background if selected or pending kill — only within the content area (not borders).
    // Must set an explicit space character so the terminal renders the bg color.
    if (is_selected or is_pending_kill) {
        var col: u16 = left;
        while (col < left + @as(u16, @intCast(content_width))) : (col += 1) {
            win.writeCell(col, row_u16, .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = .{ .bg = bg },
            });
        }
    }

    // Indicator: " ● " (space, indicator, space) starting at left_col
    // Priority: agent_waiting(✸ bright) > watched(✸ dim) > current(●) > blank
    const indicator: []const u8 = if (session.agent_waiting) "\u{2738}" else if (is_watched) "\u{2738}" else if (is_current) "\u{25CF}" else " ";
    const indicator_fg: Color = if (session.agent_waiting) theme.accent else if (is_watched) theme.dim else if (is_current) theme.current else .default;

    _ = win.print(&.{
        .{ .text = " ", .style = .{ .bg = bg } },
        .{ .text = indicator, .style = .{ .fg = indicator_fg, .bg = bg } },
        .{ .text = " ", .style = .{ .bg = bg } },
    }, .{ .row_offset = row_u16, .col_offset = left });

    // Session name (truncated to fit within content area)
    const prefix_width: usize = 3; // " ● "
    const suffix_width: usize = 5; // space + up to 2 digits + 1 right margin
    const name_max = if (content_width > prefix_width + suffix_width) content_width - prefix_width - suffix_width else 0;

    const display_name = if (session.name.len > name_max)
        session.name[0..name_max]
    else
        session.name;

    _ = win.print(&.{.{
        .text = display_name,
        .style = .{ .fg = name_fg, .bg = bg, .bold = is_selected, .strikethrough = use_strikethrough },
    }}, .{
        .row_offset = row_u16,
        .col_offset = @intCast(left_col + prefix_width),
        .wrap = .none,
    });

    // Window count (right-aligned within content area)
    // NOTE: allocPrint is required here because libvaxis cells store grapheme
    // references (not copies). A stack buffer would dangle after this function
    // returns, producing garbage characters. The arena allocator keeps the
    // string alive until the frame resets.
    const count_str = std.fmt.allocPrint(allocator, "{d}", .{session.windows}) catch "?";

    if (content_width > count_str.len + 1) {
        const count_col: u16 = @intCast(left_col + content_width - count_str.len - 1);
        _ = win.print(&.{.{
            .text = count_str,
            .style = .{ .fg = count_fg, .bg = bg },
        }}, .{
            .row_offset = row_u16,
            .col_offset = count_col,
            .wrap = .none,
        });
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Screen = vaxis.Screen;
const Window = vaxis.Window;

/// Empty watched set for tests that don't need watch functionality.
const empty_watched: std.StringHashMapUnmanaged(void) = .{};

/// Create a Screen + Arena pair for testing at the given dimensions.
/// Caller must `defer ctx.screen.deinit(testing.allocator)` and
/// `defer ctx.arena.deinit()`. Pass `ctx.arena.allocator()` to `draw()`
/// so that allocPrint leaks are detected through the backing testing.allocator.
fn createTestWindow(cols: u16, rows: u16) !struct { screen: Screen, arena: std.heap.ArenaAllocator } {
    const screen = try Screen.init(testing.allocator, .{
        .cols = cols,
        .rows = rows,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    return .{ .screen = screen, .arena = std.heap.ArenaAllocator.init(testing.allocator) };
}

/// Read the grapheme string from a cell, returning " " for default/empty cells.
fn readGrapheme(win: Window, col: u16, row: u16) []const u8 {
    const cell = win.readCell(col, row) orelse return " ";
    return cell.char.grapheme;
}

/// Build a test session.
fn testSession(name: []const u8, windows: u16) tmux.Session {
    return .{ .name = name, .windows = windows, .path = "" };
}

fn testSessionWithPath(name: []const u8, windows: u16, path: []const u8) tmux.Session {
    return .{ .name = name, .windows = windows, .path = path };
}

fn testSessionWaiting(name: []const u8, windows: u16) tmux.Session {
    return .{ .name = name, .windows = windows, .path = "", .agent_waiting = true };
}

// -- Border --

test "draw: border corners and title" {
    var ctx = try createTestWindow(30, 15);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    draw(ctx.arena.allocator(), win, &.{}, 0, "", null, null, 0, &empty_watched);

    // Top-left corner ┌
    try testing.expectEqualStrings("\u{250C}", readGrapheme(win, 0, 0));
    // Top-right corner ┐
    try testing.expectEqualStrings("\u{2510}", readGrapheme(win, 29, 0));
    // Bottom-left corner └
    try testing.expectEqualStrings("\u{2514}", readGrapheme(win, 0, 14));
    // Bottom-right corner ┘
    try testing.expectEqualStrings("\u{2518}", readGrapheme(win, 29, 14));

    // Title: ⊞ at col 3 with accent color
    try testing.expectEqualStrings("\u{229E}", readGrapheme(win, 3, 0));
    const glyph_cell = win.readCell(3, 0).?;
    try testing.expectEqual(theme.accent, glyph_cell.style.fg);

    // "amux" starts at col 5
    try testing.expectEqualStrings("a", readGrapheme(win, 5, 0));
    try testing.expectEqualStrings("m", readGrapheme(win, 6, 0));
    try testing.expectEqualStrings("u", readGrapheme(win, 7, 0));
    try testing.expectEqualStrings("x", readGrapheme(win, 8, 0));
    const title_cell = win.readCell(5, 0).?;
    try testing.expect(title_cell.style.bold);
    try testing.expectEqual(theme.accent, title_cell.style.fg);
}

test "draw: side borders on content rows" {
    var ctx = try createTestWindow(20, 10);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    draw(ctx.arena.allocator(), win, &.{}, 0, "", null, null, 0, &empty_watched);

    // Every content row (1 to height-2) should have │ at col 0 and col width-1
    var row: u16 = 1;
    while (row < 9) : (row += 1) {
        try testing.expectEqualStrings("\u{2502}", readGrapheme(win, 0, row));
        try testing.expectEqualStrings("\u{2502}", readGrapheme(win, 19, row));
    }
}

// -- Empty sessions --

test "draw: empty sessions shows 'No sessions' inside border" {
    var ctx = try createTestWindow(30, 15);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    draw(ctx.arena.allocator(), win, &.{}, 0, "", null, null, 0, &empty_watched);

    // " No sessions" printed at content_left=1, row 1
    // Text starts with space, so 'N' at col 2
    try testing.expectEqualStrings("N", readGrapheme(win, 2, 1));
    try testing.expectEqualStrings("o", readGrapheme(win, 3, 1));

    const cell = win.readCell(2, 1).?;
    try testing.expect(cell.style.italic);
    try testing.expectEqual(theme.dim, cell.style.fg);
}

// -- Session name positioning --

test "draw: session name starts at col 4 (border + indicator prefix)" {
    var ctx = try createTestWindow(30, 15);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    const sessions = [_]tmux.Session{
        testSession("dotfiles", 3),
    };
    draw(ctx.arena.allocator(), win, &sessions, 0, "", null, null, 0, &empty_watched);

    // left_col(1) + prefix_width(3) = col 4
    try testing.expectEqualStrings("d", readGrapheme(win, 4, 1));
    try testing.expectEqualStrings("o", readGrapheme(win, 5, 1));
    try testing.expectEqualStrings("t", readGrapheme(win, 6, 1));
}

// -- Current session indicator --

test "draw: current session gets green filled circle indicator" {
    var ctx = try createTestWindow(30, 15);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    const sessions = [_]tmux.Session{
        testSession("myproject", 2),
    };
    draw(ctx.arena.allocator(), win, &sessions, 0, "myproject", null, null, 0, &empty_watched);

    // Indicator ● at col 2 (left_col=1, space at 1, indicator at 2), row 1
    try testing.expectEqualStrings("\u{25CF}", readGrapheme(win, 2, 1));
    const cell = win.readCell(2, 1).?;
    try testing.expectEqual(theme.current, cell.style.fg);
}

// -- Selected row background --

test "draw: selected row has polar2 background within content area" {
    var ctx = try createTestWindow(30, 15);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    const sessions = [_]tmux.Session{
        testSession("first", 1),
        testSession("second", 2),
    };
    draw(ctx.arena.allocator(), win, &sessions, 1, "", null, null, 0, &empty_watched); // select index 1 = "second"

    // Row 2 (list_start=1, index 1 → row 2): content cols 1..28 should have polar2 bg
    const selected_row: u16 = 2;
    var col: u16 = 1;
    while (col < 29) : (col += 1) {
        const cell = win.readCell(col, selected_row).?;
        try testing.expectEqual(theme.selection_bg, cell.style.bg);
    }

    // Border cols (0 and 29) should NOT have polar2 bg
    const left_border = win.readCell(0, selected_row).?;
    try testing.expect(!std.meta.eql(theme.selection_bg, left_border.style.bg));
    const right_border = win.readCell(29, selected_row).?;
    try testing.expect(!std.meta.eql(theme.selection_bg, right_border.style.bg));

    // Row 1 (index 0, not selected) should NOT have polar2 bg
    const unselected_cell = win.readCell(1, 1).?;
    try testing.expect(!std.meta.eql(theme.selection_bg, unselected_cell.style.bg));
}

// -- Selected row style --

test "draw: selected session name is bold with snow2 foreground" {
    var ctx = try createTestWindow(30, 15);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    const sessions = [_]tmux.Session{
        testSession("dotfiles", 3),
    };
    draw(ctx.arena.allocator(), win, &sessions, 0, "", null, null, 0, &empty_watched);

    // Name at col 4, row 1 — selected
    const cell = win.readCell(4, 1).?;
    try testing.expect(cell.style.bold);
    try testing.expectEqual(theme.text_bright, cell.style.fg);
}

// -- Window count right-aligned --

test "draw: window count is right-aligned within content area" {
    var ctx = try createTestWindow(30, 15);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    const sessions = [_]tmux.Session{
        testSession("dotfiles", 3),
    };
    draw(ctx.arena.allocator(), win, &sessions, 0, "", null, null, 0, &empty_watched);

    // content_width=28, count "3" (len=1)
    // count_col = 1 + 28 - 1 - 1 = 27
    // Col 27: "3", col 28: margin, col 29: │ border
    try testing.expectEqualStrings("3", readGrapheme(win, 27, 1));
    try testing.expectEqualStrings("\u{2502}", readGrapheme(win, 29, 1)); // right border
}

// -- Help text --

test "draw: help text renders inside border above bottom" {
    var ctx = try createTestWindow(30, 15);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    draw(ctx.arena.allocator(), win, &.{}, 0, "", null, null, 0, &empty_watched);

    // help_row = 12: " j/k nav  ↵ sel  / filter"
    // 'j' at col 2 in accent color
    try testing.expectEqualStrings("j", readGrapheme(win, 2, 12));
    const help_key = win.readCell(2, 12).?;
    try testing.expectEqual(theme.accent, help_key.style.fg);
    // help_row+1 = 13: " n new  d kill  q quit"
    try testing.expectEqualStrings("n", readGrapheme(win, 2, 13));
    const help_key2 = win.readCell(2, 13).?;
    try testing.expectEqual(theme.accent, help_key2.style.fg);
    // Row 14: bottom border └
    try testing.expectEqualStrings("\u{2514}", readGrapheme(win, 0, 14));
}

// -- Truncation --

test "draw: sessions beyond visible area are not rendered" {
    // Height 7: max_visible = 7-2-2 = 3. Sessions at rows 1,2,3. Help at rows 4,5. Border at 6.
    var ctx = try createTestWindow(30, 7);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    const sessions = [_]tmux.Session{
        testSession("one", 1),
        testSession("two", 1),
        testSession("three", 1),
        testSession("four", 1), // should NOT render
        testSession("five", 1), // should NOT render
    };
    draw(ctx.arena.allocator(), win, &sessions, 0, "", null, null, 0, &empty_watched);

    // Rows 1,2,3 should have session names (col 4 = first char of name)
    try testing.expectEqualStrings("o", readGrapheme(win, 4, 1)); // "one"
    try testing.expectEqualStrings("t", readGrapheme(win, 4, 2)); // "two"
    try testing.expectEqualStrings("t", readGrapheme(win, 4, 3)); // "three"

    // Row 4 should be help text, not "four"
    // Help " j/k nav..." at col_offset=1: space at 1, 'j' at 2
    const row4_col2 = readGrapheme(win, 2, 4);
    try testing.expect(!std.mem.eql(u8, "f", row4_col2));
    try testing.expectEqualStrings("j", row4_col2);
}

// -- Long name truncation --

test "draw: long session name is truncated to fit within content area" {
    // Width 20, content_width=18: prefix=3, suffix=5 → name_max = 18-3-5 = 10
    var ctx = try createTestWindow(20, 10);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    const sessions = [_]tmux.Session{
        testSession("this-is-a-very-long-session-name", 1),
    };
    draw(ctx.arena.allocator(), win, &sessions, 0, "", null, null, 0, &empty_watched);

    // Name starts at col 4 (left_col=1 + prefix=3)
    try testing.expectEqualStrings("t", readGrapheme(win, 4, 1));

    // Count "1" right-aligned: count_col = 1 + 18 - 1 - 1 = 17
    // Col 17: "1", col 18: margin, col 19: │ border
    try testing.expectEqualStrings("1", readGrapheme(win, 17, 1));
    try testing.expectEqualStrings("\u{2502}", readGrapheme(win, 19, 1));
}

// -- Small window --

test "draw: small window (< 3x3) does not panic" {
    var ctx = try createTestWindow(2, 2);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    // Should return immediately without crashing
    draw(ctx.arena.allocator(), win, &.{}, 0, "", null, null, 0, &empty_watched);
}

test "draw: zero-size window does not panic" {
    var ctx = try createTestWindow(0, 0);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 0,
        .height = 0,
        .screen = &ctx.screen,
    };

    draw(ctx.arena.allocator(), win, &.{}, 0, "", null, null, 0, &empty_watched);
}

// -- Multiple sessions rendering --

test "draw: multiple sessions render on consecutive rows" {
    var ctx = try createTestWindow(30, 15);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    const sessions = [_]tmux.Session{
        testSession("alpha", 1),
        testSession("beta", 2),
        testSession("gamma", 3),
    };
    draw(ctx.arena.allocator(), win, &sessions, 1, "alpha", null, null, 0, &empty_watched);

    // Row 1: "alpha" — current session (selected=1, so not selected)
    try testing.expectEqualStrings("a", readGrapheme(win, 4, 1));
    try testing.expectEqualStrings("\u{25CF}", readGrapheme(win, 2, 1)); // ● current

    // Row 2: "beta" — selected
    try testing.expectEqualStrings("b", readGrapheme(win, 4, 2));
    const beta_cell = win.readCell(4, 2).?;
    try testing.expect(beta_cell.style.bold); // selected = bold
    try testing.expectEqual(theme.selection_bg, beta_cell.style.bg); // selected bg

    // Row 3: "gamma" — neither current nor selected
    try testing.expectEqualStrings("g", readGrapheme(win, 4, 3));
    const gamma_cell = win.readCell(4, 3).?;
    try testing.expect(!gamma_cell.style.bold);
}

// -- Pending kill visual --

test "draw: pending kill session has red background and strikethrough" {
    var ctx = try createTestWindow(30, 15);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    const sessions = [_]tmux.Session{
        testSession("alpha", 1),
        testSession("beta", 2),
    };
    // selected=0, pending_kill=0 (alpha marked for deletion)
    draw(ctx.arena.allocator(), win, &sessions, 0, "", @as(usize, 0), null, 0, &empty_watched);

    // Row 1 (alpha): should have kill_bg background
    const kill_cell = win.readCell(4, 1).?;
    try testing.expectEqual(theme.kill_bg, kill_cell.style.bg);
    try testing.expectEqual(theme.kill_fg, kill_cell.style.fg);
    try testing.expect(kill_cell.style.strikethrough);

    // Row 2 (beta): should NOT have kill_bg
    const normal_cell = win.readCell(4, 2).?;
    try testing.expect(!std.meta.eql(theme.kill_bg, normal_cell.style.bg));
    try testing.expect(!normal_cell.style.strikethrough);
}

test "draw: pending kill on non-selected row still shows red" {
    var ctx = try createTestWindow(30, 15);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    const sessions = [_]tmux.Session{
        testSession("alpha", 1),
        testSession("beta", 2),
    };
    // selected=1 (beta), pending_kill=0 (alpha)
    draw(ctx.arena.allocator(), win, &sessions, 1, "", @as(usize, 0), null, 0, &empty_watched);

    // Row 1 (alpha): pending kill — red bg
    const kill_cell = win.readCell(4, 1).?;
    try testing.expectEqual(theme.kill_bg, kill_cell.style.bg);

    // Row 2 (beta): selected — selection bg
    const sel_cell = win.readCell(4, 2).?;
    try testing.expectEqual(theme.selection_bg, sel_cell.style.bg);
}

test "draw: help text shows key hints" {
    var ctx = try createTestWindow(30, 15);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    draw(ctx.arena.allocator(), win, &.{}, 0, "", null, null, 0, &empty_watched);

    // Row 12: keys in accent. 'j' at col 2
    try testing.expectEqualStrings("j", readGrapheme(win, 2, 12));
}

// -- Path display for selected session --

test "draw: selected session shows path on the row below" {
    var ctx = try createTestWindow(30, 15);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    const sessions = [_]tmux.Session{
        testSessionWithPath("dotfiles", 3, "/tmp/dotfiles"),
        testSession("other", 1),
    };
    draw(ctx.arena.allocator(), win, &sessions, 0, "", null, null, 0, &empty_watched);

    // Row 1: "dotfiles" name at col 4
    try testing.expectEqualStrings("d", readGrapheme(win, 4, 1));

    // Row 2: path "/tmp/dotfiles" at col 4 (content_left=1 + indent 3), dimmed + italic
    try testing.expectEqualStrings("/", readGrapheme(win, 4, 2));
    const path_cell = win.readCell(4, 2).?;
    try testing.expectEqual(theme.dim, path_cell.style.fg);
    try testing.expect(path_cell.style.italic);

    // Row 3: "other" session (shifted down by 1 due to path row)
    try testing.expectEqualStrings("o", readGrapheme(win, 4, 3));
}

test "draw: non-selected session does not show path" {
    var ctx = try createTestWindow(30, 15);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    const sessions = [_]tmux.Session{
        testSessionWithPath("alpha", 1, "/tmp/alpha"),
        testSessionWithPath("beta", 2, "/tmp/beta"),
    };
    // Select beta (index 1) — alpha's path should NOT be shown
    draw(ctx.arena.allocator(), win, &sessions, 1, "", null, null, 0, &empty_watched);

    // Row 1: "alpha" — no path below
    try testing.expectEqualStrings("a", readGrapheme(win, 4, 1));
    // Row 2: "beta" (not alpha's path)
    try testing.expectEqualStrings("b", readGrapheme(win, 4, 2));
    // Row 3: beta's path
    try testing.expectEqualStrings("/", readGrapheme(win, 4, 3));
}

test "draw: session with empty path does not get extra row" {
    var ctx = try createTestWindow(30, 15);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    const sessions = [_]tmux.Session{
        testSession("alpha", 1), // no path
        testSession("beta", 2),
    };
    // Select alpha (index 0) — no path, so beta should be on row 2 (no shift)
    draw(ctx.arena.allocator(), win, &sessions, 0, "", null, null, 0, &empty_watched);

    try testing.expectEqualStrings("a", readGrapheme(win, 4, 1));
    try testing.expectEqualStrings("b", readGrapheme(win, 4, 2));
}

// -- Filter mode display --

// -- Agent waiting indicator --

test "draw: agent_waiting session shows star glyph and accent name" {
    var ctx = try createTestWindow(30, 15);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    const sessions = [_]tmux.Session{
        testSessionWaiting("waiting-proj", 2),
        testSession("normal-proj", 1),
    };
    // Select normal-proj (index 1), so waiting-proj is unselected
    draw(ctx.arena.allocator(), win, &sessions, 1, "", null, null, 0, &empty_watched);

    // Row 1: ✸ indicator at col 2, accent color
    try testing.expectEqualStrings("\u{2738}", readGrapheme(win, 2, 1));
    const glyph_cell = win.readCell(2, 1).?;
    try testing.expectEqual(theme.accent, glyph_cell.style.fg);

    // Row 1: "waiting-proj" name at col 4 — accent color
    const name_cell = win.readCell(4, 1).?;
    try testing.expectEqual(theme.accent, name_cell.style.fg);
    try testing.expect(!name_cell.style.bold); // not selected
}

test "draw: agent_waiting + selected shows star glyph and accent bold name" {
    var ctx = try createTestWindow(30, 15);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    const sessions = [_]tmux.Session{
        testSessionWaiting("waiting-proj", 2),
        testSession("normal-proj", 1),
    };
    // Select waiting-proj (index 0)
    draw(ctx.arena.allocator(), win, &sessions, 0, "", null, null, 0, &empty_watched);

    // Row 1: ✸ indicator
    try testing.expectEqualStrings("\u{2738}", readGrapheme(win, 2, 1));

    // Row 1: name — selected + waiting = accent + bold
    const cell = win.readCell(4, 1).?;
    try testing.expectEqual(theme.accent, cell.style.fg);
    try testing.expect(cell.style.bold);
}

test "draw: agent_waiting overrides current session indicator" {
    var ctx = try createTestWindow(30, 15);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    const sessions = [_]tmux.Session{
        testSessionWaiting("myproject", 2),
    };
    // Current AND waiting — waiting takes priority
    draw(ctx.arena.allocator(), win, &sessions, 0, "myproject", null, null, 0, &empty_watched);

    // ✸ at col 2, accent color (waiting overrides current)
    try testing.expectEqualStrings("\u{2738}", readGrapheme(win, 2, 1));
    const glyph_cell = win.readCell(2, 1).?;
    try testing.expectEqual(theme.accent, glyph_cell.style.fg);
}

test "draw: non-waiting session uses normal text color" {
    var ctx = try createTestWindow(30, 15);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    const sessions = [_]tmux.Session{
        testSession("normal-proj", 1),
        testSessionWaiting("waiting-proj", 2),
    };
    // Select waiting-proj (index 1), so normal-proj is unselected
    draw(ctx.arena.allocator(), win, &sessions, 1, "", null, null, 0, &empty_watched);

    // Row 1: "normal-proj" — no waiting = default text, blank indicator
    const cell = win.readCell(4, 1).?;
    try testing.expectEqual(theme.text, cell.style.fg);
    try testing.expectEqualStrings(" ", readGrapheme(win, 2, 1));
}

test "draw: pending_kill overrides agent_waiting color" {
    var ctx = try createTestWindow(30, 15);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    const sessions = [_]tmux.Session{
        testSessionWaiting("waiting-proj", 2),
    };
    // Selected + pending kill + waiting — kill should override
    draw(ctx.arena.allocator(), win, &sessions, 0, "", @as(usize, 0), null, 0, &empty_watched);

    const cell = win.readCell(4, 1).?;
    try testing.expectEqual(theme.kill_fg, cell.style.fg);
    try testing.expectEqual(theme.kill_bg, cell.style.bg);
}

// -- Watch indicator --

test "draw: watched session with agent_waiting shows bright star" {
    var ctx = try createTestWindow(30, 15);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    const sessions = [_]tmux.Session{
        .{ .name = "watched-proj", .windows = 2, .path = "", .agent_waiting = true },
    };
    var w: std.StringHashMapUnmanaged(void) = .{};
    defer w.deinit(testing.allocator);
    try w.put(testing.allocator, "watched-proj", {});
    draw(ctx.arena.allocator(), win, &sessions, 0, "", null, null, 0, &w);

    // Row 1: ✸ indicator at col 2, accent color (bright)
    try testing.expectEqualStrings("\u{2738}", readGrapheme(win, 2, 1));
    const glyph_cell = win.readCell(2, 1).?;
    try testing.expectEqual(theme.accent, glyph_cell.style.fg);

    // Name should also be accent color
    const name_cell = win.readCell(4, 1).?;
    try testing.expectEqual(theme.accent, name_cell.style.fg);
}

test "draw: watched session without agent_waiting shows dim star" {
    var ctx = try createTestWindow(30, 15);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    const sessions = [_]tmux.Session{
        testSession("watched-proj", 2),
    };
    var w: std.StringHashMapUnmanaged(void) = .{};
    defer w.deinit(testing.allocator);
    try w.put(testing.allocator, "watched-proj", {});
    draw(ctx.arena.allocator(), win, &sessions, 0, "", null, null, 0, &w);

    // Row 1: ✸ indicator at col 2, dim color (watched but busy)
    try testing.expectEqualStrings("\u{2738}", readGrapheme(win, 2, 1));
    const glyph_cell = win.readCell(2, 1).?;
    try testing.expectEqual(theme.dim, glyph_cell.style.fg);

    // Name should be normal text (not accent — agent isn't waiting)
    const name_cell = win.readCell(4, 1).?;
    try testing.expectEqual(theme.text_bright, name_cell.style.fg); // selected = bright
}

test "draw: unwatched session shows no star indicator" {
    var ctx = try createTestWindow(30, 15);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    const sessions = [_]tmux.Session{
        testSession("unwatched", 1),
    };
    draw(ctx.arena.allocator(), win, &sessions, 0, "", null, null, 0, &empty_watched);

    // Row 1: blank indicator at col 2
    try testing.expectEqualStrings(" ", readGrapheme(win, 2, 1));
}

test "draw: filter mode shows filter input on bottom row" {
    var ctx = try createTestWindow(30, 15);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    draw(ctx.arena.allocator(), win, &.{}, 0, "", null, "dot", 0, &empty_watched);

    // Row 13 (help_row+1): " / dot" — '/' at col 2, 'd' at col 4
    try testing.expectEqualStrings("/", readGrapheme(win, 2, 13));
    try testing.expectEqualStrings("d", readGrapheme(win, 4, 13));
    try testing.expectEqualStrings("o", readGrapheme(win, 5, 13));
    try testing.expectEqualStrings("t", readGrapheme(win, 6, 13));

    // Filter text should use accent color
    const slash_cell = win.readCell(2, 13).?;
    try testing.expectEqual(theme.accent, slash_cell.style.fg);

    // Cursor block at col 7 (content_left=1 + 3 + "dot".len=3 = 7)
    const cursor_cell = win.readCell(7, 13).?;
    try testing.expectEqual(theme.accent, cursor_cell.style.bg);
}

test "draw: filter mode shows cancel hint on help row" {
    var ctx = try createTestWindow(30, 15);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    draw(ctx.arena.allocator(), win, &.{}, 0, "", null, "", 0, &empty_watched);

    // Row 12 (help_row): " esc cancel  enter select" — 'e' at col 2
    try testing.expectEqualStrings("e", readGrapheme(win, 2, 12));
}

test "draw: filter mode with empty string shows cursor at start" {
    var ctx = try createTestWindow(30, 15);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    draw(ctx.arena.allocator(), win, &.{}, 0, "", null, "", 0, &empty_watched);

    // " / " then cursor at col 4 (content_left=1 + 3 + 0)
    try testing.expectEqualStrings("/", readGrapheme(win, 2, 13));
    const cursor_cell = win.readCell(4, 13).?;
    try testing.expectEqual(theme.accent, cursor_cell.style.bg);
}

// -- Scroll offset --

test "draw: scroll_offset skips sessions above the view" {
    // Height 7: max_visible = 7-2-2 = 3 rows for sessions
    var ctx = try createTestWindow(30, 7);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    const sessions = [_]tmux.Session{
        testSession("alpha", 1),
        testSession("beta", 2),
        testSession("gamma", 3),
        testSession("delta", 4),
        testSession("epsilon", 5),
    };
    // scroll_offset=2: skip alpha and beta, show gamma onward
    draw(ctx.arena.allocator(), win, &sessions, 2, "", null, null, 2, &empty_watched);

    // Row 1: gamma (first visible session)
    try testing.expectEqualStrings("g", readGrapheme(win, 4, 1));
}

test "draw: scroll up indicator shown when offset > 0" {
    var ctx = try createTestWindow(30, 7);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    const sessions = [_]tmux.Session{
        testSession("alpha", 1),
        testSession("beta", 2),
        testSession("gamma", 3),
        testSession("delta", 4),
    };
    // scroll_offset=1: alpha is above
    draw(ctx.arena.allocator(), win, &sessions, 1, "", null, null, 1, &empty_watched);

    // Row 1: ▲ indicator
    try testing.expectEqualStrings("\xE2\x96\xB2", readGrapheme(win, 2, 1));
    // Row 2: beta (first visible session after indicator)
    try testing.expectEqualStrings("b", readGrapheme(win, 4, 2));
}

test "draw: scroll down indicator shown when sessions below" {
    var ctx = try createTestWindow(30, 7);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    const sessions = [_]tmux.Session{
        testSession("alpha", 1),
        testSession("beta", 2),
        testSession("gamma", 3),
        testSession("delta", 4),
        testSession("epsilon", 5),
    };
    // scroll_offset=0, more sessions than fit
    draw(ctx.arena.allocator(), win, &sessions, 0, "", null, null, 0, &empty_watched);

    // Should show ▼ at some row below the visible sessions
    // With max_visible=3 and 5 sessions, we expect ▼ indicator
    // Row 1: alpha, Row 2: alpha path (selected), Row 3: ▼ (reserved)
    // Actually alpha has no path so: Row 1: alpha, Row 2: beta, Row 3: ▼
    try testing.expectEqualStrings("\xE2\x96\xBC", readGrapheme(win, 2, 3));
}

test "draw: no scroll indicators when all sessions fit" {
    var ctx = try createTestWindow(30, 15);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    const sessions = [_]tmux.Session{
        testSession("alpha", 1),
        testSession("beta", 2),
    };
    draw(ctx.arena.allocator(), win, &sessions, 0, "", null, null, 0, &empty_watched);

    // Row 1: alpha (no ▲)
    try testing.expectEqualStrings("a", readGrapheme(win, 4, 1));
    // No ▼ anywhere — row 3 should not have the indicator
    const row3 = readGrapheme(win, 2, 3);
    try testing.expect(!std.mem.eql(u8, "\xE2\x96\xBC", row3));
}

test "maxVisibleRows: correct calculation" {
    try testing.expectEqual(@as(usize, 11), maxVisibleRows(15)); // 15 - 2 - 2 = 11
    try testing.expectEqual(@as(usize, 3), maxVisibleRows(7)); // 7 - 2 - 2 = 3
    try testing.expectEqual(@as(usize, 1), maxVisibleRows(5)); // 5 - 2 - 2 = 1
    try testing.expectEqual(@as(usize, 0), maxVisibleRows(4)); // too small
    try testing.expectEqual(@as(usize, 0), maxVisibleRows(0));
}

// -- adjustScroll --

test "adjustScroll: no change when all sessions fit" {
    // height=15 → max_vis=11. 3 sessions easily fit.
    var offset: usize = 0;
    adjustScroll(&offset, 0, 3, 15, false);
    try testing.expectEqual(@as(usize, 0), offset);

    adjustScroll(&offset, 2, 3, 15, false);
    try testing.expectEqual(@as(usize, 0), offset);
}

test "adjustScroll: scrolls down when selected is below visible area" {
    // height=7 → max_vis=3. 5 sessions.
    var offset: usize = 0;
    // Select session 3 (0-indexed) — doesn't fit in rows 0,1,2
    adjustScroll(&offset, 3, 5, 7, false);
    try testing.expect(offset > 0);
    // selected=3 must be visible: offset <= 3
    try testing.expect(offset <= 3);
}

test "adjustScroll: scrolls up when selected is above visible area" {
    // Start scrolled down, then select something above
    var offset: usize = 5;
    adjustScroll(&offset, 2, 10, 15, false);
    try testing.expectEqual(@as(usize, 2), offset);
}

test "adjustScroll: accounts for path row below selected session" {
    // height=7 → max_vis=3. 4 sessions, all without path.
    // Select session 2 with path — needs 2 rows (session + path).
    var offset: usize = 0;
    adjustScroll(&offset, 2, 4, 7, true);
    // selected=2 with path needs rows for: sessions 0,1,2 + path = 4 rows
    // but max_vis=3, and there's a session below (▼ indicator), so available = 3-1 = 2
    // That's not enough for sessions 0,1,2+path. Must scroll.
    try testing.expect(offset > 0);
    try testing.expect(offset <= 2);
}

test "adjustScroll: accounts for scroll-up indicator" {
    // When offset > 0, ▲ steals a row from the visible area.
    // height=7 → max_vis=3. 6 sessions.
    var offset: usize = 1;
    // Select session 3. With ▲ indicator: avail = 3-1 = 2 (plus maybe ▼).
    adjustScroll(&offset, 3, 6, 7, false);
    // selected=3 must be visible
    try testing.expect(offset <= 3);
    // And we should still be scrolled past 0
    try testing.expect(offset > 0);
}

test "adjustScroll: zero sessions sets offset to 0" {
    var offset: usize = 5;
    adjustScroll(&offset, 0, 0, 15, false);
    try testing.expectEqual(@as(usize, 0), offset);
}

test "adjustScroll: zero height sets offset to 0" {
    var offset: usize = 3;
    adjustScroll(&offset, 2, 5, 0, false);
    try testing.expectEqual(@as(usize, 0), offset);
}

test "adjustScroll: tiny height (max_vis=0) sets offset to 0" {
    var offset: usize = 3;
    adjustScroll(&offset, 2, 5, 4, false); // max_vis=0 for height=4
    try testing.expectEqual(@as(usize, 0), offset);
}

test "adjustScroll: selected at end of list with no more below" {
    // height=7 → max_vis=3. 5 sessions. Select last (index 4).
    var offset: usize = 0;
    adjustScroll(&offset, 4, 5, 7, false);
    // No ▼ indicator needed. Must scroll so session 4 is visible.
    try testing.expect(offset <= 4);
    // With 3 visible rows and no ▼, sessions at offset, offset+1, offset+2 are visible.
    // selected=4 must be in [offset, offset+2], so offset >= 2.
    try testing.expect(offset >= 2);
}

test "adjustScroll: selected at end with path row" {
    // height=7 → max_vis=3. 5 sessions. Select last (index 4) with path.
    var offset: usize = 0;
    adjustScroll(&offset, 4, 5, 7, true);
    // Path takes extra row. No ▼ (last session). With ▲ (offset>0): avail = 3-1 = 2.
    // Need 2 rows for session+path, exactly fits in avail=2.
    try testing.expect(offset <= 4);
    try testing.expect(offset >= 2);
}

test "adjustScroll: never scrolls past selected" {
    // Edge case: make sure offset never exceeds selected
    var offset: usize = 0;
    adjustScroll(&offset, 1, 10, 7, true);
    try testing.expect(offset <= 1);
}

test "adjustScroll: large list scroll to middle" {
    // 20 sessions, height=10 → max_vis=6. Select session 12.
    var offset: usize = 0;
    adjustScroll(&offset, 12, 20, 10, false);
    // selected=12 must be visible. With ▲ (offset>0) and ▼ (more below):
    // avail = 6-1-1 = 4. offset must be >= 12-3 = 9.
    try testing.expect(offset >= 9);
    try testing.expect(offset <= 12);
}

test "adjustScroll: scrolling up from middle" {
    // offset=10, select session 5 (above view)
    var offset: usize = 10;
    adjustScroll(&offset, 5, 20, 10, false);
    try testing.expectEqual(@as(usize, 5), offset);
}

test "adjustScroll: first session selected, offset stays 0" {
    var offset: usize = 0;
    adjustScroll(&offset, 0, 10, 10, false);
    try testing.expectEqual(@as(usize, 0), offset);
}

test "adjustScroll: first session with path, offset stays 0" {
    var offset: usize = 0;
    adjustScroll(&offset, 0, 10, 10, true);
    try testing.expectEqual(@as(usize, 0), offset);
}

// -- Integration: adjustScroll + draw --

test "integration: adjustScroll then draw shows selected session visible" {
    // 6 sessions, height=7 (max_vis=3). Select session 4 (0-indexed).
    var ctx = try createTestWindow(30, 7);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    const sessions = [_]tmux.Session{
        testSession("alpha", 1),
        testSession("bravo", 1),
        testSession("charlie", 1),
        testSession("delta", 1),
        testSession("echo", 1),
        testSession("foxtrot", 1),
    };
    const selected: usize = 4;
    var offset: usize = 0;
    adjustScroll(&offset, selected, sessions.len, 7, false);

    draw(ctx.arena.allocator(), win, &sessions, selected, "", null, null, offset, &empty_watched);

    // The selected session "echo" must appear somewhere in the rendered rows.
    // Scan rows 1..4 (content rows) for 'e' at col 4.
    var found_echo = false;
    var row: u16 = 1;
    while (row < 5) : (row += 1) {
        if (std.mem.eql(u8, "e", readGrapheme(win, 4, row))) {
            // Verify it's the selected row (bold)
            const cell = win.readCell(4, row).?;
            if (cell.style.bold) {
                found_echo = true;
                break;
            }
        }
    }
    try testing.expect(found_echo);
}

test "integration: adjustScroll with path then draw shows both session and path" {
    // 6 sessions, height=7 (max_vis=3). Select session 4 with path.
    var ctx = try createTestWindow(30, 7);
    defer ctx.screen.deinit(testing.allocator);
    defer ctx.arena.deinit();
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ctx.screen.width,
        .height = ctx.screen.height,
        .screen = &ctx.screen,
    };

    const sessions = [_]tmux.Session{
        testSession("alpha", 1),
        testSession("bravo", 1),
        testSession("charlie", 1),
        testSession("delta", 1),
        testSessionWithPath("echo", 1, "/tmp/echo"),
        testSession("foxtrot", 1),
    };
    const selected: usize = 4;
    var offset: usize = 0;
    adjustScroll(&offset, selected, sessions.len, 7, true);

    draw(ctx.arena.allocator(), win, &sessions, selected, "", null, null, offset, &empty_watched);

    // "echo" must be visible and bold
    var echo_row: ?u16 = null;
    var row: u16 = 1;
    while (row < 5) : (row += 1) {
        if (std.mem.eql(u8, "e", readGrapheme(win, 4, row))) {
            const cell = win.readCell(4, row).?;
            if (cell.style.bold) {
                echo_row = row;
                break;
            }
        }
    }
    try testing.expect(echo_row != null);

    // Path should appear on the row below echo
    if (echo_row) |er| {
        const path_row = er + 1;
        if (path_row < 5) {
            const path_cell = win.readCell(4, path_row).?;
            try testing.expect(path_cell.style.italic);
            try testing.expectEqual(theme.dim, path_cell.style.fg);
        }
    }
}
