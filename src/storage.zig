//! File storage for reading progress, annotations, and preferences.
//!
//! Files live in one state directory and are always written atomically, so a
//! crash mid-write leaves the previous version intact. File names for a
//! document derive from a hash of its absolute path, which keeps compatibility
//! with state written by earlier versions.
//!
//! Writes run on a background thread because every one of them syncs to disk,
//! which can stall for tens of milliseconds. The caller queues the data and
//! learns later, through completions, whether it reached the disk. Only the
//! newest queued write per file name is kept, so a burst of edits costs one
//! write. A `Storage` value must not move once the first write was queued,
//! because the worker keeps a pointer to it.

const std = @import("std");

pub const preferences_name = "preferences";
pub const maximum_file_size = 64 * 1024 * 1024;
/// Longest file name the storage accepts; document keys and the preferences
/// name fit with room to spare.
pub const name_capacity = 32;

/// A file name kept inline, so completions never point into freed memory.
pub const Name = struct {
    bytes: [name_capacity]u8 = undefined,
    length: u8 = 0,

    pub fn of(text: []const u8) Name {
        std.debug.assert(text.len <= name_capacity);
        var name = Name{ .length = @intCast(text.len) };
        @memcpy(name.bytes[0..text.len], text);
        return name;
    }

    pub fn slice(self: *const Name) []const u8 {
        return self.bytes[0..self.length];
    }

    pub fn eql(self: *const Name, text: []const u8) bool {
        return std.mem.eql(u8, self.slice(), text);
    }
};

/// Reported once for every queued write after it finished.
pub const Completion = struct {
    name: Name,
    failed: bool,
};

pub const DocumentKey = struct {
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

pub const WriteError = error{ StorageUnavailable, OutOfMemory };

const PendingWrite = struct {
    name: Name,
    data: []u8,
};

const Temporary = struct {
    parent: std.Io.Dir,
    name: [48]u8,
    name_length: usize,

    fn slice(self: *const Temporary) []const u8 {
        return self.name[0..self.name_length];
    }
};

pub const Storage = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: ?std.Io.Dir,
    owns_dir: bool,
    temporary: ?Temporary = null,

    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    pending: std.ArrayList(PendingWrite) = .empty,
    completions: std.ArrayList(Completion) = .empty,
    writing: bool = false,
    quit: bool = false,
    thread: ?std.Thread = null,
    /// Writes that ran on the caller's thread because no worker could start.
    synchronous_write_count: usize = 0,

    pub const Options = struct {
        xdg_state_home: ?[]const u8 = null,
        home: ?[]const u8 = null,
    };

    pub const TemporaryOptions = struct {
        tmpdir: ?[]const u8 = null,
    };

    /// Opens or creates the state directory. When no location is available
    /// the storage stays usable and simply reports every file as missing.
    /// State written under the application's former name is adopted once.
    pub fn open(io: std.Io, allocator: std.mem.Allocator, options: Options) Storage {
        const directory = stateDirectory(allocator, options, directory_name) orelse {
            std.log.warn("no state directory available; progress will not be saved", .{});
            return unavailable(io, allocator);
        };
        defer allocator.free(directory);
        adoptFormerDirectory(io, allocator, options, directory);
        const dir = std.Io.Dir.cwd().createDirPathOpen(io, directory, .{}) catch |err| {
            std.log.warn("could not open state directory {s}: {s}", .{
                directory,
                @errorName(err),
            });
            return unavailable(io, allocator);
        };
        return .{ .io = io, .allocator = allocator, .dir = dir, .owns_dir = true };
    }

    /// Creates a fresh directory that is deleted again on `deinit`, so a
    /// throwaway run never reads or overwrites the user's real state.
    pub fn openTemporary(
        io: std.Io,
        allocator: std.mem.Allocator,
        options: TemporaryOptions,
    ) Storage {
        const base = options.tmpdir orelse "/tmp";
        const parent = std.Io.Dir.openDirAbsolute(io, base, .{}) catch |err| {
            std.log.warn("could not open {s} for temporary state: {s}", .{
                base,
                @errorName(err),
            });
            return unavailable(io, allocator);
        };
        var temporary = Temporary{ .parent = parent, .name = undefined, .name_length = 0 };
        const stamp: u96 = @bitCast(std.Io.Clock.real.now(io).toNanoseconds());
        const name = std.fmt.bufPrint(&temporary.name, "lectern-smoke-{x}", .{
            @as(u64, @truncate(stamp)),
        }) catch unreachable;
        temporary.name_length = name.len;
        const dir = parent.createDirPathOpen(io, name, .{}) catch |err| {
            std.log.warn("could not create temporary state directory: {s}", .{@errorName(err)});
            parent.close(io);
            return unavailable(io, allocator);
        };
        return .{
            .io = io,
            .allocator = allocator,
            .dir = dir,
            .owns_dir = true,
            .temporary = temporary,
        };
    }

    pub fn fromDir(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir) Storage {
        return .{ .io = io, .allocator = allocator, .dir = dir, .owns_dir = false };
    }

    fn unavailable(io: std.Io, allocator: std.mem.Allocator) Storage {
        return .{ .io = io, .allocator = allocator, .dir = null, .owns_dir = false };
    }

    /// Finishes every queued write before releasing the directory.
    pub fn deinit(self: *Storage) void {
        self.flush();
        self.mutex.lockUncancelable(self.io);
        self.quit = true;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
        if (self.thread) |thread| thread.join();
        self.pending.deinit(self.allocator);
        self.completions.deinit(self.allocator);
        if (self.owns_dir) {
            if (self.dir) |dir| dir.close(self.io);
        }
        if (self.temporary) |*temporary| {
            temporary.parent.deleteTree(self.io, temporary.slice()) catch |err| {
                std.log.warn("could not delete temporary state: {s}", .{@errorName(err)});
            };
            temporary.parent.close(self.io);
        }
        self.* = undefined;
    }

    pub fn isAvailable(self: *const Storage) bool {
        return self.dir != null;
    }

    /// Returns the file contents or null when the file does not exist. Read
    /// failures other than exhausted memory are logged and treated as
    /// missing so the reader stays usable. Queued writes finish first, so a
    /// read never returns a version older than what was queued.
    pub fn read(
        self: *Storage,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) error{OutOfMemory}!?[]u8 {
        const dir = self.dir orelse return null;
        self.flush();
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

    /// Queues an atomic write of `data`, which is copied. A completion is
    /// reported later; an older queued write of the same name is replaced.
    pub fn write(self: *Storage, name: []const u8, data: []const u8) WriteError!void {
        if (self.dir == null) return error.StorageUnavailable;
        const copy = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(copy);
        const pending = PendingWrite{ .name = Name.of(name), .data = copy };

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.pending.items) |*queued| {
            if (queued.name.eql(name)) {
                self.allocator.free(queued.data);
                queued.* = pending;
                return;
            }
        }
        try self.pending.append(self.allocator, pending);
        if (self.thread == null) self.startWorkerLocked();
        self.condition.broadcast(self.io);
    }

    pub fn hasPendingWrites(self: *Storage) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.pending.items.len > 0 or self.writing;
    }

    pub fn pollCompletion(self: *Storage) ?Completion {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.completions.items.len == 0) return null;
        return self.completions.orderedRemove(0);
    }

    /// Blocks until every queued write has finished.
    pub fn flush(self: *Storage) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.pending.items.len > 0 or self.writing) {
            self.condition.waitUncancelable(self.io, &self.mutex);
        }
    }

    /// Starts the worker, or falls back to writing on the calling thread when
    /// the system refuses another thread.
    fn startWorkerLocked(self: *Storage) void {
        const thread = std.Thread.spawn(.{}, worker, .{self}) catch |err| {
            std.log.warn("could not start the storage thread: {s}", .{@errorName(err)});
            while (self.pending.items.len > 0) {
                const item = self.pending.orderedRemove(0);
                self.synchronous_write_count += 1;
                self.finish(item);
            }
            return;
        };
        // The name only helps profilers and debuggers tell threads apart.
        thread.setName(self.io, "lectern-storage") catch {};
        self.thread = thread;
    }

    fn worker(self: *Storage) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (true) {
            if (self.pending.items.len == 0) {
                if (self.quit) return;
                self.condition.waitUncancelable(self.io, &self.mutex);
                continue;
            }
            const item = self.pending.orderedRemove(0);
            self.writing = true;
            self.mutex.unlock(self.io);
            const failed = self.writeFile(item.name.slice(), item.data);
            self.allocator.free(item.data);
            self.mutex.lockUncancelable(self.io);
            self.writing = false;
            self.recordCompletion(item.name, failed);
            self.condition.broadcast(self.io);
        }
    }

    /// Writes one queued item on the current thread while the lock is held.
    fn finish(self: *Storage, item: PendingWrite) void {
        const failed = self.writeFile(item.name.slice(), item.data);
        self.allocator.free(item.data);
        self.recordCompletion(item.name, failed);
    }

    fn recordCompletion(self: *Storage, name: Name, failed: bool) void {
        self.completions.append(self.allocator, .{ .name = name, .failed = failed }) catch {
            std.log.warn("could not record the completion of {s}", .{name.slice()});
        };
    }

    /// Returns true when the write failed. The failure is logged here, where
    /// the file name and cause are known.
    fn writeFile(self: *Storage, name: []const u8, data: []const u8) bool {
        const dir = self.dir orelse return true;
        self.writeAtomically(dir, name, data) catch |err| {
            std.log.warn("could not write {s}: {s}", .{ name, @errorName(err) });
            return true;
        };
        return false;
    }

    fn writeAtomically(self: *Storage, dir: std.Io.Dir, name: []const u8, data: []const u8) !void {
        var atomic = try dir.createFileAtomic(self.io, name, .{ .replace = true });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, data);
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
    }
};

/// The state directory under `XDG_STATE_HOME` or `~/.local/state`.
pub const directory_name = "lectern";
/// The name the application had before; its state is moved over on the
/// first start, so progress, bookmarks, and notes survive the rename.
pub const former_directory_name = "book-read";

fn stateDirectory(
    allocator: std.mem.Allocator,
    options: Storage.Options,
    name: []const u8,
) ?[]u8 {
    if (options.xdg_state_home) |xdg| {
        if (xdg.len > 0) {
            return std.fmt.allocPrint(allocator, "{s}/{s}", .{ xdg, name }) catch null;
        }
    }
    if (options.home) |home| {
        if (home.len > 0) {
            const path = std.fmt.allocPrint(allocator, "{s}/.local/state/{s}", .{ home, name });
            return path catch null;
        }
    }
    return null;
}

/// Renames the former state directory to the current one when the current
/// one does not exist yet. Any failure leaves both directories alone; the
/// reader then simply starts without the old state.
fn adoptFormerDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: Storage.Options,
    directory: []const u8,
) void {
    const former = stateDirectory(allocator, options, former_directory_name) orelse return;
    defer allocator.free(former);
    const cwd = std.Io.Dir.cwd();
    cwd.access(io, directory, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            cwd.access(io, former, .{}) catch return;
            cwd.rename(former, cwd, directory, io) catch |rename_error| {
                std.log.warn("could not adopt the state in {s}: {s}", .{
                    former,
                    @errorName(rename_error),
                });
            };
        },
        else => {},
    };
}

test "document keys derive stable names from the document path" {
    const key = DocumentKey.of("/library/book.pdf");
    const same = DocumentKey.of("/library/book.pdf");
    const other = DocumentKey.of("/library/other.pdf");
    try std.testing.expectEqualStrings(&key.hex, &same.hex);
    try std.testing.expect(!std.mem.eql(u8, &key.hex, &other.hex));

    var buffer: [name_capacity]u8 = undefined;
    const progress_name = key.progressName(&buffer);
    try std.testing.expectEqual(@as(usize, 22), progress_name.len);
    try std.testing.expect(std.mem.endsWith(u8, progress_name, ".state"));
    var notes_buffer: [name_capacity]u8 = undefined;
    try std.testing.expect(std.mem.endsWith(u8, key.notesName(&notes_buffer), ".state.notes"));
    // The hash matches the FNV-1a value the original native bridge produced.
    try std.testing.expectEqualStrings("cbf29ce484222325", &DocumentKey.of("").hex);
    try std.testing.expect(Name.of(preferences_name).eql(preferences_name));
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
    try std.testing.expect(!storage.hasPendingWrites());

    var names = tmp.dir.iterate();
    var file_count: usize = 0;
    while (try names.next(std.testing.io)) |entry| {
        try std.testing.expectEqualStrings("notes", entry.name);
        file_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), file_count);
}

test "queued writes report completions and failures by name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = Storage.fromDir(std.testing.io, std.testing.allocator, tmp.dir);
    defer storage.deinit();

    try storage.write("preferences", "dark 1\n");
    try storage.write("missing-directory/notes", "unreachable");
    storage.flush();
    var completed: usize = 0;
    var failed: usize = 0;
    while (storage.pollCompletion()) |completion| {
        completed += 1;
        if (completion.failed) {
            failed += 1;
            try std.testing.expect(completion.name.eql("missing-directory/notes"));
        } else {
            try std.testing.expect(completion.name.eql("preferences"));
        }
    }
    try std.testing.expectEqual(@as(usize, 2), completed);
    try std.testing.expectEqual(@as(usize, 1), failed);
    try std.testing.expectEqual(@as(?Completion, null), storage.pollCompletion());
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
    try tmp.dir.access(std.testing.io, "lectern/preferences", .{});

    var fallback = Storage.open(std.testing.io, std.testing.allocator, .{
        .xdg_state_home = "",
        .home = root,
    });
    defer fallback.deinit();
    try std.testing.expect(fallback.isAvailable());
    try fallback.write("a", "b");
    fallback.flush();
    try tmp.dir.access(std.testing.io, ".local/state/lectern/a", .{});
}

test "temporary storage lives in its own directory and disappears on deinit" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const root = path_buffer[0..length];

    var storage = Storage.openTemporary(std.testing.io, std.testing.allocator, .{ .tmpdir = root });
    try std.testing.expect(storage.isAvailable());
    try storage.write("notes", "smoke");
    storage.flush();
    var created: usize = 0;
    var entries = tmp.dir.iterate();
    while (try entries.next(std.testing.io)) |entry| {
        try std.testing.expect(std.mem.startsWith(u8, entry.name, "lectern-smoke-"));
        created += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), created);

    storage.deinit();
    var remaining = tmp.dir.iterate();
    try std.testing.expectEqual(@as(?std.Io.Dir.Entry, null), try remaining.next(std.testing.io));
}

test "state saved under the former name is adopted once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const root = path_buffer[0..length];
    try tmp.dir.createDirPath(std.testing.io, former_directory_name);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = former_directory_name ++ "/preferences",
        .data = "dark 0\n",
    });

    var storage = Storage.open(std.testing.io, std.testing.allocator, .{ .xdg_state_home = root });
    defer storage.deinit();
    const data = (try storage.read(std.testing.allocator, "preferences")) orelse {
        return error.ExpectedAdoptedFile;
    };
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("dark 0\n", data);
    try tmp.dir.access(std.testing.io, directory_name ++ "/preferences", .{});
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(std.testing.io, former_directory_name, .{}),
    );

    // Once the current directory exists, an old one left behind is ignored.
    try tmp.dir.createDirPath(std.testing.io, former_directory_name);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = former_directory_name ++ "/preferences",
        .data = "dark 1\n",
    });
    var again = Storage.open(std.testing.io, std.testing.allocator, .{ .xdg_state_home = root });
    defer again.deinit();
    const kept = (try again.read(std.testing.allocator, "preferences")) orelse {
        return error.ExpectedAdoptedFile;
    };
    defer std.testing.allocator.free(kept);
    try std.testing.expectEqualStrings("dark 0\n", kept);
}

test "unavailable storage reads nothing and rejects writes" {
    var storage = Storage.open(std.testing.io, std.testing.allocator, .{});
    defer storage.deinit();
    try std.testing.expect(!storage.isAvailable());
    try std.testing.expectEqual(@as(?[]u8, null), try storage.read(std.testing.allocator, "notes"));
    try std.testing.expectError(error.StorageUnavailable, storage.write("notes", "data"));
    try std.testing.expect(!storage.hasPendingWrites());
}
