//! The files the look is read from, and a watcher that reports when one of
//! them changes.
//!
//! The configuration lives in `$XDG_CONFIG_HOME/lectern`: `config.ini` and a
//! `themes` folder. The desktop palette is `rice/palette.json` under
//! `$XDG_CACHE_HOME`, the file the desktop's own panels follow. The folder
//! and a commented `config.ini` are created on the first start, so the
//! settings document themselves where they are edited.
//!
//! The watcher is one thread blocked in the kernel on inotify, so an idle
//! reader still costs no CPU. It watches the folders, not the files, because
//! editors and theme switchers replace files instead of writing into them.
//! A `ConfigFiles` value must not move once `watch` was called, because the
//! thread keeps a pointer to it.

const std = @import("std");
const ui_config = @import("ui/config.zig");

const linux = std.os.linux;

pub const directory_name = "lectern";
pub const config_name = "config.ini";
pub const themes_name = "themes";
pub const theme_extension = ".ini";
/// A theme to copy from, written beside the first `config.ini`.
pub const example_theme_name = "example";
const example_theme_path = themes_name ++ "/" ++ example_theme_name ++ theme_extension;
pub const palette_directory_name = "rice";
pub const palette_name = "palette.json";
/// Far above any real configuration; a larger file is not one.
pub const maximum_file_size = 1024 * 1024;

pub const ConfigFiles = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    /// Absolute paths; null when the environment names no location.
    directory: ?[:0]u8 = null,
    themes_directory: ?[:0]u8 = null,
    palette_directory: ?[:0]u8 = null,
    /// Set by the watcher thread and taken by the frame loop.
    changed: std.atomic.Value(bool) = .init(false),
    /// Ends the frame loop's wait; called from the watcher thread.
    wake: ?*const fn () void = null,
    watcher: ?Watcher = null,
    thread: ?std.Thread = null,

    pub const Options = struct {
        xdg_config_home: ?[]const u8 = null,
        xdg_cache_home: ?[]const u8 = null,
        home: ?[]const u8 = null,
        wake: ?*const fn () void = null,
    };

    const Watcher = struct {
        inotify: linux.fd_t,
        /// An eventfd; writing to it ends the thread.
        stop: linux.fd_t,
        directory_watch: i32,
        themes_watch: i32,
        palette_watch: i32,
    };

    /// Resolves the locations and creates the configuration folder with its
    /// commented `config.ini` when they do not exist yet. Nothing here is
    /// fatal: without a location every file simply reads as missing.
    pub fn open(io: std.Io, allocator: std.mem.Allocator, options: Options) ConfigFiles {
        var files = ConfigFiles{ .io = io, .allocator = allocator, .wake = options.wake };
        const home = options.home;
        const config_home = baseDirectory(allocator, options.xdg_config_home, home, ".config");
        defer if (config_home) |path| allocator.free(path);
        const cache_home = baseDirectory(allocator, options.xdg_cache_home, home, ".cache");
        defer if (cache_home) |path| allocator.free(path);
        if (config_home) |base| {
            files.directory = joinZ(allocator, &.{ base, directory_name });
            files.themes_directory = joinZ(allocator, &.{ base, directory_name, themes_name });
        }
        if (cache_home) |base| {
            files.palette_directory = joinZ(allocator, &.{ base, palette_directory_name });
        }
        files.createDefaults();
        return files;
    }

    /// No locations at all: every file reads as missing and nothing is
    /// watched. For runs that must not see the user's configuration.
    pub fn disabled(io: std.Io, allocator: std.mem.Allocator) ConfigFiles {
        return .{ .io = io, .allocator = allocator };
    }

    pub fn deinit(self: *ConfigFiles) void {
        if (self.watcher) |watcher| {
            const one: u64 = 1;
            _ = linux.write(watcher.stop, std.mem.asBytes(&one), @sizeOf(u64));
            if (self.thread) |thread| thread.join();
            _ = linux.close(watcher.inotify);
            _ = linux.close(watcher.stop);
        }
        if (self.directory) |path| self.allocator.free(path);
        if (self.themes_directory) |path| self.allocator.free(path);
        if (self.palette_directory) |path| self.allocator.free(path);
        self.* = undefined;
    }

    /// Returns the file contents, or null when the file does not exist or
    /// cannot be read; the look then falls back, so a read failure other
    /// than exhausted memory is only logged.
    pub fn read(
        self: *ConfigFiles,
        allocator: std.mem.Allocator,
        file: ui_config.File,
    ) error{OutOfMemory}!?[]u8 {
        const path = (try self.pathOf(allocator, file)) orelse return null;
        defer allocator.free(path);
        const limit: std.Io.Limit = .limited(maximum_file_size);
        const cwd = std.Io.Dir.cwd();
        return cwd.readFileAlloc(self.io, path, allocator, limit) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FileNotFound => return null,
            else => {
                std.log.warn("could not read {s}: {s}", .{ path, @errorName(err) });
                return null;
            },
        };
    }

    /// True once after one or more watched files changed.
    pub fn takeChanged(self: *ConfigFiles) bool {
        return self.changed.swap(false, .acq_rel);
    }

    /// Starts the watcher thread. Without it the files are still read, only
    /// never again after the start; a failure here is therefore a warning.
    pub fn watch(self: *ConfigFiles) void {
        if (self.watcher != null) return;
        const inotify = descriptor(linux.inotify_init1(in_cloexec)) orelse {
            std.log.warn("could not watch the configuration; it is read once", .{});
            return;
        };
        const stop = descriptor(linux.eventfd(0, efd_cloexec)) orelse {
            _ = linux.close(inotify);
            std.log.warn("could not watch the configuration; it is read once", .{});
            return;
        };
        const watcher = Watcher{
            .inotify = inotify,
            .stop = stop,
            .directory_watch = addWatch(inotify, self.directory),
            .themes_watch = addWatch(inotify, self.themes_directory),
            .palette_watch = addWatch(inotify, self.palette_directory),
        };
        const thread = std.Thread.spawn(.{}, watchLoop, .{ self, watcher }) catch |err| {
            std.log.warn("could not start the configuration watcher: {s}", .{@errorName(err)});
            _ = linux.close(inotify);
            _ = linux.close(stop);
            return;
        };
        // The name only helps profilers and debuggers tell threads apart.
        thread.setName(self.io, "lectern-config") catch {};
        self.watcher = watcher;
        self.thread = thread;
    }

    fn pathOf(
        self: *const ConfigFiles,
        allocator: std.mem.Allocator,
        file: ui_config.File,
    ) error{OutOfMemory}!?[]u8 {
        switch (file) {
            .config => {
                const directory = self.directory orelse return null;
                return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, config_name });
            },
            .theme => |name| {
                const directory = self.themes_directory orelse return null;
                return try std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{
                    directory, name, theme_extension,
                });
            },
            .desktop_palette => {
                const directory = self.palette_directory orelse return null;
                return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, palette_name });
            },
        }
    }

    /// Creates the folder, the themes folder, and a commented `config.ini`.
    /// An existing `config.ini` is never touched.
    fn createDefaults(self: *ConfigFiles) void {
        const directory = self.directory orelse return;
        const cwd = std.Io.Dir.cwd();
        const dir = cwd.createDirPathOpen(self.io, directory, .{}) catch |err| {
            std.log.warn("could not create {s}: {s}", .{ directory, @errorName(err) });
            return;
        };
        defer dir.close(self.io);
        if (dir.createDirPathOpen(self.io, themes_name, .{})) |themes| {
            themes.close(self.io);
        } else |err| {
            std.log.warn("could not create the themes folder: {s}", .{@errorName(err)});
        }
        // Only a first start writes files: a configuration that is there,
        // even an emptied one, belongs to the user.
        dir.access(self.io, config_name, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                self.writeTemplate(dir, config_name, ui_config.template);
                self.writeTemplate(dir, example_theme_path, ui_config.theme_template);
            },
            else => {},
        };
    }

    fn writeTemplate(self: *ConfigFiles, dir: std.Io.Dir, path: []const u8, data: []const u8) void {
        self.writeFile(dir, path, data) catch |err| {
            std.log.warn("could not write {s}: {s}", .{ path, @errorName(err) });
        };
    }

    fn writeFile(self: *ConfigFiles, dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
        var atomic = try dir.createFileAtomic(self.io, path, .{ .replace = true });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, data);
        try atomic.replace(self.io);
    }

    /// The thread only touches `changed` and `wake` of the shared value;
    /// its descriptors arrive by copy.
    fn watchLoop(self: *ConfigFiles, watcher: Watcher) void {
        var descriptors = [2]linux.pollfd{
            .{ .fd = watcher.inotify, .events = poll_in, .revents = 0 },
            .{ .fd = watcher.stop, .events = poll_in, .revents = 0 },
        };
        // Events carry a header and a name; this holds dozens of them, and
        // the kernel never splits one across reads.
        var buffer: [4096]u8 align(@alignOf(u32)) = undefined;
        while (true) {
            const ready: isize = @bitCast(linux.poll(&descriptors, descriptors.len, -1));
            if (ready < 0) {
                if (ready == -interrupted) continue;
                return;
            }
            if (descriptors[1].revents != 0) return;
            if (descriptors[0].revents == 0) continue;
            const length: isize = @bitCast(linux.read(watcher.inotify, &buffer, buffer.len));
            if (length <= 0) {
                if (length == -interrupted) continue;
                return;
            }
            if (concerns(watcher, buffer[0..@intCast(length)])) {
                self.changed.store(true, .release);
                if (self.wake) |wake| wake();
            }
        }
    }

    /// Whether any event in the buffer is about a file the look reads. The
    /// cache folder holds other files that change all the time; only the
    /// palette counts there.
    fn concerns(watcher: Watcher, events: []const u8) bool {
        var offset: usize = 0;
        while (offset + event_header_size <= events.len) {
            const source = std.mem.bytesToValue(i32, events[offset..][0..4]);
            const mask = std.mem.bytesToValue(u32, events[offset + 4 ..][0..4]);
            const name_length = std.mem.bytesToValue(u32, events[offset + 12 ..][0..4]);
            const name_start = offset + event_header_size;
            const name_end = @min(name_start + name_length, events.len);
            const padded = events[name_start..name_end];
            const name = padded[0 .. std.mem.indexOfScalar(u8, padded, 0) orelse padded.len];
            offset = name_start + name_length;

            // The kernel dropped events: something may have changed.
            if (mask & in_queue_overflow != 0) return true;
            if (source == watcher.directory_watch) {
                if (std.mem.eql(u8, name, config_name)) return true;
            } else if (source == watcher.themes_watch) {
                if (std.mem.endsWith(u8, name, theme_extension)) return true;
            } else if (source == watcher.palette_watch) {
                if (std.mem.eql(u8, name, palette_name)) return true;
            }
        }
        return false;
    }
};

// Kernel constants of inotify, eventfd, and poll. They are part of the Linux
// ABI and never change; spelling them here keeps this file independent of
// how the standard library names them.
const in_cloexec: u32 = 0o2000000;
const efd_cloexec: u32 = 0o2000000;
const in_close_write: u32 = 0x008;
const in_moved_from: u32 = 0x040;
const in_moved_to: u32 = 0x080;
const in_delete: u32 = 0x200;
const in_queue_overflow: u32 = 0x4000;
/// A file counts as changed when a writer closes it, or when it is renamed
/// into place or removed. Creation and partial writes are left out, so a
/// file is never read half written.
const watch_mask: u32 = in_close_write | in_moved_from | in_moved_to | in_delete;
const poll_in: i16 = 0x001;
const interrupted: isize = 4;
const event_header_size = 16;

/// A file descriptor from a raw system call result, or null on failure.
fn descriptor(result: usize) ?linux.fd_t {
    const signed: isize = @bitCast(result);
    if (signed < 0) return null;
    return @intCast(signed);
}

/// The watch descriptor, or -1 when the folder is absent or cannot be
/// watched; no event ever carries -1 for a real watch.
fn addWatch(inotify: linux.fd_t, directory: ?[:0]u8) i32 {
    const path = directory orelse return -1;
    const result: isize = @bitCast(linux.inotify_add_watch(inotify, path.ptr, watch_mask));
    if (result < 0) return -1;
    return @intCast(result);
}

/// `$XDG_…_HOME`, or its default under the home directory.
fn baseDirectory(
    allocator: std.mem.Allocator,
    xdg: ?[]const u8,
    home: ?[]const u8,
    fallback: []const u8,
) ?[]u8 {
    if (xdg) |path| {
        if (path.len > 0) return allocator.dupe(u8, path) catch null;
    }
    if (home) |path| {
        if (path.len > 0) {
            return std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, fallback }) catch null;
        }
    }
    return null;
}

fn joinZ(allocator: std.mem.Allocator, parts: []const []const u8) ?[:0]u8 {
    var length: usize = parts.len - 1;
    for (parts) |part| length += part.len;
    const path = allocator.allocSentinel(u8, length, 0) catch return null;
    var offset: usize = 0;
    for (parts, 0..) |part, index| {
        if (index > 0) {
            path[offset] = '/';
            offset += 1;
        }
        @memcpy(path[offset .. offset + part.len], part);
        offset += part.len;
    }
    return path;
}

fn testRoot(tmp: *std.testing.TmpDir, buffer: *[std.Io.Dir.max_path_bytes]u8) ![]const u8 {
    const length = try tmp.dir.realPath(std.testing.io, buffer);
    return buffer[0..length];
}

fn writeTestFile(tmp: *std.testing.TmpDir, path: []const u8, data: []const u8) !void {
    var atomic = try tmp.dir.createFileAtomic(std.testing.io, path, .{ .replace = true });
    defer atomic.deinit(std.testing.io);
    try atomic.file.writeStreamingAll(std.testing.io, data);
    try atomic.replace(std.testing.io);
}

test "the first start creates the folder with a commented configuration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try testRoot(&tmp, &buffer);

    var files = ConfigFiles.open(std.testing.io, std.testing.allocator, .{ .home = root });
    defer files.deinit();
    try tmp.dir.access(std.testing.io, ".config/lectern/themes", .{});
    const written = (try files.read(std.testing.allocator, .config)).?;
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings(ui_config.template, written);
    try std.testing.expectEqual(@as(?[]u8, null), try files.read(
        std.testing.allocator,
        .desktop_palette,
    ));
    try std.testing.expectEqual(@as(?[]u8, null), try files.read(
        std.testing.allocator,
        .{ .theme = "midnight" },
    ));
    const example = (try files.read(std.testing.allocator, .{ .theme = example_theme_name })).?;
    defer std.testing.allocator.free(example);
    try std.testing.expect(ui_config.fileSeeds(example) != null);
    try std.testing.expect(!files.takeChanged());

    // A configuration that is already there is left alone.
    try writeTestFile(&tmp, ".config/lectern/config.ini", "[general]\ntheme = nord\n");
    var again = ConfigFiles.open(std.testing.io, std.testing.allocator, .{ .home = root });
    defer again.deinit();
    const kept = (try again.read(std.testing.allocator, .config)).?;
    defer std.testing.allocator.free(kept);
    try std.testing.expectEqualStrings("[general]\ntheme = nord\n", kept);
}

test "files are found under the XDG locations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try testRoot(&tmp, &buffer);
    const config_home = try std.fmt.allocPrint(std.testing.allocator, "{s}/settings", .{root});
    defer std.testing.allocator.free(config_home);
    const cache_home = try std.fmt.allocPrint(std.testing.allocator, "{s}/cache", .{root});
    defer std.testing.allocator.free(cache_home);

    var files = ConfigFiles.open(std.testing.io, std.testing.allocator, .{
        .xdg_config_home = config_home,
        .xdg_cache_home = cache_home,
        .home = "/nonexistent",
    });
    defer files.deinit();
    try tmp.dir.access(std.testing.io, "settings/lectern/config.ini", .{});
    try writeTestFile(&tmp, "settings/lectern/themes/midnight.ini", "[theme]\n");
    var cache = try tmp.dir.createDirPathOpen(std.testing.io, "cache/rice", .{});
    cache.close(std.testing.io);
    try writeTestFile(&tmp, "cache/rice/palette.json", "{}");

    const theme_file = (try files.read(std.testing.allocator, .{ .theme = "midnight" })).?;
    defer std.testing.allocator.free(theme_file);
    try std.testing.expectEqualStrings("[theme]\n", theme_file);
    const palette = (try files.read(std.testing.allocator, .desktop_palette)).?;
    defer std.testing.allocator.free(palette);
    try std.testing.expectEqualStrings("{}", palette);
}

test "without a location nothing is read and nothing is watched" {
    var files = ConfigFiles.open(std.testing.io, std.testing.allocator, .{});
    defer files.deinit();
    try std.testing.expectEqual(@as(?[]u8, null), try files.read(std.testing.allocator, .config));
    files.watch();
    try std.testing.expect(!files.takeChanged());

    var none = ConfigFiles.disabled(std.testing.io, std.testing.allocator);
    defer none.deinit();
    try std.testing.expectEqual(@as(?[]u8, null), try none.read(
        std.testing.allocator,
        .desktop_palette,
    ));
}

var test_wake_count = std.atomic.Value(u32).init(0);

fn testWake() void {
    _ = test_wake_count.fetchAdd(1, .acq_rel);
}

/// Sleeps in the kernel with a poll on nothing, which needs no clock API.
fn pause(milliseconds: i32) void {
    var nothing: [1]linux.pollfd = undefined;
    _ = linux.poll(&nothing, 0, milliseconds);
}

/// Waits for the watcher thread to report a change; false after a second.
fn changedSoon(files: *ConfigFiles) bool {
    var attempt: usize = 0;
    while (attempt < 1000) : (attempt += 1) {
        if (files.takeChanged()) return true;
        pause(1);
    }
    return false;
}

test "the watcher reports the files of the look and ignores their neighbors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try testRoot(&tmp, &buffer);
    var cache = try tmp.dir.createDirPathOpen(std.testing.io, ".cache/rice", .{});
    cache.close(std.testing.io);

    var files = ConfigFiles.open(std.testing.io, std.testing.allocator, .{
        .home = root,
        .wake = testWake,
    });
    defer files.deinit();
    files.watch();
    try std.testing.expect(files.watcher != null);
    try std.testing.expect(!files.takeChanged());

    // The desktop rewrites its palette: one notification, and the loop is woken.
    try writeTestFile(&tmp, ".cache/rice/palette.json", "{\"accent\":\"#ffffff\"}");
    try std.testing.expect(changedSoon(&files));
    try std.testing.expect(test_wake_count.load(.acquire) > 0);

    try writeTestFile(&tmp, ".config/lectern/config.ini", "[general]\ntheme = nord\n");
    try std.testing.expect(changedSoon(&files));
    try writeTestFile(&tmp, ".config/lectern/themes/midnight.ini", "[theme]\n");
    try std.testing.expect(changedSoon(&files));

    // Other files of the same folders are nobody's business. The palette
    // written afterwards proves the watcher saw and skipped them.
    try writeTestFile(&tmp, ".cache/rice/updates.json", "{}");
    try writeTestFile(&tmp, ".config/lectern/notes.txt", "x");
    try writeTestFile(&tmp, ".config/lectern/themes/readme.md", "x");
    pause(30);
    try std.testing.expect(!files.takeChanged());
    try writeTestFile(&tmp, ".cache/rice/palette.json", "{}");
    try std.testing.expect(changedSoon(&files));
}

test "events are matched by folder and name" {
    const watcher = ConfigFiles.Watcher{
        .inotify = -1,
        .stop = -1,
        .directory_watch = 1,
        .themes_watch = 2,
        .palette_watch = 3,
    };
    const Event = struct {
        fn make(buffer: *[64]u8, source: i32, mask: u32, name: []const u8) []const u8 {
            @memset(buffer, 0);
            const name_length: u32 = 32;
            @memcpy(buffer[0..4], std.mem.asBytes(&source));
            @memcpy(buffer[4..8], std.mem.asBytes(&mask));
            @memcpy(buffer[12..16], std.mem.asBytes(&name_length));
            @memcpy(buffer[16 .. 16 + name.len], name);
            return buffer[0 .. event_header_size + name_length];
        }
    };
    var buffer: [64]u8 = undefined;
    const concerns = ConfigFiles.concerns;
    try std.testing.expect(concerns(watcher, Event.make(&buffer, 1, in_close_write, config_name)));
    try std.testing.expect(!concerns(watcher, Event.make(&buffer, 1, in_close_write, "other")));
    try std.testing.expect(concerns(watcher, Event.make(&buffer, 2, in_moved_to, "a.ini")));
    try std.testing.expect(!concerns(watcher, Event.make(&buffer, 2, in_moved_to, "a.ini~")));
    try std.testing.expect(concerns(watcher, Event.make(&buffer, 3, in_moved_to, palette_name)));
    try std.testing.expect(!concerns(watcher, Event.make(&buffer, 3, in_moved_to, config_name)));
    // The palette name in the configuration folder is not the palette.
    try std.testing.expect(!concerns(watcher, Event.make(&buffer, 1, in_delete, palette_name)));
    try std.testing.expect(concerns(watcher, Event.make(&buffer, -1, in_queue_overflow, "")));
    try std.testing.expect(!concerns(watcher, buffer[0..8]));
    try std.testing.expect(!concerns(watcher, &.{}));
}
