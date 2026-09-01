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
    mouse: ?layout.Vec2,
    page_rect: ?layout.Rect,

    pub fn annotationsEnabled(self: Frame) bool {
        return self.tool != .off;
    }
};

test "save status labels are distinct" {
    const std = @import("std");
    try std.testing.expect(!std.mem.eql(u8, SaveStatus.saved.label(), SaveStatus.failed.label()));
    try std.testing.expect(!std.mem.eql(u8, SaveStatus.pending.label(), SaveStatus.failed.label()));
}
