//! Window geometry: where every control, rail, panel, and page rectangle sits.
//!
//! The layout is a pure function of the window size and a few state flags, so
//! drawing and hit testing always agree by construction.

const std = @import("std");
const annotations = @import("book_read").annotations;

/// Window points share the native bridge's memory layout, so vertex lists are
/// handed over without copying. The platform adapter checks the match.
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

    pub fn bottom(self: Rect) f32 {
        return self.y + self.h;
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

/// The window the native bridge opens; the in-memory backend uses the same
/// size so tests see the production geometry.
pub const default_window = Size{ .width = 1100, .height = 820 };
/// The smallest window the native bridge allows. Every control must fit at
/// this size; the layout tests check it.
pub const minimum_window = Size{ .width = 900, .height = 600 };
/// Longest page side ever rasterized, in device pixels. This is the display
/// policy; the native bridge enforces a larger hard limit on top of it.
pub const maximum_page_pixels: f32 = 3072;

pub const header_height: f32 = 64;
pub const toolbar_top: f32 = 10;
pub const toolbar_button: f32 = 44;
pub const toolbar_gap: f32 = 8;
pub const toolbar_right_margin: f32 = 12;
pub const wordmark_x: f32 = 28;
pub const wordmark_y: f32 = 20;
pub const pages_button_x: f32 = 124;
pub const open_button_x: f32 = 176;
pub const open_button_wide_width: f32 = 220;
pub const open_button_narrow_width: f32 = 92;
/// Windows narrower than this show the document title in a short button.
pub const open_button_wide_threshold: f32 = 1000;
pub const zoom_reset_width: f32 = 64;
/// The previous and next buttons straddle the page label around the toolbar
/// center; these are their distances from that center.
pub const navigation_previous_offset: f32 = 108;
pub const navigation_next_offset: f32 = 72;
/// The navigation cluster sits slightly left of the middle, leaving room for
/// the zoom and bookmark actions on the right.
pub const toolbar_center_ratio: f32 = 0.49;
pub const page_margin_x: f32 = 24;
pub const page_margin_y: f32 = 16;
pub const panel_minimum_width: f32 = 300;
pub const panel_maximum_width: f32 = 352;
pub const panel_width_ratio: f32 = 0.229;
pub const panel_padding_left: f32 = 24;
pub const panel_padding_right: f32 = 16;
pub const panel_padding_bottom: f32 = 16;
pub const panel_tab_gap: f32 = 8;
pub const panel_size_gap: f32 = 8;
pub const panel_label_height: f32 = 20;
pub const panel_status_height: f32 = 24;
pub const navigation_minimum_width: f32 = 124;
pub const navigation_maximum_width: f32 = 148;
pub const navigation_width_ratio: f32 = 0.105;
pub const thumbnail_slot_height: f32 = 164;
pub const thumbnail_list_top: f32 = header_height + 48;
pub const thumbnail_bottom_margin: f32 = 12;
pub const thumbnail_scroll_step: f32 = 56;
pub const thumbnail_image_height: f32 = 124;
pub const thumbnail_label_offset: f32 = 136;
/// The rail scrollbar: a thin thumb at the right edge that widens while it
/// is hovered or dragged, and a wider strip of the rail that catches the
/// pointer so the thin thumb can actually be grabbed.
pub const scrollbar_width: f32 = 2;
pub const scrollbar_active_width: f32 = 6;
pub const scrollbar_right_margin: f32 = 2;
pub const scrollbar_hit_width: f32 = 14;
pub const scrollbar_bottom_margin: f32 = 8;
pub const scrollbar_minimum_thumb: f32 = 32;

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

/// The rail scrollbar as drawn: the track it moves along and the thumb that
/// shows the visible part of the page list.
pub const Scrollbar = struct {
    track: Rect,
    thumb: Rect,
};

pub const ScrollbarHit = union(enum) {
    /// The pointer is on the thumb; the payload is its distance from the
    /// thumb's top, which a drag keeps constant.
    thumb: f32,
    /// The pointer is on the track beside the thumb, at this height.
    track: f32,
};

/// What the pointer is over. The application resolves it once per pointer
/// move and hands it to the renderer, so both sides highlight the same thing.
pub const Hover = union(enum) {
    none,
    toolbar: ToolbarButton,
    panel: PanelControl,
    thumbnail: usize,
    scrollbar,

    pub fn isScrollbar(self: Hover) bool {
        return std.meta.activeTag(self) == .scrollbar;
    }

    pub fn isToolbar(self: Hover, button: ToolbarButton) bool {
        return switch (self) {
            .toolbar => |hovered| hovered == button,
            else => false,
        };
    }

    pub fn isPanel(self: Hover, tag: std.meta.Tag(PanelControl)) bool {
        return switch (self) {
            .panel => |control| std.meta.activeTag(control) == tag,
            else => false,
        };
    }

    pub fn isColor(self: Hover, color: annotations.Color) bool {
        return switch (self) {
            .panel => |control| switch (control) {
                .color => |hovered| hovered == color,
                else => false,
            },
            else => false,
        };
    }

    pub fn isSize(self: Hover, size: annotations.PenSize) bool {
        return switch (self) {
            .panel => |control| switch (control) {
                .size => |hovered| hovered == size,
                else => false,
            },
            else => false,
        };
    }

    pub fn isThumbnail(self: Hover, page_index: usize) bool {
        return switch (self) {
            .thumbnail => |hovered| hovered == page_index,
            else => false,
        };
    }
};

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

/// The annotation margin is a vertical flow of rows. Every row has a fixed
/// height; only the gaps between rows stretch or shrink with the window.
pub const Panel = struct {
    bounds: Rect,
    content_left: f32,
    inner_width: f32,
    /// Top of the title row; the close button shares it.
    title_y: f32,
    ink_label_y: f32,
    width_label_y: f32,
    edit_divider_y: f32,
    completion_divider_y: f32,
    /// Top of the save status row.
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

const PanelRow = enum {
    title,
    tabs,
    ink_label,
    swatches,
    width_label,
    sizes,
    edit_divider,
    undo,
    clear,
    completion_divider,
    done,
    status,
};

const panel_row_count = std.meta.fields(PanelRow).len;

const panel_row_heights = std.enums.EnumArray(PanelRow, f32).init(.{
    .title = 44,
    .tabs = 60,
    .ink_label = panel_label_height,
    .swatches = 44,
    .width_label = panel_label_height,
    .sizes = 58,
    .edit_divider = 1,
    .undo = 44,
    .clear = 44,
    .completion_divider = 1,
    .done = 48,
    .status = panel_status_height,
});

/// Preferred gap above each row; the first one is the top padding. All gaps
/// scale by one factor, so the margin fills tall windows evenly and still
/// holds every control at the minimum window height.
const panel_row_gaps = std.enums.EnumArray(PanelRow, f32).init(.{
    .title = 24,
    .tabs = 16,
    .ink_label = 24,
    .swatches = 8,
    .width_label = 24,
    .sizes = 8,
    .edit_divider = 24,
    .undo = 12,
    .clear = 8,
    .completion_divider = 12,
    .done = 12,
    .status = 24,
});

/// At the minimum gap factor the panel needs less than the minimum window
/// height, which the layout tests verify.
const panel_minimum_gap_factor: f32 = 0.5;
const panel_maximum_gap_factor: f32 = 1.75;

pub const VisibleThumbnails = struct {
    first: usize,
    end: usize,

    pub fn contains(self: VisibleThumbnails, page_index: usize) bool {
        return page_index >= self.first and page_index < self.end;
    }
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
                window.width * navigation_width_ratio,
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

    /// Resolves what the pointer is over; null means the pointer is outside
    /// the window.
    pub fn hoverAt(
        self: Layout,
        point: ?Vec2,
        document_open: bool,
        thumbnail_scroll: f32,
        page_count: usize,
    ) Hover {
        const position = point orelse return .none;
        if (self.toolbarHit(position, document_open)) |button| return .{ .toolbar = button };
        if (self.panelHit(position)) |control| return .{ .panel = control };
        if (self.scrollbarHit(position, thumbnail_scroll, page_count)) |hit| {
            return switch (hit) {
                .thumb => .scrollbar,
                .track => .none,
            };
        }
        if (self.thumbnailAt(position, thumbnail_scroll, page_count)) |index| {
            return .{ .thumbnail = index };
        }
        return .none;
    }

    /// Where the rail scrollbar sits for a scroll position, or null when
    /// every page fits and there is nothing to scroll.
    pub fn thumbnailScrollbar(self: Layout, scroll: f32, page_count: usize) ?Scrollbar {
        if (self.navigation_width <= 0) return null;
        const maximum_scroll = self.thumbnailMaxScroll(page_count);
        if (maximum_scroll <= 0) return null;
        const track_top = thumbnail_list_top;
        const track_height = self.window.height - track_top - scrollbar_bottom_margin;
        if (track_height <= 0) return null;
        const content_height = @as(f32, @floatFromInt(page_count)) * thumbnail_slot_height;
        const proportional = track_height * self.thumbnailViewportHeight() / content_height;
        const thumb_height = @min(track_height, @max(scrollbar_minimum_thumb, proportional));
        const fraction = self.clampThumbnailScroll(scroll, page_count) / maximum_scroll;
        const x = self.navigation_width - scrollbar_right_margin - scrollbar_width;
        return .{
            .track = .{ .x = x, .y = track_top, .w = scrollbar_width, .h = track_height },
            .thumb = .{
                .x = x,
                .y = track_top + (track_height - thumb_height) * fraction,
                .w = scrollbar_width,
                .h = thumb_height,
            },
        };
    }

    /// Whether a point grabs the thumb or lands on the track. The strip that
    /// catches the pointer is wider than the drawn thumb.
    pub fn scrollbarHit(
        self: Layout,
        point: Vec2,
        scroll: f32,
        page_count: usize,
    ) ?ScrollbarHit {
        const bar = self.thumbnailScrollbar(scroll, page_count) orelse return null;
        if (point.x < self.navigation_width - scrollbar_hit_width) return null;
        if (point.x >= self.navigation_width) return null;
        if (point.y < bar.track.y or point.y >= bar.track.bottom()) return null;
        if (point.y >= bar.thumb.y and point.y < bar.thumb.bottom()) {
            return .{ .thumb = point.y - bar.thumb.y };
        }
        return .{ .track = point.y };
    }

    /// The scroll that puts the top of the thumb at `thumb_y`, clamped to
    /// the track.
    pub fn scrollForThumb(self: Layout, thumb_y: f32, page_count: usize) f32 {
        const bar = self.thumbnailScrollbar(0, page_count) orelse return 0;
        const travel = bar.track.h - bar.thumb.h;
        if (travel <= 0) return 0;
        const fraction = std.math.clamp((thumb_y - bar.track.y) / travel, 0, 1);
        const scroll = fraction * self.thumbnailMaxScroll(page_count);
        return self.clampThumbnailScroll(scroll, page_count);
    }

    /// The scroll that centers the thumb on a height of the track, for a
    /// click beside the thumb.
    pub fn scrollCenteredOn(self: Layout, y: f32, page_count: usize) f32 {
        const bar = self.thumbnailScrollbar(0, page_count) orelse return 0;
        return self.scrollForThumb(y - bar.thumb.h / 2, page_count);
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
        const list_height = @max(self.window.height - thumbnail_list_top, 0);
        const span: usize = @intFromFloat(list_height / thumbnail_slot_height);
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
    return std.math.clamp(
        window_width * panel_width_ratio,
        panel_minimum_width,
        panel_maximum_width,
    );
}

fn takeRight(right: *f32, width: f32) Rect {
    right.* -= width;
    const rect = Rect{ .x = right.*, .y = toolbar_top, .w = width, .h = toolbar_button };
    right.* -= toolbar_gap;
    return rect;
}

fn toolbarSquare(x: f32) Rect {
    return .{ .x = x, .y = toolbar_top, .w = toolbar_button, .h = toolbar_button };
}

fn computeToolbar(window_width: f32) Toolbar {
    var toolbar: Toolbar = undefined;
    toolbar.pages = toolbarSquare(pages_button_x);
    toolbar.open = .{
        .x = open_button_x,
        .y = toolbar_top,
        .w = if (window_width > open_button_wide_threshold)
            open_button_wide_width
        else
            open_button_narrow_width,
        .h = toolbar_button,
    };

    var right = window_width - toolbar_right_margin;
    toolbar.annotations = takeRight(&right, toolbar_button);
    toolbar.theme = takeRight(&right, toolbar_button);
    toolbar.bookmark = takeRight(&right, toolbar_button);
    toolbar.jump = takeRight(&right, toolbar_button);
    toolbar.zoom_in = takeRight(&right, toolbar_button);
    toolbar.zoom_reset = takeRight(&right, zoom_reset_width);
    toolbar.zoom_out = takeRight(&right, toolbar_button);

    // The next button must end one gap before the first action on the right,
    // which bounds how far right the navigation center may move.
    const preferred_center = window_width * toolbar_center_ratio;
    const maximum_center = toolbar.zoom_out.x -
        (navigation_next_offset + toolbar_button + toolbar_gap);
    const center = @min(preferred_center, maximum_center);
    toolbar.previous = toolbarSquare(center - navigation_previous_offset);
    toolbar.next = toolbarSquare(center + navigation_next_offset);
    toolbar.page_label = .{
        .x = toolbar.previous.x + toolbar.previous.w,
        .y = toolbar_top,
        .w = toolbar.next.x - toolbar.previous.x - toolbar.previous.w,
        .h = toolbar_button,
    };
    return toolbar;
}

fn panelRowTops(available: f32) std.enums.EnumArray(PanelRow, f32) {
    var content_height: f32 = 0;
    var gap_total: f32 = 0;
    for (panel_row_heights.values) |height| content_height += height;
    for (panel_row_gaps.values) |gap| gap_total += gap;
    const slack = available - panel_padding_bottom - content_height;
    const factor = std.math.clamp(
        slack / gap_total,
        panel_minimum_gap_factor,
        panel_maximum_gap_factor,
    );

    var tops = std.enums.EnumArray(PanelRow, f32).initUndefined();
    var y = header_height;
    for (std.enums.values(PanelRow)) |row| {
        y += panel_row_gaps.get(row) * factor;
        tops.set(row, y);
        y += panel_row_heights.get(row);
    }
    return tops;
}

fn computePanel(window: Size) Panel {
    const width = panelWidthFor(window.width);
    const left = window.width - width;
    const available = window.height - header_height;
    const content_left = left + panel_padding_left;
    const inner_width = width - panel_padding_left - panel_padding_right;
    const tops = panelRowTops(available);
    const tool_width = (inner_width - panel_tab_gap) / 2;

    var panel = Panel{
        .bounds = .{ .x = left, .y = header_height, .w = width, .h = available },
        .content_left = content_left,
        .inner_width = inner_width,
        .title_y = tops.get(.title),
        .ink_label_y = tops.get(.ink_label),
        .width_label_y = tops.get(.width_label),
        .edit_divider_y = tops.get(.edit_divider),
        .completion_divider_y = tops.get(.completion_divider),
        .save_status_y = tops.get(.status),
        .close = .{
            .x = left + width - panel_padding_right - toolbar_button,
            .y = tops.get(.title),
            .w = toolbar_button,
            .h = panel_row_heights.get(.title),
        },
        .pen = .{
            .x = content_left,
            .y = tops.get(.tabs),
            .w = tool_width,
            .h = panel_row_heights.get(.tabs),
        },
        .eraser = .{
            .x = content_left + tool_width + panel_tab_gap,
            .y = tops.get(.tabs),
            .w = tool_width,
            .h = panel_row_heights.get(.tabs),
        },
        .colors = undefined,
        .sizes = undefined,
        .undo = .{
            .x = content_left,
            .y = tops.get(.undo),
            .w = inner_width,
            .h = panel_row_heights.get(.undo),
        },
        .clear = .{
            .x = content_left,
            .y = tops.get(.clear),
            .w = inner_width,
            .h = panel_row_heights.get(.clear),
        },
        .done = .{
            .x = content_left,
            .y = tops.get(.done),
            .w = inner_width,
            .h = panel_row_heights.get(.done),
        },
    };

    const swatch_step = inner_width / @as(f32, @floatFromInt(panel.colors.len));
    for (&panel.colors, 0..) |*rect, index| {
        const center_x = content_left + swatch_step * (@as(f32, @floatFromInt(index)) + 0.5);
        rect.* = .{
            .x = center_x - 20,
            .y = tops.get(.swatches),
            .w = 40,
            .h = panel_row_heights.get(.swatches),
        };
    }

    const size_count: f32 = @floatFromInt(panel.sizes.len);
    const size_width = (inner_width - panel_size_gap * (size_count - 1)) / size_count;
    for (&panel.sizes, 0..) |*rect, index| {
        rect.* = .{
            .x = content_left + @as(f32, @floatFromInt(index)) * (size_width + panel_size_gap),
            .y = tops.get(.sizes),
            .w = size_width,
            .h = panel_row_heights.get(.sizes),
        };
    }
    return panel;
}

const test_window = default_window;

fn testLayout(options: Options) Layout {
    return Layout.compute(test_window, options);
}

test "toolbar buttons never overlap and stay inside the header" {
    for ([_]f32{ minimum_window.width, 1100, 1300, 1536, 2400 }) |width| {
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

/// Every panel row from top to bottom, as the vertical span it occupies.
fn panelRows(panel: Panel) [panel_row_count][2]f32 {
    return .{
        .{ panel.close.y, panel.close.bottom() },
        .{ panel.pen.y, panel.pen.bottom() },
        .{ panel.ink_label_y, panel.ink_label_y + panel_label_height },
        .{ panel.colors[0].y, panel.colors[0].bottom() },
        .{ panel.width_label_y, panel.width_label_y + panel_label_height },
        .{ panel.sizes[0].y, panel.sizes[0].bottom() },
        .{ panel.edit_divider_y, panel.edit_divider_y + 1 },
        .{ panel.undo.y, panel.undo.bottom() },
        .{ panel.clear.y, panel.clear.bottom() },
        .{ panel.completion_divider_y, panel.completion_divider_y + 1 },
        .{ panel.done.y, panel.done.bottom() },
        .{ panel.save_status_y, panel.save_status_y + panel_status_height },
    };
}

test "panel rows never overlap and fit from the minimum window height upward" {
    for ([_]f32{ minimum_window.height, 640, 700, 820, 1000, 1400, 2200 }) |height| {
        const layout = Layout.compute(.{ .width = minimum_window.width, .height = height }, .{
            .document_open = true,
            .navigation_visible = true,
            .annotations_enabled = true,
        });
        const panel = layout.panel.?;
        const rows = panelRows(panel);
        var previous_bottom: f32 = header_height;
        for (rows) |row| {
            try std.testing.expect(row[0] >= previous_bottom);
            try std.testing.expect(row[1] > row[0]);
            previous_bottom = row[1];
        }
        try std.testing.expect(previous_bottom + panel_padding_bottom <= height + 0.01);

        // Controls stay inside the panel horizontally, including the close
        // button on the right edge.
        try std.testing.expect(panel.close.x + panel.close.w <= panel.bounds.x + panel.bounds.w);
        try std.testing.expect(panel.eraser.x + panel.eraser.w <=
            panel.bounds.x + panel.bounds.w - panel_padding_right + 0.01);
        try std.testing.expect(panel.sizes[2].x + panel.sizes[2].w <=
            panel.content_left + panel.inner_width + 0.01);
        try std.testing.expect(panel.colors[0].x >= panel.content_left - 0.01);
    }
}

test "panel gaps stretch in tall windows and shrink in short ones" {
    const short = Layout.compute(.{ .width = 900, .height = minimum_window.height }, .{
        .document_open = true,
        .navigation_visible = true,
        .annotations_enabled = true,
    }).panel.?;
    const tall = Layout.compute(.{ .width = 900, .height = 1400 }, .{
        .document_open = true,
        .navigation_visible = true,
        .annotations_enabled = true,
    }).panel.?;
    try std.testing.expect(tall.undo.y - tall.sizes[0].bottom() >
        short.undo.y - short.sizes[0].bottom());
    try std.testing.expect(tall.done.bottom() < 1400 * 0.85);
}

test "hover resolves the toolbar, the panel, the rail, or nothing" {
    const layout = testLayout(.{
        .document_open = true,
        .navigation_visible = true,
        .annotations_enabled = true,
    });
    const panel = layout.panel.?;
    try std.testing.expectEqual(Hover.none, layout.hoverAt(null, true, 0, 10));
    const toolbar = layout.hoverAt(.{ .x = layout.toolbar.next.centerX(), .y = 30 }, true, 0, 10);
    try std.testing.expect(toolbar.isToolbar(.next));
    try std.testing.expect(!toolbar.isToolbar(.previous));
    const swatch = layout.hoverAt(.{
        .x = panel.colors[2].centerX(),
        .y = panel.colors[2].centerY(),
    }, true, 0, 10);
    try std.testing.expect(swatch.isColor(.green));
    try std.testing.expect(!swatch.isColor(.blue));
    try std.testing.expect(!swatch.isPanel(.undo));
    const size = layout.hoverAt(.{
        .x = panel.sizes[1].centerX(),
        .y = panel.sizes[1].centerY(),
    }, true, 0, 10);
    try std.testing.expect(size.isSize(.medium));
    const undo = layout.hoverAt(.{
        .x = panel.undo.centerX(),
        .y = panel.undo.centerY(),
    }, true, 0, 10);
    try std.testing.expect(undo.isPanel(.undo));
    const rail = layout.hoverAt(.{ .x = 60, .y = 280 }, true, 0, 10);
    try std.testing.expect(rail.isThumbnail(1));
    try std.testing.expect(!rail.isThumbnail(0));
    try std.testing.expectEqual(Hover.none, layout.hoverAt(.{ .x = 600, .y = 400 }, true, 0, 10));
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
    try std.testing.expect(visible.contains(0));
    try std.testing.expect(!visible.contains(visible.end));
    const tail = layout.visibleThumbnails(layout.thumbnailMaxScroll(10), 10);
    try std.testing.expectEqual(@as(usize, 10), tail.end);
    try std.testing.expectEqual(@as(usize, 0), layout.visibleThumbnails(0, 0).end);
    const tiny = Layout.compute(.{ .width = 900, .height = 50 }, .{
        .document_open = true,
        .navigation_visible = true,
        .annotations_enabled = false,
    });
    try std.testing.expectEqual(@as(usize, 2), tiny.visibleThumbnails(0, 10).end);
}

test "thumbnail slots, image bounds, and scroll clamps follow the rail geometry" {
    const layout = testLayout(.{
        .document_open = true,
        .navigation_visible = true,
        .annotations_enabled = false,
    });
    const slot = layout.thumbnailSlot(3, 40);
    try std.testing.expectEqual(@as(f32, 8), slot.x);
    try std.testing.expectEqual(layout.navigation_width - 16, slot.w);
    try std.testing.expectEqual(thumbnail_slot_height - 4, slot.h);
    try std.testing.expectEqual(thumbnail_list_top - 40 + 3 * thumbnail_slot_height, slot.y);
    const image = layout.thumbnailImageBounds(slot);
    try std.testing.expectEqual(@as(f32, 16), image.x);
    try std.testing.expectEqual(slot.y + 4, image.y);
    try std.testing.expectEqual(layout.navigation_width - 32, image.w);
    try std.testing.expectEqual(thumbnail_image_height, image.h);
    try std.testing.expect(image.x + image.w <= slot.x + slot.w);

    try std.testing.expectEqual(@as(f32, 0), layout.clampThumbnailScroll(-5, 10));
    try std.testing.expectEqual(
        layout.thumbnailMaxScroll(10),
        layout.clampThumbnailScroll(1e9, 10),
    );
    try std.testing.expectEqual(@as(f32, 0), layout.clampThumbnailScroll(100, 1));
    try std.testing.expectEqual(@as(f32, 30), layout.clampThumbnailScroll(30, 10));
    try std.testing.expectEqual(
        layout.window.height - thumbnail_list_top - thumbnail_bottom_margin,
        layout.thumbnailViewportHeight(),
    );
}

test "rectangles inset, grow, and report their bottom edge" {
    const rect = Rect{ .x = 10, .y = 20, .w = 30, .h = 40 };
    const smaller = rect.inset(5);
    try std.testing.expectEqual(Rect{ .x = 15, .y = 25, .w = 20, .h = 30 }, smaller);
    const larger = rect.inset(-2);
    try std.testing.expectEqual(Rect{ .x = 8, .y = 18, .w = 34, .h = 44 }, larger);
    try std.testing.expectEqual(@as(f32, 60), rect.bottom());
    try std.testing.expectEqual(@as(f32, 25), rect.centerX());
    try std.testing.expectEqual(@as(f32, 40), rect.centerY());
    try std.testing.expect(!rect.isEmpty());
    try std.testing.expect(rect.inset(20).isEmpty());
    try std.testing.expect(rect.contains(.{ .x = 10, .y = 20 }));
    try std.testing.expect(!rect.contains(.{ .x = 40, .y = 20 }));
}

test "the rail scrollbar maps scroll to the thumb and back" {
    const layout = testLayout(.{
        .document_open = true,
        .navigation_visible = true,
        .annotations_enabled = false,
    });
    const page_count = 40;
    const maximum = layout.thumbnailMaxScroll(page_count);
    try std.testing.expectEqual(@as(?Scrollbar, null), layout.thumbnailScrollbar(0, 2));

    const at_top = layout.thumbnailScrollbar(0, page_count).?;
    try std.testing.expectEqual(thumbnail_list_top, at_top.track.y);
    try std.testing.expectEqual(at_top.track.y, at_top.thumb.y);
    try std.testing.expectEqual(layout.navigation_width - 4, at_top.thumb.x);
    try std.testing.expectEqual(scrollbar_width, at_top.thumb.w);
    try std.testing.expect(at_top.thumb.h >= scrollbar_minimum_thumb);
    try std.testing.expect(at_top.thumb.h < at_top.track.h);
    const at_bottom = layout.thumbnailScrollbar(maximum, page_count).?;
    try std.testing.expectApproxEqAbs(at_bottom.track.bottom(), at_bottom.thumb.bottom(), 0.01);
    const halfway = layout.thumbnailScrollbar(maximum / 2, page_count).?;
    try std.testing.expectApproxEqAbs(
        (at_top.thumb.y + at_bottom.thumb.y) / 2,
        halfway.thumb.y,
        0.01,
    );

    // The inverse mapping returns the scroll a thumb position came from and
    // clamps beyond the track.
    for ([_]f32{ 0, 100, maximum / 3, maximum }) |scroll| {
        const bar = layout.thumbnailScrollbar(scroll, page_count).?;
        const back = layout.scrollForThumb(bar.thumb.y, page_count);
        try std.testing.expectApproxEqAbs(scroll, back, 0.05);
    }
    try std.testing.expectEqual(@as(f32, 0), layout.scrollForThumb(-500, page_count));
    try std.testing.expectEqual(maximum, layout.scrollForThumb(5000, page_count));
    try std.testing.expectEqual(@as(f32, 0), layout.scrollForThumb(200, 2));
    const centered = layout.scrollCenteredOn(at_top.track.centerY(), page_count);
    const centered_bar = layout.thumbnailScrollbar(centered, page_count).?;
    try std.testing.expectApproxEqAbs(at_top.track.centerY(), centered_bar.thumb.centerY(), 0.5);
}

test "the scrollbar catches the pointer on a strip wider than the thumb" {
    const layout = testLayout(.{
        .document_open = true,
        .navigation_visible = true,
        .annotations_enabled = false,
    });
    const page_count = 40;
    const bar = layout.thumbnailScrollbar(0, page_count).?;
    const on_thumb = Vec2{ .x = layout.navigation_width - 6, .y = bar.thumb.y + 10 };
    const hit = layout.scrollbarHit(on_thumb, 0, page_count).?;
    try std.testing.expectApproxEqAbs(@as(f32, 10), hit.thumb, 0.01);
    const below = Vec2{ .x = layout.navigation_width - 1, .y = bar.thumb.bottom() + 40 };
    const on_track = layout.scrollbarHit(below, 0, page_count).?;
    try std.testing.expectApproxEqAbs(below.y, on_track.track, 0.01);
    const left_of_strip = Vec2{
        .x = layout.navigation_width - scrollbar_hit_width - 1,
        .y = bar.thumb.y + 10,
    };
    const beside = layout.scrollbarHit(left_of_strip, 0, page_count);
    try std.testing.expectEqual(@as(?ScrollbarHit, null), beside);
    const above_track = Vec2{ .x = layout.navigation_width - 6, .y = bar.track.y - 1 };
    const above = layout.scrollbarHit(above_track, 0, page_count);
    try std.testing.expectEqual(@as(?ScrollbarHit, null), above);
    try std.testing.expectEqual(@as(?ScrollbarHit, null), layout.scrollbarHit(on_thumb, 0, 2));

    // Hover reports the thumb, ignores the track, and still finds the
    // thumbnails left of the strip.
    try std.testing.expect(layout.hoverAt(on_thumb, true, 0, page_count).isScrollbar());
    try std.testing.expectEqual(Hover.none, layout.hoverAt(below, true, 0, page_count));
    const first_slot = layout.hoverAt(.{ .x = 60, .y = 140 }, true, 0, page_count);
    try std.testing.expect(first_slot.isThumbnail(0));
    const hidden = testLayout(.{
        .document_open = true,
        .navigation_visible = false,
        .annotations_enabled = false,
    });
    try std.testing.expectEqual(@as(?Scrollbar, null), hidden.thumbnailScrollbar(0, page_count));
}
