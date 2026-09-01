//! Application-wide preferences and their text format.
//!
//! Preferences are not tied to a document. The reading theme lives here so it
//! survives opening another PDF, unlike per-document progress.

const std = @import("std");

pub const Preferences = struct {
    dark_mode: bool = true,

    pub fn parse(data: []const u8) Preferences {
        var preferences = Preferences{};
        var lines = std.mem.tokenizeAny(u8, data, "\r\n");
        while (lines.next()) |line| {
            var words = std.mem.tokenizeAny(u8, line, " \t");
            const key = words.next() orelse continue;
            const value_text = words.next() orelse continue;
            const value = std.fmt.parseInt(i64, value_text, 10) catch continue;
            if (std.mem.eql(u8, key, "dark")) preferences.dark_mode = value != 0;
        }
        return preferences;
    }

    pub fn serialize(self: Preferences, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "dark {d}\n", .{@intFromBool(self.dark_mode)});
    }
};

test "preferences round trip and default to dark mode" {
    try std.testing.expect(Preferences.parse("").dark_mode);
    try std.testing.expect(!Preferences.parse("dark 0\n").dark_mode);
    try std.testing.expect(Preferences.parse("dark 1\r\nunknown 4\n").dark_mode);
    try std.testing.expect(Preferences.parse("dark x\n").dark_mode);

    const light = Preferences{ .dark_mode = false };
    const data = try light.serialize(std.testing.allocator);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("dark 0\n", data);
    try std.testing.expect(!Preferences.parse(data).dark_mode);
}
