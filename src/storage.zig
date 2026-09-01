//! File storage for reading progress, annotations, and preferences.
//!
//! Files live in one state directory and are always written atomically, so a
//! crash mid-write leaves the previous version intact. File names for a
//! document derive from a hash of its absolute path, which keeps compatibility
//! with state written by earlier versions.

const std = @import("std");

pub const preferences_name = "preferences";
pub const maximum_file_size = 64 * 1024 * 1024;

pub const DocumentKey = struct {
    pub const name_capacity = 32;

    hex: [16]u8,

    pub fn of(document_path: []const u8) DocumentKey {
        const hash = std.hash.Fnv1a_64.hash(document_path);
        var key: DocumentKey = undefined;
        _ = std.fmt.bufPrint(&key.hex, "{x:0>16}", .{hash}) catch unreachable;
        return key;
    }

    pub fn progressName(self: DocumentKey, buffer: *[name_capacity]u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{s}.state", .{&self.hex}) catch unreachable;
    }

    pub fn notesName(self: DocumentKey, buffer: *[name_capacity]u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{s}.state.notes", .{&self.hex}) catch unreachable;
    }
};

pub const Storage = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: ?std.Io.Dir,
    owns_dir: bool,

    pub const Options = struct {
        xdg_state_home: ?[]const u8 = null,
        home: ?[]const u8 = null,
    };

    /// Opens or creates the state directory. When no location is available
    /// the storage stays usable and simply reports every file as missing.
    pub fn open(io: std.Io, allocator: std.mem.Allocator, options: Options) Storage {
        const directory = stateDirectory(allocator, options) orelse {
            std.log.warn("no state directory available; progress will not be saved", .{});
            return .{ .io = io, .allocator = allocator, .dir = null, .owns_dir = false };
        };
        defer allocator.free(directory);
        const dir = std.Io.Dir.cwd().createDirPathOpen(io, directory, .{}) catch |err| {
            std.log.warn("could not open state directory {s}: {s}", .{
                directory,
                @errorName(err),
            });
            return .{ .io = io, .allocator = allocator, .dir = null, .owns_dir = false };
        };
        return .{ .io = io, .allocator = allocator, .dir = dir, .owns_dir = true };
    }

    pub fn fromDir(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir) Storage {
        return .{ .io = io, .allocator = allocator, .dir = dir, .owns_dir = false };
    }

    pub fn deinit(self: *Storage) void {
        if (self.owns_dir) {
            if (self.dir) |dir| dir.close(self.io);
        }
        self.* = undefined;
    }

    pub fn isAvailable(self: Storage) bool {
        return self.dir != null;
    }

    /// Returns the file contents or null when the file does not exist. Read
    /// failures other than exhausted memory are logged and treated as
    /// missing so the reader stays usable.
    pub fn read(
        self: Storage,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) error{OutOfMemory}!?[]u8 {
        const dir = self.dir orelse return null;
        const limit: std.Io.Limit = .limited(maximum_file_size);
        return dir.readFileAlloc(self.io, name, allocator, limit) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FileNotFound => return null,
            else => {
                std.log.warn("could not read {s}: {s}", .{ name, @errorName(err) });
                return null;
            },
        };
    }

    pub fn write(self: Storage, name: []const u8, data: []const u8) !void {
        const dir = self.dir orelse return error.StorageUnavailable;
        var atomic = try dir.createFileAtomic(self.io, name, .{ .replace = true });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, data);
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
    }
};

fn stateDirectory(allocator: std.mem.Allocator, options: Storage.Options) ?[]u8 {
    if (options.xdg_state_home) |xdg| {
        if (xdg.len > 0) {
            return std.fmt.allocPrint(allocator, "{s}/book-read", .{xdg}) catch null;
        }
    }
    if (options.home) |home| {
        if (home.len > 0) {
            return std.fmt.allocPrint(allocator, "{s}/.local/state/book-read", .{home}) catch null;
        }
    }
    return null;
}

test "document keys derive stable names from the document path" {
    const key = DocumentKey.of("/library/book.pdf");
    const same = DocumentKey.of("/library/book.pdf");
    const other = DocumentKey.of("/library/other.pdf");
    try std.testing.expectEqualStrings(&key.hex, &same.hex);
    try std.testing.expect(!std.mem.eql(u8, &key.hex, &other.hex));

    var buffer: [DocumentKey.name_capacity]u8 = undefined;
    const progress_name = key.progressName(&buffer);
    try std.testing.expectEqual(@as(usize, 22), progress_name.len);
    try std.testing.expect(std.mem.endsWith(u8, progress_name, ".state"));
    var notes_buffer: [DocumentKey.name_capacity]u8 = undefined;
    try std.testing.expect(std.mem.endsWith(u8, key.notesName(&notes_buffer), ".state.notes"));
    // The hash matches the FNV-1a value the original native bridge produced.
    try std.testing.expectEqualStrings("cbf29ce484222325", &DocumentKey.of("").hex);
}

test "storage writes atomically and reads back files from the state directory" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var storage = Storage.fromDir(std.testing.io, std.testing.allocator, tmp.dir);
    defer storage.deinit();
    try std.testing.expect(storage.isAvailable());

    const missing = try storage.read(std.testing.allocator, "missing");
    try std.testing.expectEqual(@as(?[]u8, null), missing);
    try storage.write("notes", "first");
    try storage.write("notes", "second version");
    const data = (try storage.read(std.testing.allocator, "notes")) orelse {
        return error.ExpectedFile;
    };
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("second version", data);

    var names = tmp.dir.iterate();
    var file_count: usize = 0;
    while (try names.next(std.testing.io)) |entry| {
        try std.testing.expectEqualStrings("notes", entry.name);
        file_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), file_count);
}

test "storage resolves the state directory from the environment" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const root = path_buffer[0..length];

    var storage = Storage.open(std.testing.io, std.testing.allocator, .{ .xdg_state_home = root });
    defer storage.deinit();
    try std.testing.expect(storage.isAvailable());
    try storage.write("preferences", "dark 0\n");
    const data = (try storage.read(std.testing.allocator, "preferences")) orelse {
        return error.ExpectedFile;
    };
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("dark 0\n", data);
    try tmp.dir.access(std.testing.io, "book-read/preferences", .{});

    var fallback = Storage.open(std.testing.io, std.testing.allocator, .{
        .xdg_state_home = "",
        .home = root,
    });
    defer fallback.deinit();
    try std.testing.expect(fallback.isAvailable());
    try fallback.write("a", "b");
    try tmp.dir.access(std.testing.io, ".local/state/book-read/a", .{});
}

test "unavailable storage reads nothing and rejects writes" {
    var storage = Storage.open(std.testing.io, std.testing.allocator, .{});
    defer storage.deinit();
    try std.testing.expect(!storage.isAvailable());
    try std.testing.expectEqual(@as(?[]u8, null), try storage.read(std.testing.allocator, "notes"));
    try std.testing.expectError(error.StorageUnavailable, storage.write("notes", "data"));
}
