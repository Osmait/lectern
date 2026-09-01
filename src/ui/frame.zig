//! What one frame of the interface shows. The application fills this in and
//! the renderer draws it, so the renderer never reads application state.

const annotations = @import("book_read").annotations;
const layout = @import("layout.zig");

pub const SaveStatus = enum {
    saved,
    pending,
    failed,

    pub fn label(self: SaveStatus) []const u8 {
        return switch (self) {
            .saved => "Saved locally",
            .pending => "Saving notes",
            .failed => "Notes not saved",
        };
    }
};

pub const FrameInfo = struct {
    size: layout.Size,
    density: f32,
};

pub const Frame = struct {
    dark_mode: bool,
    document_open: bool,
    /// Device pixels per logical pixel of the frame being drawn.
    density: f32 = 1,
    /// Distinguishes documents, so cached geometry and thumbnails of a
    /// previous document are never shown for the current one.
    document_identity: u64 = 0,
    page_index: usize,
    page_count: usize,
    zoom_percent: u32,
    bookmarked: bool,
    title: []const u8,
    navigation_visible: bool,
    thumbnail_scroll: f32,
    tool: annotations.Tool,
    color: annotations.Color,
    pen_size: annotations.PenSize,
    save_status: SaveStatus,
    /// Resolved once by the application, so drawing and repaint decisions
    /// agree on what the pointer is over.
    hover: layout.Hover = .none,
    page_rect: ?layout.Rect,
    /// Finished strokes of the shown page and the notebook revision they
    /// belong to; the renderer rebuilds their geometry only when it moves.
    strokes: []const annotations.Stroke = &.{},
    strokes_revision: u64 = 0,
    /// Points of the stroke being drawn on the shown page, drawn with the
    /// frame's color and pen size.
    active_stroke: []const annotations.Point = &.{},

    pub fn annotationsEnabled(self: Frame) bool {
        return self.tool != .off;
    }
};

test "save status labels are distinct" {
    const std = @import("std");
    try std.testing.expect(!std.mem.eql(u8, SaveStatus.saved.label(), SaveStatus.failed.label()));
    try std.testing.expect(!std.mem.eql(u8, SaveStatus.pending.label(), SaveStatus.failed.label()));
}

test "annotations are enabled for every tool except off" {
    const std = @import("std");
    var frame = Frame{
        .dark_mode = false,
        .document_open = true,
        .page_index = 0,
        .page_count = 1,
        .zoom_percent = 100,
        .bookmarked = false,
        .title = "",
        .navigation_visible = true,
        .thumbnail_scroll = 0,
        .tool = .off,
        .color = .blue,
        .pen_size = .medium,
        .save_status = .saved,
        .page_rect = null,
    };
    try std.testing.expect(!frame.annotationsEnabled());
    frame.tool = .pen;
    try std.testing.expect(frame.annotationsEnabled());
    frame.tool = .eraser;
    try std.testing.expect(frame.annotationsEnabled());
}
