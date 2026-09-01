//! Page thumbnails rendered in the background and kept in a bounded
//! least-recently-used texture set.
//!
//! The renderer only reads this cache. The application asks it to request
//! the pages that are visible and hands finished renders back, so scrolling
//! the rail never waits for Poppler.

const std = @import("std");
const densityKey = @import("text_cache.zig").densityKey;
const rendering = @import("../rendering.zig");
const VisibleThumbnails = @import("layout.zig").VisibleThumbnails;

pub const capacity = 48;
pub const render_scale: f32 = 0.24;

pub fn Thumbnails(comptime backend: type) type {
    return struct {
        const Self = @This();

        const Slot = struct {
            texture: ?backend.Texture = null,
            /// Id of the render request in flight for this page.
            job: ?u64 = null,
            failed: bool = false,
            last_used: u64 = 0,
        };

        pub const Lookup = struct {
            texture: ?backend.Texture = null,
            /// True when the page has no texture and nobody asked for one.
            missing: bool = false,
        };

        allocator: std.mem.Allocator,
        slots: []Slot = &.{},
        identity: ?u64 = null,
        tick: u64 = 0,
        /// Pages that currently hold a texture; eviction scans only these.
        live: std.ArrayList(usize) = .empty,
        request_count: usize = 0,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.clear();
            self.live.deinit(self.allocator);
            self.* = .{ .allocator = self.allocator };
        }

        pub fn clear(self: *Self) void {
            for (self.slots) |*slot| {
                if (slot.texture) |*texture| texture.deinit();
            }
            self.allocator.free(self.slots);
            self.slots = &.{};
            self.identity = null;
            self.live.clearRetainingCapacity();
        }

        /// Prepares the cache for a document, theme, and density. Changing
        /// any of them drops every texture; requests still pending are
        /// cancelled and requests already running are dropped on arrival.
        pub fn prepare(
            self: *Self,
            queue: *backend.RenderQueue,
            document_identity: u64,
            page_count: usize,
            dark_mode: bool,
            density: f32,
        ) error{OutOfMemory}!void {
            const identity = identityOf(document_identity, dark_mode, density);
            if (self.identity == identity and self.slots.len == page_count) return;

            for (self.slots) |*slot| {
                const job = slot.job orelse continue;
                _ = queue.cancel(job);
                slot.job = null;
            }
            self.clear();
            self.slots = try self.allocator.alloc(Slot, page_count);
            for (self.slots) |*slot| slot.* = .{};
            try self.live.ensureTotalCapacity(self.allocator, capacity);
            self.identity = identity;
        }

        pub fn get(self: *Self, page_index: usize) Lookup {
            if (page_index >= self.slots.len) return .{};
            const slot = &self.slots[page_index];
            if (slot.texture) |texture| {
                slot.last_used = self.nextTick();
                return .{ .texture = texture };
            }
            return .{ .missing = !slot.failed and slot.job == null };
        }

        /// Requests every visible page without a texture and cancels requests
        /// for pages that scrolled out of view.
        pub fn requestVisible(
            self: *Self,
            queue: *backend.RenderQueue,
            document: backend.Document,
            generation: u64,
            visible: VisibleThumbnails,
            dark_mode: bool,
            density: f32,
        ) void {
            for (self.slots, 0..) |*slot, index| {
                const job = slot.job orelse continue;
                if (visible.contains(index)) continue;
                if (queue.cancel(job)) slot.job = null;
            }
            var index = visible.first;
            while (index < visible.end and index < self.slots.len) : (index += 1) {
                const slot = &self.slots[index];
                if (slot.texture != null or slot.failed or slot.job != null) continue;
                // Out of memory here only delays the request to the next frame.
                const id = queue.submit(.{
                    .document = document,
                    .generation = generation,
                    .page_index = index,
                    .scale = render_scale * density,
                    .dark_mode = dark_mode,
                    .purpose = .thumbnail,
                    .priority = .visible,
                }) catch continue;
                slot.job = id;
                self.request_count += 1;
            }
        }

        /// Installs a finished request. A result that no slot is waiting for
        /// belongs to an earlier configuration and is released.
        pub fn complete(
            self: *Self,
            job_id: u64,
            page_index: usize,
            texture: ?backend.Texture,
        ) void {
            var owned = texture;
            if (page_index >= self.slots.len or self.slots[page_index].job != job_id) {
                if (owned) |*stale| stale.deinit();
                return;
            }
            const slot = &self.slots[page_index];
            slot.job = null;
            const ready = owned orelse {
                slot.failed = true;
                return;
            };
            if (self.live.items.len >= capacity) self.evict();
            slot.texture = ready;
            slot.last_used = self.nextTick();
            self.live.appendAssumeCapacity(page_index);
        }

        pub fn liveCount(self: Self) usize {
            return self.live.items.len;
        }

        pub fn pendingCount(self: Self) usize {
            var total: usize = 0;
            for (self.slots) |slot| {
                if (slot.job != null) total += 1;
            }
            return total;
        }

        fn evict(self: *Self) void {
            if (self.live.items.len == 0) return;
            var oldest: usize = 0;
            for (self.live.items, 0..) |page_index, position| {
                const oldest_use = self.slots[self.live.items[oldest]].last_used;
                if (self.slots[page_index].last_used < oldest_use) oldest = position;
            }
            const victim = &self.slots[self.live.items[oldest]];
            victim.texture.?.deinit();
            victim.texture = null;
            _ = self.live.swapRemove(oldest);
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

const TestThumbnails = Thumbnails(mock.Backend);

fn deliver(state: *mock.State, queue: *mock.Backend.RenderQueue, cache: *TestThumbnails) usize {
    const context = mock.Backend.Context{ .state = state };
    var delivered: usize = 0;
    while (queue.poll(context, 1)) |result| {
        cache.complete(result.job.id, result.job.page_index, result.texture);
        delivered += 1;
    }
    return delivered;
}

test "visible pages are requested through the queue and delivered later" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    state.page_count = 10;
    state.auto_complete_renders = false;
    const context = mock.Backend.Context{ .state = &state };
    var document = try mock.Backend.Document.open(context, std.testing.allocator, "book.pdf");
    defer document.deinit();
    var queue = mock.Backend.RenderQueue{ .state = &state };
    var cache = TestThumbnails.init(std.testing.allocator);
    defer cache.deinit();

    try cache.prepare(&queue, document.identity(), 10, false, 1.0);
    try std.testing.expect(cache.get(0).missing);
    cache.requestVisible(&queue, document, 1, .{ .first = 0, .end = 3 }, false, 1.0);
    try std.testing.expectEqual(@as(usize, 3), queue.pendingCount());
    try std.testing.expectEqual(@as(usize, 3), cache.pendingCount());
    // A page with a request in flight is neither missing nor ready.
    try std.testing.expect(!cache.get(0).missing);
    try std.testing.expectEqual(@as(?mock.Backend.Texture, null), cache.get(0).texture);
    cache.requestVisible(&queue, document, 1, .{ .first = 0, .end = 3 }, false, 1.0);
    try std.testing.expectEqual(@as(usize, 3), queue.pendingCount());

    try std.testing.expect(state.completeRender());
    try std.testing.expectEqual(@as(usize, 1), deliver(&state, &queue, &cache));
    try std.testing.expect(cache.get(0).texture != null);
    try std.testing.expectApproxEqAbs(render_scale, state.last_render_scale, 0.0001);
    try std.testing.expectEqual(@as(usize, 1), cache.liveCount());

    // Scrolling away cancels what is still pending and requests the new pages.
    cache.requestVisible(&queue, document, 1, .{ .first = 5, .end = 7 }, false, 1.0);
    try std.testing.expectEqual(@as(usize, 2), state.cancelled_job_count);
    try std.testing.expectEqual(@as(usize, 2), queue.pendingCount());
    try std.testing.expect(cache.get(1).missing);
    try std.testing.expect(!cache.get(99).missing);
    state.completeAllRenders();
    try std.testing.expectEqual(@as(usize, 2), deliver(&state, &queue, &cache));
    try std.testing.expectEqual(@as(usize, 3), cache.liveCount());
}

test "theme, density, and document changes invalidate thumbnails and drop late results" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    state.auto_complete_renders = false;
    const context = mock.Backend.Context{ .state = &state };
    var document = try mock.Backend.Document.open(context, std.testing.allocator, "book.pdf");
    defer document.deinit();
    var queue = mock.Backend.RenderQueue{ .state = &state };
    var cache = TestThumbnails.init(std.testing.allocator);
    defer cache.deinit();

    try cache.prepare(&queue, document.identity(), 3, false, 1.0);
    cache.requestVisible(&queue, document, 1, .{ .first = 0, .end = 3 }, false, 1.0);
    state.completeAllRenders();
    _ = deliver(&state, &queue, &cache);
    try std.testing.expectEqual(@as(usize, 3), cache.liveCount());

    try cache.prepare(&queue, document.identity(), 3, true, 1.0);
    try std.testing.expectEqual(@as(usize, 3), state.texture_deinit_count);
    try std.testing.expectEqual(@as(usize, 0), cache.liveCount());
    cache.requestVisible(&queue, document, 1, .{ .first = 0, .end = 1 }, true, 1.0);
    // The result of a request made before the density changed is released
    // instead of being shown at the wrong size.
    state.completeAllRenders();
    try cache.prepare(&queue, document.identity(), 3, true, 2.0);
    try std.testing.expectEqual(@as(usize, 0), deliver(&state, &queue, &cache) - 1);
    try std.testing.expectEqual(@as(usize, 4), state.texture_deinit_count);
    try std.testing.expectEqual(@as(usize, 0), cache.liveCount());

    // A pending request of the old configuration is cancelled, not rendered.
    cache.requestVisible(&queue, document, 1, .{ .first = 0, .end = 1 }, true, 2.0);
    var other = try mock.Backend.Document.open(context, std.testing.allocator, "other.pdf");
    defer other.deinit();
    try cache.prepare(&queue, other.identity(), 3, true, 2.0);
    try std.testing.expectEqual(@as(usize, 1), state.cancelled_job_count);
    try std.testing.expectEqual(@as(usize, 0), queue.pendingCount());
}

test "thumbnail storage is bounded and failures are not retried" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    state.page_count = capacity + 10;
    const context = mock.Backend.Context{ .state = &state };
    var document = try mock.Backend.Document.open(context, std.testing.allocator, "long.pdf");
    defer document.deinit();
    var queue = mock.Backend.RenderQueue{ .state = &state };
    var cache = TestThumbnails.init(std.testing.allocator);
    defer cache.deinit();

    try cache.prepare(&queue, document.identity(), capacity + 10, false, 1.0);
    var page_index: usize = 0;
    while (page_index < capacity + 10) : (page_index += 1) {
        cache.requestVisible(&queue, document, 1, .{
            .first = page_index,
            .end = page_index + 1,
        }, false, 1.0);
        _ = deliver(&state, &queue, &cache);
        try std.testing.expect(cache.get(page_index).texture != null);
    }
    try std.testing.expectEqual(@as(usize, capacity), cache.liveCount());
    try std.testing.expectEqual(@as(usize, 10), state.texture_deinit_count);
    try std.testing.expect(cache.get(0).missing);

    state.fail_render = true;
    cache.requestVisible(&queue, document, 1, .{ .first = 0, .end = 1 }, false, 1.0);
    _ = deliver(&state, &queue, &cache);
    try std.testing.expectEqual(@as(?mock.Backend.Texture, null), cache.get(0).texture);
    try std.testing.expect(!cache.get(0).missing);
    const requests = cache.request_count;
    cache.requestVisible(&queue, document, 1, .{ .first = 0, .end = 1 }, false, 1.0);
    try std.testing.expectEqual(requests, cache.request_count);
}

test "the least recently viewed thumbnail is evicted first" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    state.page_count = capacity + 2;
    const context = mock.Backend.Context{ .state = &state };
    var document = try mock.Backend.Document.open(context, std.testing.allocator, "long.pdf");
    defer document.deinit();
    var queue = mock.Backend.RenderQueue{ .state = &state };
    var cache = TestThumbnails.init(std.testing.allocator);
    defer cache.deinit();

    try cache.prepare(&queue, document.identity(), capacity + 2, false, 1.0);
    var page_index: usize = 0;
    while (page_index < capacity) : (page_index += 1) {
        cache.requestVisible(&queue, document, 1, .{
            .first = page_index,
            .end = page_index + 1,
        }, false, 1.0);
        _ = deliver(&state, &queue, &cache);
    }
    try std.testing.expectEqual(@as(usize, capacity), cache.liveCount());

    // Looking at the first page again keeps it; the second page, untouched
    // since it arrived, goes first.
    try std.testing.expect(cache.get(0).texture != null);
    cache.requestVisible(&queue, document, 1, .{
        .first = capacity,
        .end = capacity + 1,
    }, false, 1.0);
    _ = deliver(&state, &queue, &cache);
    try std.testing.expectEqual(@as(usize, capacity), cache.liveCount());
    try std.testing.expectEqual(@as(usize, 1), state.texture_deinit_count);
    try std.testing.expect(cache.get(1).missing);
    try std.testing.expect(cache.get(0).texture != null);
    try std.testing.expect(cache.get(capacity).texture != null);
    try std.testing.expect(cache.get(2).texture != null);
}
