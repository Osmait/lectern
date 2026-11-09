//! Sectioned `key = value` text, the format of the configuration file and of
//! theme files.
//!
//! A line is a `[section]`, a `key = value`, or ignored: blank lines and
//! lines starting with `#` or `;` are comments. There are no trailing
//! comments, because a color value starts with `#`. Malformed lines are
//! skipped, so a damaged file degrades line by line.

const std = @import("std");

pub const Entry = struct {
    /// Empty for entries above the first section.
    section: []const u8,
    key: []const u8,
    /// Trimmed of blanks and of one pair of surrounding quotes; never empty.
    value: []const u8,

    pub fn in(self: Entry, section: []const u8) bool {
        return std.mem.eql(u8, self.section, section);
    }

    pub fn is(self: Entry, key: []const u8) bool {
        return std.mem.eql(u8, self.key, key);
    }
};

pub const Iterator = struct {
    lines: std.mem.TokenIterator(u8, .any),
    section: []const u8 = "",

    pub fn next(self: *Iterator) ?Entry {
        while (self.lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t");
            if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
            if (line[0] == '[') {
                const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
                self.section = std.mem.trim(u8, line[1..end], " \t");
                continue;
            }
            const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..equals], " \t");
            const value = unquote(std.mem.trim(u8, line[equals + 1 ..], " \t"));
            if (key.len == 0 or value.len == 0) continue;
            return .{ .section = self.section, .key = key, .value = value };
        }
        return null;
    }
};

pub fn entries(data: []const u8) Iterator {
    return .{ .lines = std.mem.tokenizeAny(u8, data, "\r\n") };
}

fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2) {
        const first = value[0];
        if ((first == '"' or first == '\'') and value[value.len - 1] == first) {
            return std.mem.trim(u8, value[1 .. value.len - 1], " \t");
        }
    }
    return value;
}

pub fn parseBool(value: []const u8) ?bool {
    for ([_][]const u8{ "true", "yes", "on", "1" }) |word| {
        if (std.ascii.eqlIgnoreCase(value, word)) return true;
    }
    for ([_][]const u8{ "false", "no", "off", "0" }) |word| {
        if (std.ascii.eqlIgnoreCase(value, word)) return false;
    }
    return null;
}

test "entries carry their section and skip comments and malformed lines" {
    var iterator = entries(
        \\# a comment
        \\top = 1
        \\
        \\[general]
        \\theme = auto
        \\; another comment
        \\  font =  "Noto Sans"
        \\nonsense
        \\empty =
        \\= orphan
        \\[ colors ]
        \\accent = #2363d8
        \\[broken
        \\text='#111111'
    );
    const top = iterator.next().?;
    try std.testing.expect(top.in("") and top.is("top"));
    try std.testing.expectEqualStrings("1", top.value);
    const theme = iterator.next().?;
    try std.testing.expect(theme.in("general") and theme.is("theme"));
    try std.testing.expectEqualStrings("auto", theme.value);
    const font = iterator.next().?;
    try std.testing.expect(font.in("general") and font.is("font"));
    try std.testing.expectEqualStrings("Noto Sans", font.value);
    const accent = iterator.next().?;
    try std.testing.expect(accent.in("colors") and accent.is("accent"));
    try std.testing.expectEqualStrings("#2363d8", accent.value);
    // A section header that never closes is skipped; the section stays.
    const text = iterator.next().?;
    try std.testing.expect(text.in("colors") and text.is("text"));
    try std.testing.expectEqualStrings("#111111", text.value);
    try std.testing.expectEqual(@as(?Entry, null), iterator.next());
}

test "empty input and CRLF line endings are handled" {
    var empty = entries("");
    try std.testing.expectEqual(@as(?Entry, null), empty.next());
    var windows = entries("[view]\r\nrail = off\r\n");
    const rail = windows.next().?;
    try std.testing.expect(rail.in("view") and rail.is("rail"));
    try std.testing.expectEqualStrings("off", rail.value);
}

test "booleans accept the usual words" {
    try std.testing.expectEqual(@as(?bool, true), parseBool("Yes"));
    try std.testing.expectEqual(@as(?bool, true), parseBool("1"));
    try std.testing.expectEqual(@as(?bool, false), parseBool("off"));
    try std.testing.expectEqual(@as(?bool, null), parseBool("maybe"));
}
