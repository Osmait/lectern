//! Window geometry: where every control, rail, panel, and page rectangle sits.
//!
//! The layout is a pure function of the window size and a few state flags, so
//! drawing and hit testing always agree by construction.

const std = @import("std");
const annotations = @import("book_read").annotations;

pub const Vec2 = extern struct {
    x: f32,
    y: f32,
};

pub const Size = struct {
    width: f32,
    height: f32,
};

pub const Rect = extern struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub const empty: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

    pub fn contains(self: Rect, point: Vec2) bool {
        return point.x >= self.x and point.x < self.x + self.w and
            point.y >= self.y and point.y < self.y + self.h;
    }

    pub fn isEmpty(self: Rect) bool {
        return self.w <= 0 or self.h <= 0;
    }

    pub fn centerX(self: Rect) f32 {
        return self.x + self.w / 2;
    }

    pub fn centerY(self: Rect) f32 {
        return self.y + self.h / 2;
    }

    pub fn inset(self: Rect, amount: f32) Rect {
        return .{
            .x = self.x + amount,
            .y = self.y + amount,
            .w = self.w - amount * 2,
            .h = self.h - amount * 2,
        };
    }
};

pub const header_height: f32 = 64;
pub const toolbar_top: f32 = 10;
pub const toolbar_button: f32 = 44;
pub const toolbar_gap: f32 = 8;
pub const toolbar_right_margin: f32 = 12;
pub const page_margin_x: f32 = 24;
pub const page_margin_y: f32 = 16;
pub const panel_minimum_width: f32 = 300;
pub const panel_maximum_width: f32 = 352;
pub const navigation_minimum_width: f32 = 124;
pub const navigation_maximum_width: f32 = 148;
pub const thumbnail_slot_height: f32 = 164;
pub const thumbnail_list_top: f32 = header_height + 48;
pub const thumbnail_bottom_margin: f32 = 12;
pub const thumbnail_scroll_step: f32 = 56;
pub const thumbnail_image_height: f32 = 124;

pub const Options = struct {
    document_open: bool,
    navigation_visible: bool,
    annotations_enabled: bool,
};

pub const ToolbarButton = enum {
    pages,
    open,
    previous,
    next,
    zoom_out,
    zoom_reset,
    zoom_in,
    jump,
    bookmark,
    theme,
    annotations,
};

pub const PanelControl = union(enum) {
    close,
    pen,
    eraser,
    color: annotations.Color,
    size: annotations.PenSize,
    undo,
    clear,
    done,
};

pub const PageEdge = enum { previous, next };

pub const Toolbar = struct {
    pages: Rect,
    open: Rect,
    previous: Rect,
    next: Rect,
    page_label: Rect,
    zoom_out: Rect,
    zoom_reset: Rect,
    zoom_in: Rect,
    jump: Rect,
    bookmark: Rect,
    theme: Rect,
    annotations: Rect,

    pub fn rectFor(self: Toolbar, button: ToolbarButton) Rect {
        return switch (button) {
            .pages => self.pages,
            .open => self.open,
            .previous => self.previous,
            .next => self.next,
            .zoom_out => self.zoom_out,
            .zoom_reset => self.zoom_reset,
            .zoom_in => self.zoom_in,
            .jump => self.jump,
            .bookmark => self.bookmark,
            .theme => self.theme,
            .annotations => self.annotations,
        };
    }
};

pub const Panel = struct {
    bounds: Rect,
    title_y: f32,
    ink_label_y: f32,
    width_label_y: f32,
    edit_divider_y: f32,
    completion_divider_y: f32,
    save_status_y: f32,
    close: Rect,
    pen: Rect,
    eraser: Rect,
    colors: [annotations.Color.swatches.len]Rect,
    sizes: [annotations.PenSize.all.len]Rect,
    undo: Rect,
    clear: Rect,
    done: Rect,
};

pub const VisibleThumbnails = struct {
    first: usize,
    end: usize,
};

pub const Layout = struct {
    window: Size,
    navigation_width: f32,
    panel_width: f32,
    content: Rect,
    toolbar: Toolbar,
    panel: ?Panel,

    pub fn compute(window: Size, options: Options) Layout {
        const navigation_width: f32 = if (options.navigation_visible)
            std.math.clamp(
                window.width * 0.105,
                navigation_minimum_width,
                navigation_maximum_width,
            )
        else
            0;
        const panel_width: f32 = if (options.annotations_enabled)
            panelWidthFor(window.width)
        else
            0;
        return .{
            .window = window,
            .navigation_width = navigation_width,
            .panel_width = panel_width,
            .content = .{
                .x = navigation_width,
                .y = header_height,
                .w = window.width - navigation_width - panel_width,
                .h = window.height - header_height,
            },
            .toolbar = computeToolbar(window.width),
            .panel = if (options.annotations_enabled) computePanel(window) else null,
        };
    }

    pub fn railRect(self: Layout) ?Rect {
        if (self.navigation_width <= 0) return null;
        return .{
            .x = 0,
            .y = header_height,
            .w = self.navigation_width,
            .h = self.window.height - header_height,
        };
    }

    /// Toolbar buttons accept clicks anywhere in the header column so the
    /// whole strip feels like one control bar.
    pub fn toolbarHit(self: Layout, point: Vec2, document_open: bool) ?ToolbarButton {
        if (point.y < 0 or point.y >= header_height) return null;
        const row = Vec2{ .x = point.x, .y = toolbar_top + toolbar_button / 2 };
        inline for (std.meta.fields(ToolbarButton)) |field| {
            const button: ToolbarButton = @enumFromInt(field.value);
            const enabled = button != .pages or document_open;
            if (enabled and self.toolbar.rectFor(button).contains(row)) return button;
        }
        return null;
    }

    pub fn panelHit(self: Layout, point: Vec2) ?PanelControl {
        const panel = self.panel orelse return null;
        if (!panel.bounds.contains(point)) return null;
        if (panel.close.contains(point)) return .close;
        if (panel.pen.contains(point)) return .pen;
        if (panel.eraser.contains(point)) return .eraser;
        for (panel.colors, annotations.Color.swatches) |rect, color| {
            if (rect.contains(point)) return .{ .color = color };
        }
        for (panel.sizes, annotations.PenSize.all) |rect, size| {
            if (rect.contains(point)) return .{ .size = size };
        }
        if (panel.undo.contains(point)) return .undo;
        if (panel.clear.contains(point)) return .clear;
        if (panel.done.contains(point)) return .done;
        return null;
    }

    pub fn pageEdge(self: Layout, point: Vec2) ?PageEdge {
        if (!self.content.contains(point)) return null;
        const relative_x = point.x - self.content.x;
        if (relative_x <= self.content.w * 0.25) return .previous;
        if (relative_x >= self.content.w * 0.75) return .next;
        return null;
    }

    /// Logical pixels per PDF point when the page is fitted to the reading
    /// area and then zoomed.
    pub fn pageDisplayScale(self: Layout, page_size: Size, zoom: f32) f32 {
        const available_width = @max(self.content.w - page_margin_x * 2, 1);
        const available_height = @max(self.content.h - page_margin_y * 2, 1);
        const fit = @min(available_width / page_size.width, available_height / page_size.height);
        return fit * zoom;
    }

    pub fn pageRect(self: Layout, page_size: Size, zoom: f32) Rect {
        const scale = self.pageDisplayScale(page_size, zoom);
        const width = page_size.width * scale;
        const height = page_size.height * scale;
        const available_height = self.content.h - page_margin_y * 2;
        return .{
            .x = self.content.x + (self.content.w - width) / 2,
            .y = header_height + page_margin_y + (available_height - height) / 2,
            .w = width,
            .h = height,
        };
    }

    pub fn thumbnailViewportHeight(self: Layout) f32 {
        return @max(self.window.height - thumbnail_list_top - thumbnail_bottom_margin, 0);
    }

    pub fn thumbnailMaxScroll(self: Layout, page_count: usize) f32 {
        const content_height = @as(f32, @floatFromInt(page_count)) * thumbnail_slot_height;
        return @max(content_height - self.thumbnailViewportHeight(), 0);
    }

    pub fn clampThumbnailScroll(self: Layout, scroll: f32, page_count: usize) f32 {
        return std.math.clamp(scroll, 0, self.thumbnailMaxScroll(page_count));
    }

    pub fn scrollThumbnails(self: Layout, scroll: f32, amount: f32, page_count: usize) f32 {
        return self.clampThumbnailScroll(scroll - amount * thumbnail_scroll_step, page_count);
    }

    /// Scrolls just enough for the selected page to be fully visible.
    pub fn revealThumbnail(
        self: Layout,
        scroll: f32,
        page_index: usize,
        page_count: usize,
    ) f32 {
        const viewport_height = self.thumbnailViewportHeight();
        const item_top = @as(f32, @floatFromInt(page_index)) * thumbnail_slot_height;
        const item_bottom = item_top + thumbnail_slot_height;
        var next_scroll = scroll;
        if (item_top < scroll) next_scroll = item_top;
        if (item_bottom > scroll + viewport_height) next_scroll = item_bottom - viewport_height;
        return self.clampThumbnailScroll(next_scroll, page_count);
    }

    pub fn thumbnailAt(self: Layout, point: Vec2, scroll: f32, page_count: usize) ?usize {
        if (self.navigation_width <= 0 or page_count == 0) return null;
        if (point.x < 0 or point.x >= self.navigation_width) return null;
        if (point.y < thumbnail_list_top or point.y >= self.window.height) return null;
        const content_y = point.y - thumbnail_list_top + scroll;
        if (content_y < 0) return null;
        const page_index: usize = @intFromFloat(content_y / thumbnail_slot_height);
        if (page_index >= page_count) return null;
        return page_index;
    }

    pub fn visibleThumbnails(self: Layout, scroll: f32, page_count: usize) VisibleThumbnails {
        if (page_count == 0) return .{ .first = 0, .end = 0 };
        const first: usize = @intFromFloat(@max(scroll, 0) / thumbnail_slot_height);
        const span: usize = @intFromFloat(
            (self.window.height - thumbnail_list_top) / thumbnail_slot_height,
        );
        return .{
            .first = @min(first, page_count),
            .end = @min(first + span + 2, page_count),
        };
    }

    pub fn thumbnailSlot(self: Layout, page_index: usize, scroll: f32) Rect {
        const slot_y = thumbnail_list_top - scroll +
            @as(f32, @floatFromInt(page_index)) * thumbnail_slot_height;
        return .{
            .x = 8,
            .y = slot_y,
            .w = self.navigation_width - 16,
            .h = thumbnail_slot_height - 4,
        };
    }

    pub fn thumbnailImageBounds(self: Layout, slot: Rect) Rect {
        return .{
            .x = 16,
            .y = slot.y + 4,
            .w = self.navigation_width - 32,
            .h = thumbnail_image_height,
        };
    }
};

fn panelWidthFor(window_width: f32) f32 {
    return std.math.clamp(window_width * 0.229, panel_minimum_width, panel_maximum_width);
}

fn takeRight(right: *f32, width: f32) Rect {
    right.* -= width;
    const rect = Rect{ .x = right.*, .y = toolbar_top, .w = width, .h = toolbar_button };
    right.* -= toolbar_gap;
    return rect;
}

fn computeToolbar(window_width: f32) Toolbar {
    var toolbar: Toolbar = undefined;
    toolbar.pages = .{ .x = 124, .y = toolbar_top, .w = toolbar_button, .h = toolbar_button };
    toolbar.open = .{
        .x = 176,
        .y = toolbar_top,
        .w = if (window_width > 1000) 220 else 92,
        .h = toolbar_button,
    };

    var right = window_width - toolbar_right_margin;
    toolbar.annotations = takeRight(&right, toolbar_button);
    toolbar.theme = takeRight(&right, toolbar_button);
    toolbar.bookmark = takeRight(&right, toolbar_button);
    toolbar.jump = takeRight(&right, toolbar_button);
    toolbar.zoom_in = takeRight(&right, toolbar_button);
    toolbar.zoom_reset = takeRight(&right, 64);
    toolbar.zoom_out = takeRight(&right, toolbar_button);

    // The next button ends 116 logical pixels right of the center, so keeping
    // the center this far from the first action leaves one gap between them.
    const preferred_center = window_width * 0.49;
    const maximum_center = toolbar.zoom_out.x - (72 + toolbar_button + toolbar_gap);
    const center = @min(preferred_center, maximum_center);
    toolbar.previous = .{
        .x = center - 108,
        .y = toolbar_top,
        .w = toolbar_button,
        .h = toolbar_button,
    };
    toolbar.next = .{
        .x = center + 72,
        .y = toolbar_top,
        .w = toolbar_button,
        .h = toolbar_button,
    };
    toolbar.page_label = .{
        .x = toolbar.previous.x + toolbar.previous.w,
        .y = toolbar_top,
        .w = toolbar.next.x - toolbar.previous.x - toolbar.previous.w,
        .h = toolbar_button,
    };
    return toolbar;
}

fn computePanel(window: Size) Panel {
    const width = panelWidthFor(window.width);
    const left = window.width - width;
    const available = window.height - header_height;
    const content_left = left + 24;
    const inner_width = width - 40;
    const tool_width = (inner_width - 8) / 2;
    const tool_top = header_height + available * 0.10;
    const title_y = header_height + available * 0.05;

    var panel = Panel{
        .bounds = .{ .x = left, .y = header_height, .w = width, .h = available },
        .title_y = title_y,
        .ink_label_y = header_height + available * 0.20,
        .width_label_y = header_height + available * 0.344,
        .edit_divider_y = header_height + available * 0.484,
        .completion_divider_y = header_height + available * 0.653,
        .save_status_y = header_height + available * 0.77,
        .close = .{ .x = left + width - 52, .y = title_y - 16, .w = 44, .h = 44 },
        .pen = .{ .x = content_left, .y = tool_top, .w = tool_width, .h = 60 },
        .eraser = .{
            .x = content_left + tool_width + 8,
            .y = tool_top,
            .w = tool_width,
            .h = 60,
        },
        .colors = undefined,
        .sizes = undefined,
        .undo = .{
            .x = content_left,
            .y = header_height + available * 0.504,
            .w = inner_width,
            .h = 44,
        },
        .clear = .{
            .x = content_left,
            .y = header_height + available * 0.563,
            .w = inner_width,
            .h = 44,
        },
        .done = .{
            .x = content_left,
            .y = header_height + available * 0.685,
            .w = inner_width,
            .h = 48,
        },
    };

    const swatch_y = header_height + available * 0.27;
    const swatch_step = inner_width / @as(f32, @floatFromInt(panel.colors.len));
    for (&panel.colors, 0..) |*rect, index| {
        const center_x = content_left - 8 + swatch_step * (@as(f32, @floatFromInt(index)) + 0.5);
        rect.* = .{ .x = center_x - 20, .y = swatch_y - 22, .w = 40, .h = 44 };
    }

    const size_top = header_height + available * 0.38;
    const size_width = (inner_width - 16) / @as(f32, @floatFromInt(panel.sizes.len));
    for (&panel.sizes, 0..) |*rect, index| {
        rect.* = .{
            .x = content_left + @as(f32, @floatFromInt(index)) * (size_width + 8),
            .y = size_top,
            .w = size_width,
            .h = 58,
        };
    }
    return panel;
}

const test_window = Size{ .width = 1100, .height = 820 };

fn testLayout(options: Options) Layout {
    return Layout.compute(test_window, options);
}

test "toolbar buttons never overlap and stay inside the header" {
    for ([_]f32{ 900, 1100, 1300, 1536, 2400 }) |width| {
        const layout = Layout.compute(.{ .width = width, .height = 820 }, .{
            .document_open = true,
            .navigation_visible = true,
            .annotations_enabled = true,
        });
        const buttons = std.meta.fields(ToolbarButton);
        inline for (buttons, 0..) |field, index| {
            const rect = layout.toolbar.rectFor(@enumFromInt(field.value));
            try std.testing.expect(rect.x >= 0);
            try std.testing.expect(rect.x + rect.w <= width);
            try std.testing.expect(rect.y + rect.h <= header_height);
            inline for (buttons[index + 1 ..]) |other_field| {
                const other = layout.toolbar.rectFor(@enumFromInt(other_field.value));
                const separated = rect.x + rect.w <= other.x or other.x + other.w <= rect.x;
                try std.testing.expect(separated);
            }
        }
        try std.testing.expect(layout.toolbar.page_label.w > 100);
    }
}

test "toolbar hit testing returns every button and nothing between them" {
    const layout = testLayout(.{
        .document_open = true,
        .navigation_visible = true,
        .annotations_enabled = false,
    });
    inline for (std.meta.fields(ToolbarButton)) |field| {
        const button: ToolbarButton = @enumFromInt(field.value);
        const rect = layout.toolbar.rectFor(button);
        const center = Vec2{ .x = rect.centerX(), .y = 5 };
        try std.testing.expectEqual(button, layout.toolbarHit(center, true).?);
    }
    const between = Vec2{ .x = layout.toolbar.pages.x + layout.toolbar.pages.w + 2, .y = 30 };
    try std.testing.expectEqual(@as(?ToolbarButton, null), layout.toolbarHit(between, true));
    try std.testing.expectEqual(@as(?ToolbarButton, null), layout.toolbarHit(.{
        .x = layout.toolbar.pages.centerX(),
        .y = 30,
    }, false));
    try std.testing.expectEqual(@as(?ToolbarButton, null), layout.toolbarHit(.{
        .x = layout.toolbar.open.centerX(),
        .y = header_height,
    }, true));
}

test "the annotation panel occupies the right edge and hit tests every control" {
    const layout = testLayout(.{
        .document_open = true,
        .navigation_visible = true,
        .annotations_enabled = true,
    });
    const panel = layout.panel.?;
    try std.testing.expectApproxEqAbs(test_window.width, panel.bounds.x + panel.bounds.w, 0.01);
    try std.testing.expect(layout.content.w + layout.navigation_width + panel.bounds.w ==
        test_window.width);

    const center = struct {
        fn of(rect: Rect) Vec2 {
            return .{ .x = rect.centerX(), .y = rect.centerY() };
        }
    };
    try std.testing.expectEqual(PanelControl.close, layout.panelHit(center.of(panel.close)).?);
    try std.testing.expectEqual(PanelControl.pen, layout.panelHit(center.of(panel.pen)).?);
    try std.testing.expectEqual(PanelControl.eraser, layout.panelHit(center.of(panel.eraser)).?);
    for (panel.colors, annotations.Color.swatches) |rect, color| {
        try std.testing.expectEqual(color, layout.panelHit(center.of(rect)).?.color);
    }
    for (panel.sizes, annotations.PenSize.all) |rect, size| {
        try std.testing.expectEqual(size, layout.panelHit(center.of(rect)).?.size);
    }
    try std.testing.expectEqual(PanelControl.undo, layout.panelHit(center.of(panel.undo)).?);
    try std.testing.expectEqual(PanelControl.clear, layout.panelHit(center.of(panel.clear)).?);
    try std.testing.expectEqual(PanelControl.done, layout.panelHit(center.of(panel.done)).?);
    try std.testing.expectEqual(@as(?PanelControl, null), layout.panelHit(.{
        .x = panel.bounds.x - 1,
        .y = panel.pen.centerY(),
    }));
    try std.testing.expectEqual(@as(?PanelControl, null), layout.panelHit(.{
        .x = panel.bounds.x + 4,
        .y = panel.bounds.y + 2,
    }));

    const closed = testLayout(.{
        .document_open = true,
        .navigation_visible = true,
        .annotations_enabled = false,
    });
    try std.testing.expectEqual(@as(?Panel, null), closed.panel);
    try std.testing.expectEqual(@as(?PanelControl, null), closed.panelHit(center.of(panel.pen)));
}

test "page edges split the reading area into quarters" {
    const layout = testLayout(.{
        .document_open = true,
        .navigation_visible = true,
        .annotations_enabled = false,
    });
    const left = layout.content.x;
    const outside = layout.pageEdge(.{ .x = left - 1, .y = 400 });
    try std.testing.expectEqual(@as(?PageEdge, null), outside);
    const near_left = layout.pageEdge(.{ .x = left + 10, .y = 400 });
    try std.testing.expectEqual(PageEdge.previous, near_left.?);
    try std.testing.expectEqual(@as(?PageEdge, null), layout.pageEdge(.{
        .x = layout.content.centerX(),
        .y = 400,
    }));
    try std.testing.expectEqual(PageEdge.next, layout.pageEdge(.{
        .x = left + layout.content.w - 10,
        .y = 400,
    }).?);
    const in_header = layout.pageEdge(.{ .x = left + 10, .y = 10 });
    try std.testing.expectEqual(@as(?PageEdge, null), in_header);
}

test "page rectangles fit the reading area and scale with zoom" {
    const layout = testLayout(.{
        .document_open = true,
        .navigation_visible = true,
        .annotations_enabled = false,
    });
    const letter = Size{ .width = 612, .height = 792 };
    const fitted = layout.pageRect(letter, 1.0);
    try std.testing.expect(fitted.x >= layout.content.x + page_margin_x - 0.01);
    try std.testing.expect(fitted.y >= header_height + page_margin_y - 0.01);
    try std.testing.expect(fitted.y + fitted.h <= test_window.height - page_margin_y + 0.01);
    try std.testing.expectApproxEqAbs(letter.width / letter.height, fitted.w / fitted.h, 0.001);

    const zoomed = layout.pageRect(letter, 2.0);
    try std.testing.expectApproxEqAbs(fitted.w * 2, zoomed.w, 0.01);
    try std.testing.expectApproxEqAbs(fitted.centerX(), zoomed.centerX(), 0.01);
    try std.testing.expectApproxEqAbs(
        layout.pageDisplayScale(letter, 1.0) * 2,
        layout.pageDisplayScale(letter, 2.0),
        0.0001,
    );
}

test "thumbnail rail scrolls independently and maps visible pages" {
    const hidden = testLayout(.{
        .document_open = true,
        .navigation_visible = false,
        .annotations_enabled = false,
    });
    try std.testing.expectEqual(@as(f32, 0), hidden.navigation_width);
    try std.testing.expectEqual(@as(?Rect, null), hidden.railRect());
    const hidden_hit = hidden.thumbnailAt(.{ .x = 60, .y = 120 }, 0, 10);
    try std.testing.expectEqual(@as(?usize, null), hidden_hit);

    const narrow = Layout.compute(.{ .width = 900, .height = 820 }, .{
        .document_open = true,
        .navigation_visible = true,
        .annotations_enabled = false,
    });
    try std.testing.expectEqual(navigation_minimum_width, narrow.navigation_width);
    const wide = Layout.compute(.{ .width = 1536, .height = 820 }, .{
        .document_open = true,
        .navigation_visible = true,
        .annotations_enabled = false,
    });
    try std.testing.expectEqual(navigation_maximum_width, wide.navigation_width);

    const layout = testLayout(.{
        .document_open = true,
        .navigation_visible = true,
        .annotations_enabled = false,
    });
    const at = struct {
        fn hit(rail: Layout, x: f32, y: f32, scroll: f32, page_count: usize) ?usize {
            return rail.thumbnailAt(.{ .x = x, .y = y }, scroll, page_count);
        }
    }.hit;
    try std.testing.expectEqual(@as(?usize, 0), at(layout, 60, 120, 0, 10));
    try std.testing.expectEqual(@as(?usize, 1), at(layout, 60, 280, 0, 10));
    try std.testing.expectEqual(@as(?usize, 2), at(layout, 60, 120, 328, 10));
    try std.testing.expectEqual(@as(?usize, null), at(layout, 140, 120, 0, 10));
    try std.testing.expectEqual(@as(?usize, null), at(layout, 60, 100, 0, 10));
    try std.testing.expectEqual(@as(?usize, null), at(layout, 60, 120, 0, 0));
    try std.testing.expectEqual(@as(?usize, 0), at(layout, 60, 120, 0, 1));

    const short = Layout.compute(.{ .width = 1100, .height = 600 }, .{
        .document_open = true,
        .navigation_visible = true,
        .annotations_enabled = false,
    });
    try std.testing.expectEqual(@as(f32, 56), short.scrollThumbnails(0, -1, 10));
    try std.testing.expectEqual(@as(f32, 0), short.scrollThumbnails(0, 1, 10));
    try std.testing.expectEqual(@as(f32, 1164), short.scrollThumbnails(1160, -1, 10));
    try std.testing.expectEqual(@as(f32, 0), layout.scrollThumbnails(80, -1, 1));
    try std.testing.expectEqual(@as(f32, 0), layout.revealThumbnail(0, 0, 10));
    try std.testing.expect(layout.revealThumbnail(0, 9, 10) > 0);
    try std.testing.expectEqual(@as(f32, 0), layout.revealThumbnail(500, 0, 10));

    const visible = layout.visibleThumbnails(0, 10);
    try std.testing.expectEqual(@as(usize, 0), visible.first);
    try std.testing.expect(visible.end >= 5 and visible.end <= 10);
    const tail = layout.visibleThumbnails(layout.thumbnailMaxScroll(10), 10);
    try std.testing.expectEqual(@as(usize, 10), tail.end);
    try std.testing.expectEqual(@as(usize, 0), layout.visibleThumbnails(0, 0).end);
}
