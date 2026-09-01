//! Text format for per-document reading progress.
//!
//! Each line is a `key value` pair. `page N` restores the current page and
//! `bookmark N` marks a page. Files written by earlier versions also carried a
//! `dark N` line; it is reported separately so the application can migrate the
//! value into its preferences once and then ignore it.

const std = @import("std");
const Reader = @import("reader.zig").Reader;

pub const Restored = struct {
    legacy_dark_mode: ?bool = null,
};

/// Applies persisted progress to an open reader. Unknown keys, malformed
/// values, and pages outside the document are ignored so a damaged file can
/// never leave the reader in an invalid state.
pub fn restore(reader: *Reader, data: []const u8) Restored {
    var result = Restored{};
    var lines = std.mem.tokenizeAny(u8, data, "\r\n");
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t");
        const key = words.next() orelse continue;
        const value_text = words.next() orelse continue;
        const value = std.fmt.parseInt(i64, value_text, 10) catch continue;
        if (std.mem.eql(u8, key, "page")) {
            if (value >= 0) _ = reader.goToPage(@intCast(value));
        } else if (std.mem.eql(u8, key, "bookmark")) {
            if (value >= 0) _ = reader.setBookmark(@intCast(value));
        } else if (std.mem.eql(u8, key, "dark")) {
            result.legacy_dark_mode = value != 0;
        }
    }
    return result;
}

pub fn serialize(allocator: std.mem.Allocator, reader: Reader) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var line_buffer: [64]u8 = undefined;

    const page_line = try std.fmt.bufPrint(&line_buffer, "page {d}\n", .{reader.page_index});
    try output.appendSlice(allocator, page_line);

    var bookmarks = reader.bookmarks.iterator(.{});
    while (bookmarks.next()) |page_index| {
        const bookmark_line = try std.fmt.bufPrint(
            &line_buffer,
            "bookmark {d}\n",
            .{page_index},
        );
        try output.appendSlice(allocator, bookmark_line);
    }
    return output.toOwnedSlice(allocator);
}

test "progress round trips page and bookmarks" {
    var source = Reader.init(std.testing.allocator);
    defer source.deinit();
    try source.open(5);
    _ = source.goToPage(3);
    _ = source.toggleBookmark();
    _ = source.goToPage(1);
    _ = source.toggleBookmark();

    const data = try serialize(std.testing.allocator, source);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("page 1\nbookmark 1\nbookmark 3\n", data);

    var restored = Reader.init(std.testing.allocator);
    defer restored.deinit();
    try restored.open(5);
    const result = restore(&restored, data);
    try std.testing.expectEqual(@as(usize, 1), restored.page_index);
    try std.testing.expect(restored.isBookmarked(1));
    try std.testing.expect(restored.isBookmarked(3));
    try std.testing.expectEqual(@as(?bool, null), result.legacy_dark_mode);
}

test "corrupt progress is ignored field by field" {
    var reader = Reader.init(std.testing.allocator);
    defer reader.deinit();
    try reader.open(2);

    const result = restore(
        &reader,
        "page 99\r\ndark 7\nbookmark -1\nbookmark 1\nbookmark x\nnonsense\npage\n",
    );
    try std.testing.expectEqual(@as(usize, 0), reader.page_index);
    try std.testing.expect(!reader.isBookmarked(0));
    try std.testing.expect(reader.isBookmarked(1));
    try std.testing.expectEqual(@as(?bool, true), result.legacy_dark_mode);
}

test "empty and closed readers restore safely" {
    var reader = Reader.init(std.testing.allocator);
    defer reader.deinit();
    _ = restore(&reader, "page 1\nbookmark 0\n");
    try std.testing.expect(!reader.isOpen());
    _ = restore(&reader, "");
    try std.testing.expect(!reader.isOpen());
}
