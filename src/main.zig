const std = @import("std");
const desktop = @import("desktop.zig");

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    const options = parseArguments(arguments) catch |err| {
        std.log.err("usage: book-read [PDF] | book-read --smoke-test PDF", .{});
        return err;
    };

    const context = try desktop.Context.init();
    var storage = desktop.Storage.open(init.io, init.gpa, .{
        .xdg_state_home = init.environ_map.get("XDG_STATE_HOME"),
        .home = init.environ_map.get("HOME"),
    });
    defer storage.deinit();

    var application = desktop.Application.init(init.gpa, context, storage);
    defer application.deinit();
    try application.run(options);
}

fn parseArguments(arguments: []const [:0]const u8) !desktop.Application.RunOptions {
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
    const executable: [:0]const u8 = "book-read";
    const document: [:0]const u8 = "book.pdf";
    const smoke_test: [:0]const u8 = "--smoke-test";

    const interactive = try parseArguments(&.{executable});
    try std.testing.expectEqual(@as(?[]const u8, null), interactive.initial_path);

    const direct = try parseArguments(&.{ executable, document });
    try std.testing.expectEqualStrings(document, direct.initial_path.?);

    const smoke = try parseArguments(&.{ executable, smoke_test, document });
    try std.testing.expect(smoke.smoke_test);
    try std.testing.expectEqualStrings(document, smoke.initial_path.?);
}

test "command line rejects incomplete and unknown options" {
    const executable: [:0]const u8 = "book-read";
    const smoke_test: [:0]const u8 = "--smoke-test";
    const unknown: [:0]const u8 = "--unknown";

    try std.testing.expectError(
        error.InvalidArguments,
        parseArguments(&.{ executable, smoke_test }),
    );
    try std.testing.expectError(
        error.InvalidArguments,
        parseArguments(&.{ executable, unknown }),
    );
}

test "command line rejects extra arguments and option-shaped paths" {
    const executable: [:0]const u8 = "book-read";
    const document: [:0]const u8 = "book.pdf";
    const extra: [:0]const u8 = "extra.pdf";
    const option_path: [:0]const u8 = "--book.pdf";

    try std.testing.expectError(
        error.InvalidArguments,
        parseArguments(&.{ executable, document, extra }),
    );
    try std.testing.expectError(
        error.InvalidArguments,
        parseArguments(&.{ executable, option_path }),
    );
    try std.testing.expectError(error.InvalidArguments, parseArguments(&.{}));
}

test {
    _ = desktop;
}
