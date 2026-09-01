//! Lazily rendered page thumbnails with a per-frame render budget and a
//! bounded least-recently-used texture set.
//!
//! Rendering a thumbnail means rasterizing a PDF page, which can take longer
//! than a frame. The budget keeps scrolling responsive: pages that did not fit
//! are reported as pending so the application schedules another frame.

const std = @import("std");
const densityKey = @import("text_cache.zig").densityKey;

pub const capacity = 48;
pub const renders_per_frame = 2;
pub const render_scale: f32 = 0.24;

pub fn Thumbnails(comptime backend: type) type {
    return struct {
        const Self = @This();

        const Slot = struct {
            texture: ?backend.Texture = null,
            failed: bool = false,
            last_used: u64 = 0,
        };

        pub const Lookup = struct {
            texture: ?backend.Texture = null,
            pending: bool = false,
        };

        allocator: std.mem.Allocator,
        slots: []Slot = &.{},
        identity: ?u64 = null,
        tick: u64 = 0,
        live_count: usize = 0,
        budget: u32 = 0,
        render_count: usize = 0,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.clear();
            self.* = .{ .allocator = self.allocator };
        }

        pub fn clear(self: *Self) void {
            for (self.slots) |*slot| {
                if (slot.texture) |*texture| texture.deinit();
            }
            self.allocator.free(self.slots);
            self.slots = &.{};
            self.identity = null;
            self.live_count = 0;
        }

        /// Prepares the cache for a frame. Opening another document, changing
        /// the theme, or changing the display density invalidates everything.
        pub fn beginFrame(
            self: *Self,
            document: backend.Document,
            page_count: usize,
            dark_mode: bool,
            density: f32,
        ) !void {
            self.budget = renders_per_frame;
            const identity = identityOf(document.identity(), dark_mode, density);
            if (self.identity == identity and self.slots.len == page_count) return;

            self.clear();
            self.slots = try self.allocator.alloc(Slot, page_count);
            for (self.slots) |*slot| slot.* = .{};
            self.identity = identity;
        }

        pub fn get(
            self: *Self,
            context: backend.Context,
            document: backend.Document,
            page_index: usize,
            dark_mode: bool,
            density: f32,
        ) Lookup {
            if (page_index >= self.slots.len) return .{};
            const slot = &self.slots[page_index];
            if (slot.texture) |texture| {
                slot.last_used = self.nextTick();
                return .{ .texture = texture };
            }
            if (slot.failed) return .{};
            if (self.budget == 0) return .{ .pending = true };

            self.budget -= 1;
            self.render_count += 1;
            const texture = document.render(
                context,
                page_index,
                render_scale * density,
                dark_mode,
            ) catch {
                slot.failed = true;
                return .{};
            };
            if (self.live_count >= capacity) self.evict();
            slot.texture = texture;
            slot.last_used = self.nextTick();
            self.live_count += 1;
            return .{ .texture = texture };
        }

        pub fn liveCount(self: Self) usize {
            return self.live_count;
        }

        fn evict(self: *Self) void {
            var oldest: ?*Slot = null;
            for (self.slots) |*slot| {
                if (slot.texture == null) continue;
                if (oldest == null or slot.last_used < oldest.?.last_used) oldest = slot;
            }
            const victim = oldest orelse return;
            victim.texture.?.deinit();
            victim.texture = null;
            self.live_count -= 1;
        }

        fn nextTick(self: *Self) u64 {
            self.tick += 1;
            return self.tick;
        }

        fn identityOf(document_identity: u64, dark_mode: bool, density: f32) u64 {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(std.mem.asBytes(&document_identity));
            hasher.update(std.mem.asBytes(&dark_mode));
            hasher.update(std.mem.asBytes(&densityKey(density)));
            return hasher.final();
        }
    };
}

const mock = @import("../testing/mock_backend.zig");

test "thumbnails render within a per-frame budget and report pending pages" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    state.page_count = 10;
    const context = mock.Backend.Context{ .state = &state };
    var document = try mock.Backend.Document.open(context, std.testing.allocator, "book.pdf");
    defer document.deinit();
    var cache = Thumbnails(mock.Backend).init(std.testing.allocator);
    defer cache.deinit();

    try cache.beginFrame(document, 10, false, 1.0);
    try std.testing.expect(cache.get(context, document, 0, false, 1.0).texture != null);
    try std.testing.expect(cache.get(context, document, 1, false, 1.0).texture != null);
    const third = cache.get(context, document, 2, false, 1.0);
    try std.testing.expect(third.pending);
    try std.testing.expectEqual(@as(?mock.Backend.Texture, null), third.texture);
    try std.testing.expectEqual(@as(usize, 2), cache.render_count);
    try std.testing.expectApproxEqAbs(render_scale, state.last_render_scale, 0.0001);

    try cache.beginFrame(document, 10, false, 1.0);
    try std.testing.expect(cache.get(context, document, 0, false, 1.0).texture != null);
    try std.testing.expect(cache.get(context, document, 2, false, 1.0).texture != null);
    try std.testing.expectEqual(@as(usize, 3), cache.render_count);
    try std.testing.expectEqual(@as(usize, 0), state.texture_deinit_count);
    try std.testing.expect(!cache.get(context, document, 99, false, 1.0).pending);
}

test "theme, density, and document changes invalidate thumbnails" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    const context = mock.Backend.Context{ .state = &state };
    var document = try mock.Backend.Document.open(context, std.testing.allocator, "book.pdf");
    defer document.deinit();
    var cache = Thumbnails(mock.Backend).init(std.testing.allocator);
    defer cache.deinit();

    try cache.beginFrame(document, 3, false, 1.0);
    _ = cache.get(context, document, 0, false, 1.0);
    try cache.beginFrame(document, 3, true, 1.0);
    try std.testing.expectEqual(@as(usize, 1), state.texture_deinit_count);
    _ = cache.get(context, document, 0, true, 1.0);
    try cache.beginFrame(document, 3, true, 2.0);
    try std.testing.expectEqual(@as(usize, 2), state.texture_deinit_count);

    var other = try mock.Backend.Document.open(context, std.testing.allocator, "other.pdf");
    defer other.deinit();
    _ = cache.get(context, document, 0, true, 2.0);
    try cache.beginFrame(other, 3, true, 2.0);
    try std.testing.expectEqual(@as(usize, 3), state.texture_deinit_count);
    try std.testing.expectEqual(@as(usize, 0), cache.liveCount());
}

test "thumbnail storage is bounded and failures are not retried" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    state.page_count = capacity + 10;
    const context = mock.Backend.Context{ .state = &state };
    var document = try mock.Backend.Document.open(context, std.testing.allocator, "long.pdf");
    defer document.deinit();
    var cache = Thumbnails(mock.Backend).init(std.testing.allocator);
    defer cache.deinit();

    var page_index: usize = 0;
    while (page_index < capacity + 10) : (page_index += 1) {
        try cache.beginFrame(document, capacity + 10, false, 1.0);
        const lookup = cache.get(context, document, page_index, false, 1.0);
        try std.testing.expect(lookup.texture != null);
    }
    try std.testing.expectEqual(@as(usize, capacity), cache.liveCount());
    try std.testing.expectEqual(@as(usize, 10), state.texture_deinit_count);

    state.fail_render = true;
    try cache.beginFrame(document, capacity + 10, false, 1.0);
    try std.testing.expectEqual(@as(?mock.Backend.Texture, null), cache.get(
        context,
        document,
        0,
        false,
        1.0,
    ).texture);
    const renders = cache.render_count;
    try std.testing.expect(!cache.get(context, document, 0, false, 1.0).pending);
    try std.testing.expectEqual(renders, cache.render_count);
}
