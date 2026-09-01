//! Pure per-document reading state.
//!
//! This module deliberately knows nothing about PDFs, windows, or persistence.
//! Keeping those dependencies out makes every state transition cheap to test.
//! The reading theme is an application preference, so it does not live here.

const std = @import("std");

pub const Reader = struct {
    /// Zoom is stored as an integer step so repeated operations never drift.
    /// Each step is ten percent; step zero is one hundred percent.
    pub const minimum_zoom_step: i8 = -5;
    pub const maximum_zoom_step: i8 = 15;

    allocator: std.mem.Allocator,
    page_count: usize = 0,
    page_index: usize = 0,
    zoom_step: i8 = 0,
    bookmarks: std.DynamicBitSetUnmanaged = .{},

    pub fn init(allocator: std.mem.Allocator) Reader {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Reader) void {
        self.bookmarks.deinit(self.allocator);
        self.* = .{ .allocator = self.allocator };
    }

    pub fn open(self: *Reader, page_count: usize) !void {
        if (page_count == 0) return error.EmptyDocument;

        var next_bookmarks = try std.DynamicBitSetUnmanaged.initEmpty(
            self.allocator,
            page_count,
        );
        errdefer next_bookmarks.deinit(self.allocator);

        self.bookmarks.deinit(self.allocator);
        self.bookmarks = next_bookmarks;
        self.page_count = page_count;
        self.page_index = 0;
        self.zoom_step = 0;
    }

    pub fn isOpen(self: Reader) bool {
        return self.page_count > 0;
    }

    pub fn pageCount(self: Reader) usize {
        return self.page_count;
    }

    pub fn goToPage(self: *Reader, page_index: usize) bool {
        if (page_index >= self.page_count or page_index == self.page_index) return false;
        self.page_index = page_index;
        return true;
    }

    pub fn nextPage(self: *Reader) bool {
        if (self.page_index + 1 >= self.page_count) return false;
        self.page_index += 1;
        return true;
    }

    pub fn previousPage(self: *Reader) bool {
        if (self.page_index == 0) return false;
        self.page_index -= 1;
        return true;
    }

    pub fn firstPage(self: *Reader) bool {
        return self.goToPage(0);
    }

    pub fn lastPage(self: *Reader) bool {
        if (!self.isOpen()) return false;
        return self.goToPage(self.page_count - 1);
    }

    pub fn zoom(self: Reader) f32 {
        const tenths: f32 = @floatFromInt(10 + @as(i32, self.zoom_step));
        return tenths / 10.0;
    }

    pub fn zoomPercent(self: Reader) u32 {
        return @intCast(100 + @as(i32, self.zoom_step) * 10);
    }

    pub fn zoomIn(self: *Reader) bool {
        if (self.zoom_step >= maximum_zoom_step) return false;
        self.zoom_step += 1;
        return true;
    }

    pub fn zoomOut(self: *Reader) bool {
        if (self.zoom_step <= minimum_zoom_step) return false;
        self.zoom_step -= 1;
        return true;
    }

    pub fn resetZoom(self: *Reader) bool {
        if (self.zoom_step == 0) return false;
        self.zoom_step = 0;
        return true;
    }

    pub fn isBookmarked(self: Reader, page_index: usize) bool {
        return page_index < self.page_count and self.bookmarks.isSet(page_index);
    }

    pub fn isCurrentPageBookmarked(self: Reader) bool {
        return self.isBookmarked(self.page_index);
    }

    /// Restores a bookmark from persisted state. Out-of-range pages are ignored
    /// so a state file written for a different revision of the PDF stays safe.
    pub fn setBookmark(self: *Reader, page_index: usize) bool {
        if (page_index >= self.page_count) return false;
        self.bookmarks.set(page_index);
        return true;
    }

    pub fn toggleBookmark(self: *Reader) bool {
        if (!self.isOpen()) return false;
        self.bookmarks.toggle(self.page_index);
        return true;
    }

    pub fn bookmarkCount(self: Reader) usize {
        return self.bookmarks.count();
    }

    /// Returns the next bookmarked page after the current one, wrapping around
    /// the document, without changing the current page.
    pub fn nextBookmarkIndex(self: Reader) ?usize {
        if (!self.isOpen()) return null;
        var offset: usize = 1;
        while (offset < self.page_count) : (offset += 1) {
            const page_index = (self.page_index + offset) % self.page_count;
            if (self.bookmarks.isSet(page_index)) return page_index;
        }
        return null;
    }

    pub fn jumpToNextBookmark(self: *Reader) bool {
        const page_index = self.nextBookmarkIndex() orelse return false;
        return self.goToPage(page_index);
    }
};

test "opening a document establishes valid initial state" {
    var reader = Reader.init(std.testing.allocator);
    defer reader.deinit();

    try reader.open(3);

    try std.testing.expect(reader.isOpen());
    try std.testing.expectEqual(@as(usize, 3), reader.pageCount());
    try std.testing.expectEqual(@as(usize, 0), reader.page_index);
    try std.testing.expectEqual(@as(f32, 1.0), reader.zoom());
    try std.testing.expectEqual(@as(u32, 100), reader.zoomPercent());
    try std.testing.expectEqual(@as(usize, 0), reader.bookmarkCount());
}

test "an empty document is rejected without changing existing state" {
    var reader = Reader.init(std.testing.allocator);
    defer reader.deinit();
    try reader.open(2);
    try std.testing.expect(reader.nextPage());

    try std.testing.expectError(error.EmptyDocument, reader.open(0));
    try std.testing.expectEqual(@as(usize, 2), reader.pageCount());
    try std.testing.expectEqual(@as(usize, 1), reader.page_index);
}

test "page navigation preserves boundaries" {
    var reader = Reader.init(std.testing.allocator);
    defer reader.deinit();
    try reader.open(3);

    try std.testing.expect(!reader.previousPage());
    try std.testing.expect(!reader.firstPage());
    try std.testing.expect(!reader.goToPage(3));
    try std.testing.expect(reader.lastPage());
    try std.testing.expectEqual(@as(usize, 2), reader.page_index);
    try std.testing.expect(!reader.nextPage());
    try std.testing.expect(reader.previousPage());
    try std.testing.expectEqual(@as(usize, 1), reader.page_index);
}

test "zoom steps clamp to supported limits and never drift" {
    var reader = Reader.init(std.testing.allocator);
    defer reader.deinit();

    var operation_count: usize = 0;
    while (operation_count < 100) : (operation_count += 1) {
        _ = reader.zoomIn();
    }
    try std.testing.expectEqual(@as(u32, 250), reader.zoomPercent());
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), reader.zoom(), 0.0001);
    try std.testing.expect(!reader.zoomIn());

    operation_count = 0;
    while (operation_count < 15) : (operation_count += 1) {
        _ = reader.zoomOut();
    }
    try std.testing.expectEqual(@as(u32, 100), reader.zoomPercent());
    try std.testing.expectEqual(@as(f32, 1.0), reader.zoom());
    try std.testing.expect(!reader.resetZoom());

    operation_count = 0;
    while (operation_count < 100) : (operation_count += 1) {
        _ = reader.zoomOut();
    }
    try std.testing.expectEqual(@as(u32, 50), reader.zoomPercent());
    try std.testing.expect(!reader.zoomOut());
    try std.testing.expect(reader.resetZoom());
    try std.testing.expectEqual(@as(f32, 1.0), reader.zoom());
}

test "bookmarks toggle and wrap around the document" {
    var reader = Reader.init(std.testing.allocator);
    defer reader.deinit();
    try reader.open(5);

    try std.testing.expect(reader.toggleBookmark());
    try std.testing.expect(reader.goToPage(3));
    try std.testing.expect(reader.toggleBookmark());
    try std.testing.expectEqual(@as(usize, 2), reader.bookmarkCount());
    try std.testing.expectEqual(@as(?usize, 0), reader.nextBookmarkIndex());
    try std.testing.expect(reader.jumpToNextBookmark());
    try std.testing.expectEqual(@as(usize, 0), reader.page_index);
    try std.testing.expect(reader.jumpToNextBookmark());
    try std.testing.expectEqual(@as(usize, 3), reader.page_index);

    try std.testing.expect(reader.toggleBookmark());
    try std.testing.expect(reader.jumpToNextBookmark());
    try std.testing.expectEqual(@as(usize, 0), reader.page_index);
    try std.testing.expect(reader.toggleBookmark());
    try std.testing.expect(!reader.jumpToNextBookmark());
    try std.testing.expectEqual(@as(?usize, null), reader.nextBookmarkIndex());
    try std.testing.expectEqual(@as(usize, 0), reader.page_index);
}

test "restored bookmarks ignore pages outside the document" {
    var reader = Reader.init(std.testing.allocator);
    defer reader.deinit();
    try reader.open(2);

    try std.testing.expect(reader.setBookmark(1));
    try std.testing.expect(!reader.setBookmark(2));
    try std.testing.expect(!reader.isBookmarked(0));
    try std.testing.expect(reader.isBookmarked(1));
    try std.testing.expect(!reader.isBookmarked(99));
}

test "opening another document releases and replaces bookmark storage" {
    var reader = Reader.init(std.testing.allocator);
    defer reader.deinit();
    try reader.open(10);
    _ = reader.toggleBookmark();
    _ = reader.zoomIn();
    try reader.open(2);

    try std.testing.expectEqual(@as(usize, 2), reader.pageCount());
    try std.testing.expectEqual(@as(usize, 0), reader.bookmarkCount());
    try std.testing.expectEqual(@as(u32, 100), reader.zoomPercent());
}

test "closed reader operations are safe no-ops" {
    var reader = Reader.init(std.testing.allocator);
    defer reader.deinit();

    try std.testing.expect(!reader.isOpen());
    try std.testing.expect(!reader.goToPage(0));
    try std.testing.expect(!reader.nextPage());
    try std.testing.expect(!reader.previousPage());
    try std.testing.expect(!reader.firstPage());
    try std.testing.expect(!reader.lastPage());
    try std.testing.expect(!reader.setBookmark(0));
    try std.testing.expect(!reader.toggleBookmark());
    try std.testing.expect(!reader.jumpToNextBookmark());
    try std.testing.expect(!reader.isCurrentPageBookmarked());
}

fn exerciseReaderAllocations(allocator: std.mem.Allocator) !void {
    var reader = Reader.init(allocator);
    defer reader.deinit();
    try reader.open(3);
    try reader.open(200);
}

test "allocation failures preserve memory safety" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseReaderAllocations,
        .{},
    );
}
