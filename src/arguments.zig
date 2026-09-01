//! Command line options. Parsing needs no native library, so a usage error
//! costs nothing and can be unit tested anywhere.

const std = @import("std");

pub const RunOptions = struct {
    initial_path: ?[]const u8 = null,
    /// Opens the document, records one note, checks that it round trips
    /// through storage, and exits. Storage is a throwaway directory.
    smoke_test: bool = false,
};

pub fn parse(arguments: []const [:0]const u8) error{InvalidArguments}!RunOptions {
    if (arguments.len == 1) return .{};
    if (arguments.len == 2 and !std.mem.startsWith(u8, arguments[1], "--")) {
        return .{ .initial_path = arguments[1] };
    }
    if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "--smoke-test")) {
        return .{ .initial_path = arguments[2], .smoke_test = true };
    }
    return error.InvalidArguments;
}

test "command line accepts interactive, direct, and smoke-test modes" {
    const executable: [:0]const u8 = "lectern";
    const document: [:0]const u8 = "book.pdf";
    const smoke_test: [:0]const u8 = "--smoke-test";

    const interactive = try parse(&.{executable});
    try std.testing.expectEqual(@as(?[]const u8, null), interactive.initial_path);

    const direct = try parse(&.{ executable, document });
    try std.testing.expectEqualStrings(document, direct.initial_path.?);

    const smoke = try parse(&.{ executable, smoke_test, document });
    try std.testing.expect(smoke.smoke_test);
    try std.testing.expectEqualStrings(document, smoke.initial_path.?);
}

test "command line rejects incomplete and unknown options" {
    const executable: [:0]const u8 = "lectern";
    const smoke_test: [:0]const u8 = "--smoke-test";
    const unknown: [:0]const u8 = "--unknown";

    try std.testing.expectError(error.InvalidArguments, parse(&.{ executable, smoke_test }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ executable, unknown }));
}

test "command line rejects extra arguments and option-shaped paths" {
    const executable: [:0]const u8 = "lectern";
    const document: [:0]const u8 = "book.pdf";
    const extra: [:0]const u8 = "extra.pdf";
    const option_path: [:0]const u8 = "--book.pdf";

    try std.testing.expectError(error.InvalidArguments, parse(&.{ executable, document, extra }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ executable, option_path }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{}));
}
