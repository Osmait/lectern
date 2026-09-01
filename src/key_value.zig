//! Line-oriented `key value` text records shared by the progress and
//! preferences formats.
//!
//! Lines are split on CR or LF and words on spaces or tabs. A record is
//! reported only when it has a key and an integer value, so callers never see
//! malformed lines and a damaged file degrades field by field.

const std = @import("std");

pub const Record = struct {
    key: []const u8,
    value: i64,
};

pub const Iterator = struct {
    lines: std.mem.TokenIterator(u8, .any),

    pub fn next(self: *Iterator) ?Record {
        while (self.lines.next()) |line| {
            var words = std.mem.tokenizeAny(u8, line, " \t");
            const key = words.next() orelse continue;
            const value_text = words.next() orelse continue;
            const value = std.fmt.parseInt(i64, value_text, 10) catch continue;
            return .{ .key = key, .value = value };
        }
        return null;
    }
};

pub fn records(data: []const u8) Iterator {
    return .{ .lines = std.mem.tokenizeAny(u8, data, "\r\n") };
}

test "records yield every well-formed line and skip the rest" {
    var iterator = records("page 3\r\n\nbookmark\tx\n  dark 1  \nnonsense\npage\n-7 5\n");
    const first = iterator.next().?;
    try std.testing.expectEqualStrings("page", first.key);
    try std.testing.expectEqual(@as(i64, 3), first.value);
    const second = iterator.next().?;
    try std.testing.expectEqualStrings("dark", second.key);
    try std.testing.expectEqual(@as(i64, 1), second.value);
    const third = iterator.next().?;
    try std.testing.expectEqualStrings("-7", third.key);
    try std.testing.expectEqual(@as(i64, 5), third.value);
    try std.testing.expectEqual(@as(?Record, null), iterator.next());
    try std.testing.expectEqual(@as(?Record, null), iterator.next());
}

test "empty input yields nothing" {
    var iterator = records("");
    try std.testing.expectEqual(@as(?Record, null), iterator.next());
}
