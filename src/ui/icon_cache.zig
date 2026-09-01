//! Least-recently-used cache of vector icons rasterized per color and density.

const std = @import("std");
const theme = @import("theme.zig");
const densityKey = @import("text_cache.zig").densityKey;

pub const capacity = 64;

pub fn IconCache(comptime backend: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            texture: ?backend.Texture = null,
            icon: theme.Icon = .open,
            color: theme.Rgba = theme.white,
            density_key: u32 = 0,
            last_used: u64 = 0,
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

        pub fn get(
            self: *Self,
            context: backend.Context,
            icon: theme.Icon,
            color: theme.Rgba,
            density: f32,
        ) ?backend.Texture {
            const key = densityKey(density);
            var victim: *Entry = &self.entries[0];
            for (&self.entries) |*entry| {
                if (entry.texture != null and entry.icon == icon and
                    entry.density_key == key and std.meta.eql(entry.color, color))
                {
                    entry.last_used = self.nextTick();
                    return entry.texture;
                }
                if (entry.texture == null) {
                    if (victim.texture != null) victim = entry;
                } else if (victim.texture != null and entry.last_used < victim.last_used) {
                    victim = entry;
                }
            }

            const texture = context.createIcon(icon, color) orelse return null;
            self.create_count += 1;
            if (victim.texture) |*old| old.deinit();
            victim.* = .{
                .texture = texture,
                .icon = icon,
                .color = color,
                .density_key = key,
                .last_used = self.nextTick(),
            };
            return texture;
        }

        fn nextTick(self: *Self) u64 {
            self.tick += 1;
            return self.tick;
        }
    };
}

const mock = @import("../testing/mock_backend.zig");

test "icons are cached per icon, color, and density" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    const context = mock.Backend.Context{ .state = &state };
    var cache = IconCache(mock.Backend){};
    defer cache.deinit();

    const accent = theme.Palette.forMode(true).accent;
    _ = cache.get(context, .pen, accent, 1.0).?;
    _ = cache.get(context, .pen, accent, 1.0).?;
    try std.testing.expectEqual(@as(usize, 1), cache.create_count);
    _ = cache.get(context, .pen, theme.white, 1.0).?;
    _ = cache.get(context, .pen, accent, 2.0).?;
    _ = cache.get(context, .eraser, accent, 1.0).?;
    try std.testing.expectEqual(@as(usize, 4), cache.create_count);
}

test "the least recently used icon is evicted when the cache is full" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    const context = mock.Backend.Context{ .state = &state };
    var cache = IconCache(mock.Backend){};
    defer cache.deinit();

    const first = theme.rgb(0, 0, 0);
    const second = theme.rgb(1, 0, 0);
    _ = cache.get(context, .pen, first, 1.0).?;
    var shade: u8 = 1;
    while (shade < capacity) : (shade += 1) {
        _ = cache.get(context, .pen, theme.rgb(shade, 0, 0), 1.0).?;
    }
    try std.testing.expectEqual(@as(usize, capacity), cache.create_count);
    try std.testing.expectEqual(@as(usize, 0), state.texture_deinit_count);

    // Using the first icon again makes the second one the oldest.
    _ = cache.get(context, .pen, first, 1.0).?;
    _ = cache.get(context, .eraser, first, 1.0).?;
    try std.testing.expectEqual(@as(usize, capacity + 1), cache.create_count);
    try std.testing.expectEqual(@as(usize, 1), state.texture_deinit_count);
    _ = cache.get(context, .pen, first, 1.0).?;
    try std.testing.expectEqual(@as(usize, capacity + 1), cache.create_count);
    _ = cache.get(context, .pen, second, 1.0).?;
    try std.testing.expectEqual(@as(usize, capacity + 2), cache.create_count);
    try std.testing.expectEqual(@as(usize, 2), state.texture_deinit_count);
}
