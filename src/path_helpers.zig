const std = @import("std");

pub fn baseName(path: []const u8) []const u8 {
    const slash_index = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return path;
    return path[slash_index + 1 ..];
}

test "baseName supports Unix and Windows separators" {
    try std.testing.expectEqualStrings("book.pdf", baseName("/library/books/book.pdf"));
    try std.testing.expectEqualStrings("book.pdf", baseName("C:\\Books\\book.pdf"));
    try std.testing.expectEqualStrings("book.pdf", baseName("book.pdf"));
}

test "baseName handles empty and trailing components" {
    try std.testing.expectEqualStrings("", baseName(""));
    try std.testing.expectEqualStrings("", baseName("/library/"));
}

test "baseName handles roots, repeated separators, and Unicode bytes" {
    try std.testing.expectEqualStrings("", baseName("/"));
    try std.testing.expectEqualStrings("", baseName("C:\\"));
    try std.testing.expectEqualStrings("book.pdf", baseName("/library//book.pdf"));
    try std.testing.expectEqualStrings("libro-ñ.pdf", baseName("/lectura/libro-ñ.pdf"));
}
