//! Small repository style check, implemented in Zig to keep tooling uniform.

const std = @import("std");

const maximum_line_length = 100;
const maximum_file_size = 2 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    var violation_found = false;

    for (arguments[1..]) |path| {
        const contents = try std.Io.Dir.cwd().readFileAlloc(
            init.io,
            path,
            init.gpa,
            .limited(maximum_file_size),
        );
        defer init.gpa.free(contents);

        violation_found = checkFile(path, contents) or violation_found;
    }

    if (violation_found) return error.StyleViolation;
}

fn checkFile(path: []const u8, contents: []const u8) bool {
    var violation_found = false;
    var line_iterator = std.mem.splitScalar(u8, contents, '\n');
    var line_number: usize = 1;

    while (line_iterator.next()) |line| : (line_number += 1) {
        if (line.len > maximum_line_length) {
            report(path, line_number, "line exceeds 100 bytes");
            violation_found = true;
        }
        if (std.mem.indexOfScalar(u8, line, '\t') != null) {
            report(path, line_number, "tab character found");
            violation_found = true;
        }
        if (line.len > 0 and (line[line.len - 1] == ' ' or line[line.len - 1] == '\r')) {
            report(path, line_number, "trailing whitespace found");
            violation_found = true;
        }
    }
    return violation_found;
}

fn report(path: []const u8, line_number: usize, message: []const u8) void {
    std.debug.print("{s}:{d}: {s}\n", .{ path, line_number, message });
}

test "style checker accepts clean source" {
    try std.testing.expect(!checkFile("clean.zig", "const answer = 42;\n"));
}

test "style checker accepts the exact line limit" {
    const line = "a" ** maximum_line_length;
    try std.testing.expect(!checkFile("limit.zig", line));
}

test "style checker rejects every supported violation" {
    const long_line = "a" ** (maximum_line_length + 1);
    try std.testing.expect(checkFile("long.zig", long_line));
    try std.testing.expect(checkFile("tab.zig", "const\tanswer = 42;\n"));
    try std.testing.expect(checkFile("space.zig", "const answer = 42; \n"));
    try std.testing.expect(checkFile("crlf.zig", "const answer = 42;\r\n"));
}
