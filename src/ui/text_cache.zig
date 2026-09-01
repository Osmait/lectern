//! Least-recently-used cache of rasterized text.
//!
//! Text is rasterized white and tinted when drawn, so the cache key ignores
//! color and a label keeps one texture no matter how many states show it.
//! Entries are found by a hash of the text, size, weight, and density; the
//! bytes are compared only when the hashes agree.

const std = @import("std");

pub const maximum_text_length = 95;
pub const capacity = 64;

pub fn densityKey(density: f32) u32 {
    return @intFromFloat(density * 1000 + 0.5);
}

pub fn TextCache(comptime backend: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            texture: ?backend.Texture = null,
            hash: u64 = 0,
            text: [maximum_text_length]u8 = undefined,
            length: u8 = 0,
            size: u8 = 0,
            strong: bool = false,
            density_key: u32 = 0,
            width: f32 = 0,
            height: f32 = 0,
            last_used: u64 = 0,

            fn matches(
                self: Entry,
                hash: u64,
                text: []const u8,
                size: u8,
                strong: bool,
                key: u32,
            ) bool {
                return self.hash == hash and self.size == size and self.strong == strong and
                    self.density_key == key and
                    std.mem.eql(u8, self.text[0..self.length], text);
            }
        };

        entries: [capacity]Entry = [_]Entry{.{}} ** capacity,
        tick: u64 = 0,
        create_count: usize = 0,

        pub fn deinit(self: *Self) void {
            for (&self.entries) |*entry| {
                if (entry.texture) |*texture| texture.deinit();
                entry.* = .{};
            }
        }

        /// Returns the cached rasterization, creating it when missing. Texts
        /// longer than the key size are clipped so cache and drawing agree.
        pub fn get(
            self: *Self,
            context: backend.Context,
            text: []const u8,
            size: u8,
            strong: bool,
            density: f32,
        ) ?*const Entry {
            const key = densityKey(density);
            const clipped = text[0..@min(text.len, maximum_text_length)];
            const hash = entryHash(clipped, size, strong, key);
            var victim: *Entry = &self.entries[0];
            for (&self.entries) |*entry| {
                if (entry.texture != null and entry.matches(hash, clipped, size, strong, key)) {
                    entry.last_used = self.nextTick();
                    return entry;
                }
                if (entry.texture == null) {
                    if (victim.texture != null) victim = entry;
                } else if (victim.texture != null and entry.last_used < victim.last_used) {
                    victim = entry;
                }
            }

            var buffer: [maximum_text_length + 1]u8 = undefined;
            @memcpy(buffer[0..clipped.len], clipped);
            buffer[clipped.len] = 0;
            const image = context.createText(buffer[0..clipped.len :0], size, strong) orelse {
                return null;
            };
            self.create_count += 1;
            if (victim.texture) |*texture| texture.deinit();
            victim.* = .{
                .texture = image.texture,
                .hash = hash,
                .length = @intCast(clipped.len),
                .size = size,
                .strong = strong,
                .density_key = key,
                .width = image.width,
                .height = image.height,
                .last_used = self.nextTick(),
            };
            @memcpy(victim.text[0..clipped.len], clipped);
            return victim;
        }

        fn nextTick(self: *Self) u64 {
            self.tick += 1;
            return self.tick;
        }
    };
}

fn entryHash(text: []const u8, size: u8, strong: bool, density_key: u32) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(text);
    hasher.update(&[_]u8{ size, @intFromBool(strong) });
    hasher.update(std.mem.asBytes(&density_key));
    return hasher.final();
}

const mock = @import("../testing/mock_backend.zig");

test "text textures are shared across colors and evicted least recently used" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    const context = mock.Backend.Context{ .state = &state };
    var cache = TextCache(mock.Backend){};
    defer cache.deinit();

    const first = cache.get(context, "Pen", 16, true, 1.0).?;
    try std.testing.expect(first.width > 0);
    _ = cache.get(context, "Pen", 16, true, 1.0).?;
    try std.testing.expectEqual(@as(usize, 1), cache.create_count);
    _ = cache.get(context, "Pen", 16, false, 1.0).?;
    _ = cache.get(context, "Pen", 16, true, 2.0).?;
    try std.testing.expectEqual(@as(usize, 3), cache.create_count);

    var label_buffer: [8]u8 = undefined;
    var index: usize = 0;
    while (index < capacity) : (index += 1) {
        const label = try std.fmt.bufPrint(&label_buffer, "{d}", .{index});
        _ = cache.get(context, label, 13, false, 1.0).?;
    }
    try std.testing.expectEqual(@as(usize, 3 + capacity), cache.create_count);
    try std.testing.expectEqual(@as(usize, 3), state.texture_deinit_count);
    _ = cache.get(context, "0", 13, false, 1.0).?;
    try std.testing.expectEqual(@as(usize, 3 + capacity), cache.create_count);
}

test "text creation failures are reported without caching" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    state.fail_text = true;
    const context = mock.Backend.Context{ .state = &state };
    var cache = TextCache(mock.Backend){};
    defer cache.deinit();
    try std.testing.expectEqual(@as(?*const TextCache(mock.Backend).Entry, null), cache.get(
        context,
        "Pen",
        16,
        true,
        1.0,
    ));
    try std.testing.expectEqual(@as(usize, 0), cache.create_count);
}

test "texts longer than the key are clipped so the cache and the drawing agree" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    const context = mock.Backend.Context{ .state = &state };
    var cache = TextCache(mock.Backend){};
    defer cache.deinit();

    const long = "x" ** 120;
    const entry = cache.get(context, long, 13, false, 1.0).?;
    try std.testing.expectEqual(@as(u8, maximum_text_length), entry.length);
    try std.testing.expectEqual(@as(usize, 1), state.labels.items.len);
    const created = state.labels.items[0].textSlice();
    try std.testing.expectEqual(@as(usize, maximum_text_length), created.len);

    // A different text with the same first bytes shares the entry.
    const same_prefix = "x" ** maximum_text_length ++ "y" ** 25;
    _ = cache.get(context, same_prefix, 13, false, 1.0).?;
    try std.testing.expectEqual(@as(usize, 1), cache.create_count);
    _ = cache.get(context, "x" ** (maximum_text_length - 1), 13, false, 1.0).?;
    try std.testing.expectEqual(@as(usize, 2), cache.create_count);
}

test "entry hashes separate text, size, weight, and density" {
    const base = entryHash("Pen", 16, true, 1000);
    try std.testing.expectEqual(base, entryHash("Pen", 16, true, 1000));
    try std.testing.expect(base != entryHash("Pe", 16, true, 1000));
    try std.testing.expect(base != entryHash("Pen", 15, true, 1000));
    try std.testing.expect(base != entryHash("Pen", 16, false, 1000));
    try std.testing.expect(base != entryHash("Pen", 16, true, 2000));
}

test "density keys round to thousandths" {
    try std.testing.expectEqual(@as(u32, 1000), densityKey(1.0));
    try std.testing.expectEqual(@as(u32, 1500), densityKey(1.5));
    try std.testing.expectEqual(@as(u32, 2000), densityKey(2.0));
    try std.testing.expectEqual(@as(u32, 1000), densityKey(1.0004));
    try std.testing.expectEqual(@as(u32, 1001), densityKey(1.0006));
}
