//! Rendered pages kept ready so navigation is instant: the neighbors of the
//! current page, rendered ahead of time, and the page the reader just left.
//!
//! Entries are keyed by page, scale, and theme. The cache is small because a
//! page texture at full display size can take tens of megabytes.

const std = @import("std");

pub const capacity = 3;
/// Scales within this ratio of each other produce the same pixels on screen.
pub const scale_tolerance: f32 = 0.01;

pub fn scalesMatch(left: f32, right: f32) bool {
    if (left <= 0 or right <= 0) return false;
    return @abs(left / right - 1) <= scale_tolerance;
}

pub fn PageCache(comptime Texture: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            page_index: usize,
            scale: f32,
            dark_mode: bool,
            texture: Texture,
            last_used: u64,
        };

        entries: [capacity]?Entry = [_]?Entry{null} ** capacity,
        tick: u64 = 0,

        pub fn deinit(self: *Self) void {
            self.clear();
        }

        pub fn clear(self: *Self) void {
            for (&self.entries) |*slot| {
                if (slot.*) |*entry| entry.texture.deinit();
                slot.* = null;
            }
        }

        pub fn count(self: Self) usize {
            var total: usize = 0;
            for (self.entries) |slot| {
                if (slot != null) total += 1;
            }
            return total;
        }

        pub fn contains(self: Self, page_index: usize, scale: f32, dark_mode: bool) bool {
            return self.find(page_index, scale, dark_mode) != null;
        }

        /// Removes and returns the matching texture; the caller owns it.
        pub fn take(self: *Self, page_index: usize, scale: f32, dark_mode: bool) ?Texture {
            const index = self.find(page_index, scale, dark_mode) orelse return null;
            const entry = self.entries[index].?;
            self.entries[index] = null;
            return entry.texture;
        }

        /// Stores a texture, replacing any entry for the same page and
        /// evicting the least recently used one when full.
        pub fn put(
            self: *Self,
            page_index: usize,
            scale: f32,
            dark_mode: bool,
            texture: Texture,
        ) void {
            var target: ?usize = null;
            for (&self.entries, 0..) |*slot, index| {
                const entry = slot.* orelse {
                    if (target == null) target = index;
                    continue;
                };
                if (entry.page_index == page_index) {
                    var old = entry.texture;
                    old.deinit();
                    slot.* = null;
                    target = index;
                }
            }
            if (target == null) {
                target = self.leastRecentlyUsed();
                if (self.entries[target.?]) |*entry| entry.texture.deinit();
            }
            self.tick += 1;
            self.entries[target.?] = .{
                .page_index = page_index,
                .scale = scale,
                .dark_mode = dark_mode,
                .texture = texture,
                .last_used = self.tick,
            };
        }

        fn find(self: Self, page_index: usize, scale: f32, dark_mode: bool) ?usize {
            for (self.entries, 0..) |slot, index| {
                const entry = slot orelse continue;
                if (entry.page_index == page_index and entry.dark_mode == dark_mode and
                    scalesMatch(entry.scale, scale))
                {
                    return index;
                }
            }
            return null;
        }

        fn leastRecentlyUsed(self: Self) usize {
            var oldest: usize = 0;
            for (self.entries, 0..) |slot, index| {
                const entry = slot orelse return index;
                if (entry.last_used < self.entries[oldest].?.last_used) oldest = index;
            }
            return oldest;
        }
    };
}

const mock = @import("testing/mock_backend.zig");

fn testTexture(state: *mock.State) mock.Backend.Texture {
    state.texture_create_count += 1;
    return .{ .state = state, .width = 10, .height = 10 };
}

test "pages are found by page, scale within tolerance, and theme" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    var cache = PageCache(mock.Backend.Texture){};
    defer cache.deinit();

    cache.put(4, 2.0, false, testTexture(&state));
    try std.testing.expect(cache.contains(4, 2.0, false));
    try std.testing.expect(cache.contains(4, 2.015, false));
    try std.testing.expect(!cache.contains(4, 2.1, false));
    try std.testing.expect(!cache.contains(4, 2.0, true));
    try std.testing.expect(!cache.contains(5, 2.0, false));
    try std.testing.expectEqual(@as(?mock.Backend.Texture, null), cache.take(5, 2.0, false));
    try std.testing.expect(cache.take(4, 2.0, false) != null);
    try std.testing.expectEqual(@as(usize, 0), cache.count());
    try std.testing.expectEqual(@as(usize, 0), state.texture_deinit_count);
    try std.testing.expect(!scalesMatch(0, 1));
}

test "the cache is bounded, evicts the least recently used page, and dedupes pages" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    var cache = PageCache(mock.Backend.Texture){};
    defer cache.deinit();

    cache.put(1, 1.0, false, testTexture(&state));
    cache.put(2, 1.0, false, testTexture(&state));
    cache.put(3, 1.0, false, testTexture(&state));
    try std.testing.expectEqual(capacity, cache.count());
    cache.put(4, 1.0, false, testTexture(&state));
    try std.testing.expectEqual(capacity, cache.count());
    try std.testing.expect(!cache.contains(1, 1.0, false));
    try std.testing.expectEqual(@as(usize, 1), state.texture_deinit_count);

    // Replacing a page keeps one entry for it and releases the old texture.
    cache.put(2, 1.5, false, testTexture(&state));
    try std.testing.expectEqual(capacity, cache.count());
    try std.testing.expect(cache.contains(2, 1.5, false));
    try std.testing.expect(!cache.contains(2, 1.0, false));
    try std.testing.expectEqual(@as(usize, 2), state.texture_deinit_count);

    cache.clear();
    try std.testing.expectEqual(@as(usize, 0), cache.count());
    try std.testing.expectEqual(@as(usize, 5), state.texture_deinit_count);
}
