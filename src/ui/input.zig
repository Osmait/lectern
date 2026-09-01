//! Translates raw window input into typed commands using the current layout.
//!
//! Raw input carries physical facts: a key, a mouse position, a wheel step.
//! This module decides what those facts mean for the reader.

const std = @import("std");
const annotations = @import("book_read").annotations;
const commands = @import("../commands.zig");
const layout_module = @import("layout.zig");

const Command = commands.Command;
const Layout = layout_module.Layout;
const Rect = layout_module.Rect;
const Vec2 = layout_module.Vec2;

pub const Kind = enum(u8) {
    none = 0,
    quit,
    key_down,
    mouse_down,
    mouse_up,
    mouse_motion,
    mouse_wheel,
    file,
    dialog_closed,
    window,
};

pub const Key = enum(u8) {
    none = 0,
    escape,
    left,
    right,
    page_up,
    page_down,
    space,
    comma,
    period,
    home,
    end,
    plus,
    minus,
    zero,
    b,
    c,
    d,
    e,
    j,
    n,
    o,
    p,
    s,
    t,
    u,
    x,
};

pub const Button = enum(u8) {
    none = 0,
    left,
    other,
};

pub const RawInput = struct {
    kind: Kind,
    position: Vec2 = .{ .x = 0, .y = 0 },
    wheel: f32 = 0,
    key: Key = .none,
    button: Button = .none,
    left_held: bool = false,
    /// Owned by the application allocator; released after handling.
    path: ?[]const u8 = null,

    pub fn hasPosition(self: RawInput) bool {
        return switch (self.kind) {
            .mouse_down, .mouse_up, .mouse_motion, .mouse_wheel => true,
            else => false,
        };
    }
};

/// Everything translation needs to know about the current interface state.
pub const State = struct {
    layout: Layout,
    page_rect: ?Rect,
    tool: annotations.Tool,
    document_open: bool,
    page_count: usize,
    thumbnail_scroll: f32,
    stroke_active: bool,
};

pub fn keyCommand(key: Key) ?Command {
    return switch (key) {
        .none => null,
        .escape => .quit,
        .right, .page_down, .space, .period => .next_page,
        .left, .page_up, .comma => .previous_page,
        .home => .first_page,
        .end => .last_page,
        .plus => .zoom_in,
        .minus => .zoom_out,
        .zero => .zoom_reset,
        .b => .toggle_bookmark,
        .c => .cycle_color,
        .d => .toggle_dark_mode,
        .e => .eraser,
        .j => .jump_bookmark,
        .n => .notes_off,
        .o => .open_dialog,
        .p => .pen,
        .s => .toggle_pages,
        .t => .cycle_size,
        .u => .note_undo,
        .x => .note_clear,
    };
}

pub fn translate(raw: RawInput, state: State) ?Command {
    return switch (raw.kind) {
        .none => null,
        .quit => .quit,
        .window => .redraw,
        .key_down => keyCommand(raw.key),
        .file => if (raw.path) |path| .{ .open_path = path } else null,
        .dialog_closed => .dialog_closed,
        .mouse_wheel => translateWheel(raw, state),
        .mouse_down => translateMouseDown(raw, state),
        .mouse_motion => translateMotion(raw, state),
        .mouse_up => if (raw.button == .left and state.tool != .off) .draw_end else null,
    };
}

fn translateWheel(raw: RawInput, state: State) ?Command {
    if (state.layout.railRect()) |rail| {
        if (rail.contains(raw.position)) return .{ .scroll_thumbnails = raw.wheel };
    }
    if (raw.wheel < 0) return .next_page;
    if (raw.wheel > 0) return .previous_page;
    return null;
}

fn translateMouseDown(raw: RawInput, state: State) ?Command {
    if (raw.button != .left) return null;
    const point = raw.position;
    if (state.layout.toolbarHit(point, state.document_open)) |button| {
        return toolbarCommand(button);
    }
    if (point.y < layout_module.header_height) return null;
    if (state.layout.thumbnailAt(point, state.thumbnail_scroll, state.page_count)) |page_index| {
        return .{ .select_page = page_index };
    }
    if (state.layout.railRect()) |rail| {
        if (rail.contains(point)) return null;
    }
    if (state.layout.panelHit(point)) |control| return panelCommand(control);
    if (state.layout.panel) |panel| {
        if (panel.bounds.contains(point)) return null;
    }
    if (state.tool != .off) {
        if (normalizedPagePoint(state.page_rect, point)) |page_point| {
            return .{ .draw_begin = page_point };
        }
    }
    return switch (state.layout.pageEdge(point) orelse return null) {
        .previous => .previous_page,
        .next => .next_page,
    };
}

fn translateMotion(raw: RawInput, state: State) ?Command {
    if (state.tool == .off) return null;
    if (raw.left_held) {
        const page_point = normalizedPagePoint(state.page_rect, raw.position) orelse return null;
        return .{ .draw_move = page_point };
    }
    // A release that happened outside the window never arrives as a button
    // event, so a hover with no button held closes the open stroke.
    if (state.stroke_active) return .draw_end;
    return null;
}

fn toolbarCommand(button: layout_module.ToolbarButton) Command {
    return switch (button) {
        .pages => .toggle_pages,
        .open => .open_dialog,
        .previous => .previous_page,
        .next => .next_page,
        .zoom_out => .zoom_out,
        .zoom_reset => .zoom_reset,
        .zoom_in => .zoom_in,
        .jump => .jump_bookmark,
        .bookmark => .toggle_bookmark,
        .theme => .toggle_dark_mode,
        .annotations => .pen,
    };
}

fn panelCommand(control: layout_module.PanelControl) Command {
    return switch (control) {
        .close, .done => .notes_off,
        .pen => .pen,
        .eraser => .eraser,
        .color => |color| .{ .select_color = color },
        .size => |size| .{ .select_size = size },
        .undo => .note_undo,
        .clear => .note_clear,
    };
}

pub fn normalizedPagePoint(page_rect: ?Rect, point: Vec2) ?annotations.Point {
    const rect = page_rect orelse return null;
    if (rect.isEmpty()) return null;
    if (point.x < rect.x or point.x > rect.x + rect.w or
        point.y < rect.y or point.y > rect.y + rect.h) return null;
    return .{
        .x = (point.x - rect.x) / rect.w,
        .y = (point.y - rect.y) / rect.h,
    };
}

fn testState(options: struct {
    tool: annotations.Tool = .off,
    stroke_active: bool = false,
    navigation_visible: bool = true,
}) State {
    const layout = Layout.compute(.{ .width = 1100, .height = 820 }, .{
        .document_open = true,
        .navigation_visible = options.navigation_visible,
        .annotations_enabled = options.tool != .off,
    });
    return .{
        .layout = layout,
        .page_rect = layout.pageRect(.{ .width = 612, .height = 792 }, 1.0),
        .tool = options.tool,
        .document_open = true,
        .page_count = 10,
        .thumbnail_scroll = 0,
        .stroke_active = options.stroke_active,
    };
}

test "keyboard mapping covers navigation, reading, and annotation commands" {
    const expectations = [_]struct { Key, Command }{
        .{ .escape, .quit },
        .{ .right, .next_page },
        .{ .space, .next_page },
        .{ .left, .previous_page },
        .{ .page_up, .previous_page },
        .{ .home, .first_page },
        .{ .end, .last_page },
        .{ .plus, .zoom_in },
        .{ .minus, .zoom_out },
        .{ .zero, .zoom_reset },
        .{ .b, .toggle_bookmark },
        .{ .c, .cycle_color },
        .{ .d, .toggle_dark_mode },
        .{ .e, .eraser },
        .{ .j, .jump_bookmark },
        .{ .n, .notes_off },
        .{ .o, .open_dialog },
        .{ .p, .pen },
        .{ .s, .toggle_pages },
        .{ .t, .cycle_size },
        .{ .u, .note_undo },
        .{ .x, .note_clear },
    };
    for (expectations) |expectation| {
        try std.testing.expectEqual(expectation[1], keyCommand(expectation[0]).?);
    }
    try std.testing.expectEqual(@as(?Command, null), keyCommand(.none));
    try std.testing.expectEqual(
        Command.zoom_in,
        translate(.{ .kind = .key_down, .key = .plus }, testState(.{})).?,
    );
}

test "window points normalize to page coordinates and reject invalid rectangles" {
    const rect = Rect{ .x = 100, .y = 200, .w = 400, .h = 800 };
    const inside = normalizedPagePoint(rect, .{ .x = 300, .y = 600 }).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), inside.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), inside.y, 0.0001);
    try std.testing.expectEqual(@as(?annotations.Point, null), normalizedPagePoint(rect, .{
        .x = 99,
        .y = 600,
    }));
    try std.testing.expectEqual(@as(?annotations.Point, null), normalizedPagePoint(.{
        .x = 100,
        .y = 200,
        .w = 0,
        .h = 800,
    }, .{ .x = 100, .y = 600 }));
    try std.testing.expectEqual(@as(?annotations.Point, null), normalizedPagePoint(null, .{
        .x = 100,
        .y = 600,
    }));
}

test "mouse clicks route to the toolbar, rail, panel, page, and edges" {
    const state = testState(.{ .tool = .pen });
    const toolbar = state.layout.toolbar;
    try std.testing.expectEqual(Command.next_page, translate(.{
        .kind = .mouse_down,
        .button = .left,
        .position = .{ .x = toolbar.next.centerX(), .y = 30 },
    }, state).?);
    try std.testing.expectEqual(Command.toggle_pages, translate(.{
        .kind = .mouse_down,
        .button = .left,
        .position = .{ .x = toolbar.pages.centerX(), .y = 30 },
    }, state).?);
    try std.testing.expectEqual(@as(?Command, null), translate(.{
        .kind = .mouse_down,
        .button = .other,
        .position = .{ .x = toolbar.next.centerX(), .y = 30 },
    }, state));

    const selection = translate(.{
        .kind = .mouse_down,
        .button = .left,
        .position = .{ .x = 60, .y = 280 },
    }, state).?;
    try std.testing.expectEqual(@as(usize, 1), selection.select_page);
    try std.testing.expectEqual(@as(?Command, null), translate(.{
        .kind = .mouse_down,
        .button = .left,
        .position = .{ .x = 60, .y = 90 },
    }, state));

    const panel = state.layout.panel.?;
    const color = translate(.{
        .kind = .mouse_down,
        .button = .left,
        .position = .{ .x = panel.colors[2].centerX(), .y = panel.colors[2].centerY() },
    }, state).?;
    try std.testing.expectEqual(annotations.Color.green, color.select_color);
    try std.testing.expectEqual(Command.notes_off, translate(.{
        .kind = .mouse_down,
        .button = .left,
        .position = .{ .x = panel.done.centerX(), .y = panel.done.centerY() },
    }, state).?);
    try std.testing.expectEqual(@as(?Command, null), translate(.{
        .kind = .mouse_down,
        .button = .left,
        .position = .{ .x = panel.bounds.x + 2, .y = panel.bounds.y + 2 },
    }, state));

    const page_rect = state.page_rect.?;
    const begin = translate(.{
        .kind = .mouse_down,
        .button = .left,
        .position = .{ .x = page_rect.centerX(), .y = page_rect.centerY() },
    }, state).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), begin.draw_begin.x, 0.001);

    const reading = testState(.{});
    try std.testing.expectEqual(Command.previous_page, translate(.{
        .kind = .mouse_down,
        .button = .left,
        .position = .{ .x = reading.layout.content.x + 5, .y = 400 },
    }, reading).?);
    try std.testing.expectEqual(Command.next_page, translate(.{
        .kind = .mouse_down,
        .button = .left,
        .position = .{ .x = reading.layout.content.x + reading.layout.content.w - 5, .y = 400 },
    }, reading).?);
    try std.testing.expectEqual(@as(?Command, null), translate(.{
        .kind = .mouse_down,
        .button = .left,
        .position = .{ .x = reading.layout.content.centerX(), .y = 30 + 800 },
    }, reading));
}

test "wheel scrolls the rail or turns pages" {
    const state = testState(.{});
    try std.testing.expectEqual(Command.next_page, translate(.{
        .kind = .mouse_wheel,
        .wheel = -1,
        .position = .{ .x = 600, .y = 400 },
    }, state).?);
    try std.testing.expectEqual(Command.previous_page, translate(.{
        .kind = .mouse_wheel,
        .wheel = 1,
        .position = .{ .x = 600, .y = 400 },
    }, state).?);
    try std.testing.expectEqual(@as(?Command, null), translate(.{
        .kind = .mouse_wheel,
        .wheel = 0,
        .position = .{ .x = 600, .y = 400 },
    }, state));
    const scroll = translate(.{
        .kind = .mouse_wheel,
        .wheel = -1,
        .position = .{ .x = 40, .y = 400 },
    }, state).?;
    try std.testing.expectEqual(@as(f32, -1), scroll.scroll_thumbnails);
    const hidden_rail = testState(.{ .navigation_visible = false });
    try std.testing.expectEqual(Command.next_page, translate(.{
        .kind = .mouse_wheel,
        .wheel = -1,
        .position = .{ .x = 40, .y = 400 },
    }, hidden_rail).?);
}

test "drags extend strokes and releases finish them" {
    const state = testState(.{ .tool = .pen, .stroke_active = true });
    const page_rect = state.page_rect.?;
    const move = translate(.{
        .kind = .mouse_motion,
        .left_held = true,
        .position = .{ .x = page_rect.x + page_rect.w * 0.25, .y = page_rect.centerY() },
    }, state).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), move.draw_move.x, 0.001);
    try std.testing.expectEqual(@as(?Command, null), translate(.{
        .kind = .mouse_motion,
        .left_held = true,
        .position = .{ .x = 5, .y = 5 },
    }, state));
    try std.testing.expectEqual(Command.draw_end, translate(.{
        .kind = .mouse_motion,
        .left_held = false,
        .position = .{ .x = page_rect.centerX(), .y = page_rect.centerY() },
    }, state).?);
    try std.testing.expectEqual(Command.draw_end, translate(.{
        .kind = .mouse_up,
        .button = .left,
        .position = .{ .x = 5, .y = 5 },
    }, state).?);

    const idle = testState(.{ .tool = .pen });
    try std.testing.expectEqual(@as(?Command, null), translate(.{
        .kind = .mouse_motion,
        .position = .{ .x = page_rect.centerX(), .y = page_rect.centerY() },
    }, idle));
    const reading = testState(.{});
    try std.testing.expectEqual(@as(?Command, null), translate(.{
        .kind = .mouse_up,
        .button = .left,
        .position = .{ .x = 5, .y = 5 },
    }, reading));
}

test "files, dialogs, windows, and quit translate directly" {
    const state = testState(.{});
    const opened = translate(.{ .kind = .file, .path = "book.pdf" }, state).?;
    try std.testing.expectEqualStrings("book.pdf", opened.open_path);
    try std.testing.expectEqual(@as(?Command, null), translate(.{ .kind = .file }, state));
    try std.testing.expectEqual(
        Command.dialog_closed,
        translate(.{ .kind = .dialog_closed }, state).?,
    );
    try std.testing.expectEqual(Command.redraw, translate(.{ .kind = .window }, state).?);
    try std.testing.expectEqual(Command.quit, translate(.{ .kind = .quit }, state).?);
    try std.testing.expectEqual(@as(?Command, null), translate(.{ .kind = .none }, state));
    try std.testing.expect((RawInput{ .kind = .mouse_motion }).hasPosition());
    try std.testing.expect(!(RawInput{ .kind = .key_down }).hasPosition());
}
