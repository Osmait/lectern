//! In-memory backend for application and interface tests.
//!
//! Every native concept has a counting stand-in: textures, documents, input,
//! the clock, the render queue, and storage. Tests inject failures through
//! `State` flags. Render jobs complete as soon as they are submitted unless a
//! test turns `auto_complete_renders` off and pumps them by hand.
//!
//! Drawing is recorded, not only counted: every filled or stroked rectangle,
//! every texture draw with its destination and tint, every clip, and every
//! triangle batch of the current frame can be inspected, and textures
//! remember the text or icon they were created from.

const std = @import("std");
const ui = @import("../ui.zig");
const rendering = @import("../rendering.zig");
const storage_module = @import("../storage.zig");
const input = ui.input;
const layout = ui.layout;
const theme = ui.theme;
const frame_module = ui.frame;

pub const DrawnRect = struct {
    rect: layout.Rect,
    color: theme.Rgba,
};

pub const DrawnTexture = struct {
    serial: u64,
    rect: layout.Rect,
    tint: theme.Rgba,
};

pub const TriangleBatch = struct {
    triangle_count: usize,
    first_color: theme.FColor,
};

pub const TextureKind = enum { text, icon, page };

pub const PrefixedText = struct {
    draw: DrawnTexture,
    text: []const u8,
};

pub const TextureLabel = struct {
    pub const text_capacity = 96;

    serial: u64,
    kind: TextureKind,
    text: [text_capacity]u8 = undefined,
    text_length: u8 = 0,
    icon: theme.Icon = .open,
    color: theme.Rgba = theme.white,
    size: u8 = 0,
    strong: bool = false,

    pub fn textSlice(self: *const TextureLabel) []const u8 {
        return self.text[0..self.text_length];
    }
};

pub const State = struct {
    allocator: std.mem.Allocator,
    page_count: usize = 3,
    page_size: layout.Size = .{ .width = 612, .height = 792 },
    fail_open: bool = false,
    fail_render: bool = false,
    fail_text: bool = false,
    fail_write: bool = false,
    storage_available: bool = true,
    /// When set, queued input is only delivered by `waitInput`, which models
    /// a quiet window where events arrive while the loop sleeps.
    inputs_arrive_while_waiting: bool = false,
    /// When set, submitted render jobs finish immediately; otherwise tests
    /// complete them with `completeRender`.
    auto_complete_renders: bool = true,
    error_message: [:0]const u8 = "mock failure",

    document_open_count: usize = 0,
    document_deinit_count: usize = 0,
    texture_create_count: usize = 0,
    texture_deinit_count: usize = 0,
    render_count: usize = 0,
    last_render_page: usize = 0,
    last_render_dark_mode: bool = false,
    last_render_scale: f32 = 0,
    text_create_count: usize = 0,
    icon_create_count: usize = 0,
    measure_count: usize = 0,
    frame_count: usize = 0,
    fill_rect_count: usize = 0,
    draw_texture_count: usize = 0,
    triangle_batch_count: usize = 0,
    triangle_count: usize = 0,
    open_dialog_count: usize = 0,
    show_error_count: usize = 0,
    context_deinit_count: usize = 0,
    poll_count: usize = 0,
    wait_count: usize = 0,
    window_size_count: usize = 0,
    last_wait_timeout: ?u32 = null,
    write_count: usize = 0,
    read_count: usize = 0,
    submitted_job_count: usize = 0,
    cancelled_job_count: usize = 0,
    next_job_id: u64 = 1,

    ticks: u64 = 0,
    window: layout.Size = layout.default_window,
    density: f32 = 1,
    title: [256]u8 = undefined,
    title_length: usize = 0,
    inputs: std.ArrayList(input.RawInput) = .empty,
    input_index: usize = 0,
    files: std.StringHashMapUnmanaged([]u8) = .empty,
    render_jobs: std.ArrayList(Backend.Job) = .empty,
    render_results: std.ArrayList(Backend.RenderResult) = .empty,
    write_completions: std.ArrayList(storage_module.Completion) = .empty,

    /// Drawing record of the frame in progress; reset by `beginFrame`.
    fills: std.ArrayList(DrawnRect) = .empty,
    outlines: std.ArrayList(DrawnRect) = .empty,
    texture_draws: std.ArrayList(DrawnTexture) = .empty,
    clips: std.ArrayList(?layout.Rect) = .empty,
    batches: std.ArrayList(TriangleBatch) = .empty,
    /// What every texture was created from, for the life of the state.
    labels: std.ArrayList(TextureLabel) = .empty,
    next_texture_serial: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *State) void {
        for (self.inputs.items) |raw| {
            if (raw.path) |path| self.allocator.free(path);
        }
        self.inputs.deinit(self.allocator);
        var files = self.files.iterator();
        while (files.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.files.deinit(self.allocator);
        self.render_jobs.deinit(self.allocator);
        for (self.render_results.items) |*result| {
            if (result.texture) |*texture| texture.deinit();
        }
        self.render_results.deinit(self.allocator);
        self.write_completions.deinit(self.allocator);
        self.fills.deinit(self.allocator);
        self.outlines.deinit(self.allocator);
        self.texture_draws.deinit(self.allocator);
        self.clips.deinit(self.allocator);
        self.batches.deinit(self.allocator);
        self.labels.deinit(self.allocator);
        self.* = undefined;
    }

    fn clearFrameRecord(self: *State) void {
        self.fills.clearRetainingCapacity();
        self.outlines.clearRetainingCapacity();
        self.texture_draws.clearRetainingCapacity();
        self.clips.clearRetainingCapacity();
        self.batches.clearRetainingCapacity();
    }

    fn newTexture(self: *State, label: TextureLabel, width: u32, height: u32) Backend.Texture {
        var owned = label;
        owned.serial = self.next_texture_serial;
        self.next_texture_serial += 1;
        self.texture_create_count += 1;
        // Recording is best effort: a failed append only weakens assertions.
        self.labels.append(self.allocator, owned) catch {};
        return .{ .state = self, .serial = owned.serial, .width = width, .height = height };
    }

    fn labelOf(self: *const State, serial: u64) ?*const TextureLabel {
        for (self.labels.items) |*entry| {
            if (entry.serial == serial) return entry;
        }
        return null;
    }

    /// Whether a rectangle was filled with exactly this color this frame.
    pub fn filled(self: *const State, rect: layout.Rect, color: theme.Rgba) bool {
        for (self.fills.items) |fill| {
            if (sameRect(fill.rect, rect) and std.meta.eql(fill.color, color)) return true;
        }
        return false;
    }

    /// Whether a rectangle was outlined with exactly this color this frame.
    pub fn outlined(self: *const State, rect: layout.Rect, color: theme.Rgba) bool {
        for (self.outlines.items) |outline| {
            if (sameRect(outline.rect, rect) and std.meta.eql(outline.color, color)) return true;
        }
        return false;
    }

    /// The last draw of a text texture with these contents this frame.
    pub fn textDraw(self: *const State, text: []const u8) ?DrawnTexture {
        var found: ?DrawnTexture = null;
        for (self.texture_draws.items) |draw| {
            const entry = self.labelOf(draw.serial) orelse continue;
            if (entry.kind != .text or !std.mem.eql(u8, entry.textSlice(), text)) continue;
            found = draw;
        }
        return found;
    }

    /// The text of the last drawn text texture starting with `prefix`, with
    /// its draw; used for titles that the renderer may have shortened.
    pub fn textDrawPrefixed(self: *const State, prefix: []const u8) ?PrefixedText {
        var found: ?PrefixedText = null;
        for (self.texture_draws.items) |draw| {
            const entry = self.labelOf(draw.serial) orelse continue;
            if (entry.kind != .text or !std.mem.startsWith(u8, entry.textSlice(), prefix)) continue;
            found = .{ .draw = draw, .text = entry.textSlice() };
        }
        return found;
    }

    /// The color an icon was rasterized with when it was last drawn this
    /// frame, or null when it was not drawn.
    pub fn iconColor(self: *const State, icon: theme.Icon) ?theme.Rgba {
        var found: ?theme.Rgba = null;
        for (self.texture_draws.items) |draw| {
            const entry = self.labelOf(draw.serial) orelse continue;
            if (entry.kind == .icon and entry.icon == icon) found = entry.color;
        }
        return found;
    }

    /// The last draw of an icon this frame.
    pub fn iconDraw(self: *const State, icon: theme.Icon) ?DrawnTexture {
        var found: ?DrawnTexture = null;
        for (self.texture_draws.items) |draw| {
            const entry = self.labelOf(draw.serial) orelse continue;
            if (entry.kind == .icon and entry.icon == icon) found = draw;
        }
        return found;
    }

    /// The last draw of a page texture this frame.
    pub fn pageDraw(self: *const State) ?DrawnTexture {
        var found: ?DrawnTexture = null;
        for (self.texture_draws.items) |draw| {
            const entry = self.labelOf(draw.serial) orelse continue;
            if (entry.kind == .page) found = draw;
        }
        return found;
    }

    /// Fills whose rectangle sits entirely inside `bounds`, this frame.
    pub fn fillsInside(self: *const State, bounds: layout.Rect) usize {
        var total: usize = 0;
        for (self.fills.items) |fill| {
            if (rectInside(fill.rect, bounds)) total += 1;
        }
        return total;
    }

    pub fn pushInput(self: *State, raw: input.RawInput) !void {
        var owned = raw;
        if (raw.path) |path| owned.path = try self.allocator.dupe(u8, path);
        errdefer if (owned.path) |path| self.allocator.free(path);
        try self.inputs.append(self.allocator, owned);
    }

    pub fn putFile(self: *State, name: []const u8, data: []const u8) !void {
        const value = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(value);
        if (self.files.getEntry(name)) |entry| {
            self.allocator.free(entry.value_ptr.*);
            entry.value_ptr.* = value;
            return;
        }
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        try self.files.put(self.allocator, key, value);
    }

    pub fn getFile(self: *State, name: []const u8) ?[]const u8 {
        return self.files.get(name);
    }

    pub fn titleText(self: *const State) []const u8 {
        return self.title[0..self.title_length];
    }

    pub fn pendingRenderCount(self: *const State) usize {
        return self.render_jobs.items.len;
    }

    /// Runs the most urgent pending job to completion. Returns false when
    /// nothing was pending.
    pub fn completeRender(self: *State) bool {
        const index = rendering.nextJobIndex(Backend.Document, self.render_jobs.items) orelse {
            return false;
        };
        const job = self.render_jobs.orderedRemove(index);
        self.finishJob(job) catch {};
        return true;
    }

    pub fn completeAllRenders(self: *State) void {
        while (self.completeRender()) {}
    }

    fn finishJob(self: *State, job: Backend.Job) error{OutOfMemory}!void {
        const context = Backend.Context{ .state = self };
        const texture = job.document.render(
            context,
            job.page_index,
            job.scale,
            job.dark_mode,
        ) catch null;
        errdefer if (texture) |*created| {
            var owned = created.*;
            owned.deinit();
        };
        try self.render_results.append(self.allocator, .{ .job = job, .texture = texture });
    }

    pub fn takeInput(self: *State, allocator: std.mem.Allocator) ?input.RawInput {
        if (self.input_index >= self.inputs.items.len) return null;
        var raw = self.inputs.items[self.input_index];
        self.input_index += 1;
        if (raw.path) |path| {
            raw.path = allocator.dupe(u8, path) catch null;
        }
        return raw;
    }
};

pub fn sameRect(left: layout.Rect, right: layout.Rect) bool {
    const tolerance = 0.01;
    return @abs(left.x - right.x) <= tolerance and @abs(left.y - right.y) <= tolerance and
        @abs(left.w - right.w) <= tolerance and @abs(left.h - right.h) <= tolerance;
}

pub fn rectInside(inner: layout.Rect, outer: layout.Rect) bool {
    const tolerance = 0.01;
    return inner.x >= outer.x - tolerance and inner.y >= outer.y - tolerance and
        inner.x + inner.w <= outer.x + outer.w + tolerance and
        inner.y + inner.h <= outer.y + outer.h + tolerance;
}

pub const Backend = struct {
    pub const Texture = struct {
        state: *State,
        serial: u64 = 0,
        width: u32,
        height: u32,

        pub fn deinit(self: *Texture) void {
            self.state.texture_deinit_count += 1;
            self.* = undefined;
        }
    };

    pub const TextImage = struct {
        texture: Texture,
        width: f32,
        height: f32,
    };

    pub const Job = rendering.Job(Document);
    pub const RenderResult = rendering.Result(Document, Texture);

    pub const Context = struct {
        state: *State,

        pub fn init() !Context {
            return error.MockContextMustBeInjected;
        }

        pub fn deinit(self: *Context) void {
            self.state.context_deinit_count += 1;
            self.* = undefined;
        }

        pub fn lastError(self: Context) [:0]const u8 {
            return self.state.error_message;
        }

        pub fn pollInput(self: Context, allocator: std.mem.Allocator) ?input.RawInput {
            self.state.poll_count += 1;
            if (self.state.inputs_arrive_while_waiting) return null;
            return self.state.takeInput(allocator);
        }

        /// A null timeout waits until input arrives; the mock still advances
        /// the clock by one idle period so timers can be observed.
        pub fn waitInput(
            self: Context,
            allocator: std.mem.Allocator,
            timeout_ms: ?u32,
        ) ?input.RawInput {
            self.state.wait_count += 1;
            self.state.last_wait_timeout = timeout_ms;
            self.state.ticks += timeout_ms orelse 1000;
            return self.state.takeInput(allocator);
        }

        pub fn ticksMs(self: Context) u64 {
            return self.state.ticks;
        }

        pub fn windowSize(self: Context) layout.Size {
            self.state.window_size_count += 1;
            return self.state.window;
        }

        pub fn pixelDensity(self: Context) f32 {
            return self.state.density;
        }

        pub fn setTitle(self: Context, title: [:0]const u8) void {
            const length = @min(title.len, self.state.title.len);
            @memcpy(self.state.title[0..length], title[0..length]);
            self.state.title_length = length;
        }

        pub fn showError(self: Context, message: [:0]const u8) void {
            _ = message;
            self.state.show_error_count += 1;
        }

        pub fn openDialog(self: Context) void {
            self.state.open_dialog_count += 1;
        }

        pub fn beginFrame(self: Context, clear_color: theme.Rgba) frame_module.FrameInfo {
            _ = clear_color;
            self.state.frame_count += 1;
            self.state.clearFrameRecord();
            return .{ .size = self.state.window, .density = self.state.density };
        }

        pub fn endFrame(self: Context) void {
            _ = self;
        }

        pub fn fillRect(self: Context, rect: layout.Rect, color: theme.Rgba) void {
            self.state.fill_rect_count += 1;
            self.state.fills.append(self.state.allocator, .{
                .rect = rect,
                .color = color,
            }) catch {};
        }

        pub fn strokeRect(self: Context, rect: layout.Rect, color: theme.Rgba) void {
            self.state.outlines.append(self.state.allocator, .{
                .rect = rect,
                .color = color,
            }) catch {};
        }

        pub fn setClip(self: Context, rect: ?layout.Rect) void {
            self.state.clips.append(self.state.allocator, rect) catch {};
        }

        pub fn drawTexture(
            self: Context,
            texture: Texture,
            destination: layout.Rect,
            tint: theme.Rgba,
        ) void {
            self.state.draw_texture_count += 1;
            self.state.texture_draws.append(self.state.allocator, .{
                .serial = texture.serial,
                .rect = destination,
                .tint = tint,
            }) catch {};
        }

        pub fn drawTriangles(
            self: Context,
            vertices: []const layout.Vec2,
            colors: []const theme.FColor,
            indices: []const u32,
        ) void {
            std.debug.assert(vertices.len == colors.len);
            self.state.triangle_batch_count += 1;
            self.state.triangle_count += indices.len / 3;
            self.state.batches.append(self.state.allocator, .{
                .triangle_count = indices.len / 3,
                .first_color = if (colors.len > 0) colors[0] else theme.toFloat(theme.white),
            }) catch {};
        }

        pub fn createText(self: Context, text: [:0]const u8, size: u8, strong: bool) ?TextImage {
            if (self.state.fail_text) return null;
            self.state.text_create_count += 1;
            const width = self.measureText(text, size, strong);
            var label = TextureLabel{ .serial = 0, .kind = .text, .size = size, .strong = strong };
            const kept = @min(text.len, TextureLabel.text_capacity);
            @memcpy(label.text[0..kept], text[0..kept]);
            label.text_length = @intCast(kept);
            return .{
                .texture = self.state.newTexture(label, @intFromFloat(width), size + 6),
                .width = width,
                .height = @floatFromInt(size + 6),
            };
        }

        pub fn measureText(self: Context, text: [:0]const u8, size: u8, strong: bool) f32 {
            _ = strong;
            self.state.measure_count += 1;
            const glyph_width = @as(f32, @floatFromInt(size)) * 0.58;
            return glyph_width * @as(f32, @floatFromInt(text.len)) + 8;
        }

        pub fn createIcon(self: Context, icon: theme.Icon, color: theme.Rgba) ?Texture {
            self.state.icon_create_count += 1;
            return self.state.newTexture(.{
                .serial = 0,
                .kind = .icon,
                .icon = icon,
                .color = color,
            }, 40, 40);
        }
    };

    pub const Document = struct {
        state: *State,
        allocator: std.mem.Allocator,
        path_value: []const u8,
        serial: u64,

        pub fn open(
            context: Context,
            allocator: std.mem.Allocator,
            raw_path: []const u8,
        ) error{ InvalidPdf, OutOfMemory }!Document {
            if (context.state.fail_open) return error.InvalidPdf;
            // The native document keeps its own copy of the path, so the mock
            // does too; callers may free the argument right after opening.
            const path_copy = try allocator.dupe(u8, raw_path);
            context.state.document_open_count += 1;
            return .{
                .state = context.state,
                .allocator = allocator,
                .path_value = path_copy,
                .serial = context.state.document_open_count,
            };
        }

        pub fn deinit(self: *Document) void {
            self.state.document_deinit_count += 1;
            self.allocator.free(self.path_value);
            self.* = undefined;
        }

        pub fn pageCount(self: Document) usize {
            return self.state.page_count;
        }

        pub fn path(self: Document) []const u8 {
            return self.path_value;
        }

        pub fn pageSize(self: Document, page_index: usize) ?layout.Size {
            if (page_index >= self.state.page_count) return null;
            return self.state.page_size;
        }

        pub fn identity(self: Document) u64 {
            return self.serial;
        }

        pub fn render(
            self: Document,
            context: Context,
            page_index: usize,
            scale: f32,
            dark_mode: bool,
        ) error{PageRenderFailed}!Texture {
            _ = context;
            self.state.render_count += 1;
            self.state.last_render_page = page_index;
            self.state.last_render_dark_mode = dark_mode;
            self.state.last_render_scale = scale;
            if (self.state.fail_render) return error.PageRenderFailed;
            if (page_index >= self.state.page_count) return error.PageRenderFailed;
            return self.state.newTexture(
                .{ .serial = 0, .kind = .page },
                @intFromFloat(self.state.page_size.width * scale),
                @intFromFloat(self.state.page_size.height * scale),
            );
        }
    };

    /// Queue of page rasterizations. Jobs complete immediately by default;
    /// see `State.auto_complete_renders`.
    pub const RenderQueue = struct {
        state: *State,

        pub fn submit(self: *RenderQueue, job: Job) error{OutOfMemory}!u64 {
            var owned = job;
            owned.id = self.state.next_job_id;
            self.state.next_job_id += 1;
            self.state.submitted_job_count += 1;
            if (self.state.auto_complete_renders) {
                try self.state.finishJob(owned);
            } else {
                try self.state.render_jobs.append(self.state.allocator, owned);
            }
            return owned.id;
        }

        pub fn cancel(self: *RenderQueue, id: u64) bool {
            for (self.state.render_jobs.items, 0..) |job, index| {
                if (job.id != id) continue;
                _ = self.state.render_jobs.orderedRemove(index);
                self.state.cancelled_job_count += 1;
                return true;
            }
            return false;
        }

        pub fn cancelAll(self: *RenderQueue) void {
            self.state.cancelled_job_count += self.state.render_jobs.items.len;
            self.state.render_jobs.clearRetainingCapacity();
        }

        pub fn reprioritize(self: *RenderQueue, id: u64, priority: rendering.Priority) void {
            for (self.state.render_jobs.items) |*job| {
                if (job.id == id) job.priority = priority;
            }
        }

        pub fn pendingCount(self: *RenderQueue) usize {
            return self.state.render_jobs.items.len;
        }

        pub fn isIdle(self: *RenderQueue) bool {
            return self.state.render_jobs.items.len == 0;
        }

        /// The native queue blocks until the worker is idle; the mock finishes
        /// every pending job instead.
        pub fn waitIdle(self: *RenderQueue) void {
            self.state.completeAllRenders();
        }

        /// Hands over the next finished job of the current generation. Results
        /// of earlier generations are released unseen.
        pub fn poll(self: *RenderQueue, context: Context, generation: u64) ?RenderResult {
            _ = context;
            while (self.state.render_results.items.len > 0) {
                var result = self.state.render_results.orderedRemove(0);
                if (result.job.generation == generation) return result;
                if (result.texture) |*texture| texture.deinit();
            }
            return null;
        }
    };

    pub const Storage = struct {
        state: *State,

        pub fn isAvailable(self: *Storage) bool {
            return self.state.storage_available;
        }

        pub fn read(
            self: *Storage,
            allocator: std.mem.Allocator,
            name: []const u8,
        ) error{OutOfMemory}!?[]u8 {
            self.state.read_count += 1;
            if (!self.state.storage_available) return null;
            const data = self.state.files.get(name) orelse return null;
            return try allocator.dupe(u8, data);
        }

        /// Writes synchronously and queues the completion, so the application
        /// exercises the same completion path as with the native storage.
        pub fn write(
            self: *Storage,
            name: []const u8,
            data: []const u8,
        ) storage_module.WriteError!void {
            self.state.write_count += 1;
            if (!self.state.storage_available) return error.StorageUnavailable;
            var failed = self.state.fail_write;
            if (!failed) self.state.putFile(name, data) catch {
                failed = true;
            };
            try self.state.write_completions.append(self.state.allocator, .{
                .name = storage_module.Name.of(name),
                .failed = failed,
            });
        }

        pub fn hasPendingWrites(self: *Storage) bool {
            _ = self;
            return false;
        }

        pub fn pollCompletion(self: *Storage) ?storage_module.Completion {
            if (self.state.write_completions.items.len == 0) return null;
            return self.state.write_completions.orderedRemove(0);
        }

        pub fn flush(self: *Storage) void {
            _ = self;
        }
    };
};

test "the mock records what a frame drew and what textures were made of" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    const context = Backend.Context{ .state = &state };
    _ = context.beginFrame(theme.white);
    const rect = layout.Rect{ .x = 1, .y = 2, .w = 3, .h = 4 };
    context.fillRect(rect, theme.rgb(9, 9, 9));
    context.strokeRect(rect, theme.rgb(8, 8, 8));
    context.setClip(rect);
    context.setClip(null);
    var text = context.createText("Pen", 16, true).?;
    defer text.texture.deinit();
    context.drawTexture(text.texture, rect, theme.rgb(7, 7, 7));
    var icon = context.createIcon(.undo, theme.rgb(6, 6, 6)).?;
    defer icon.deinit();
    context.drawTexture(icon, rect, theme.white);

    try std.testing.expect(state.filled(rect, theme.rgb(9, 9, 9)));
    try std.testing.expect(!state.filled(rect, theme.rgb(1, 9, 9)));
    try std.testing.expect(state.outlined(rect, theme.rgb(8, 8, 8)));
    try std.testing.expectEqual(@as(usize, 2), state.clips.items.len);
    try std.testing.expectEqual(@as(?layout.Rect, null), state.clips.items[1]);
    try std.testing.expectEqual(theme.rgb(7, 7, 7), state.textDraw("Pen").?.tint);
    try std.testing.expectEqual(@as(?DrawnTexture, null), state.textDraw("Eraser"));
    try std.testing.expectEqual(theme.rgb(6, 6, 6), state.iconColor(.undo).?);
    try std.testing.expectEqual(@as(?theme.Rgba, null), state.iconColor(.alert));
    try std.testing.expectEqual(@as(usize, 1), state.fillsInside(rect));

    // The record belongs to one frame.
    _ = context.beginFrame(theme.white);
    try std.testing.expect(!state.filled(rect, theme.rgb(9, 9, 9)));
    try std.testing.expectEqual(@as(?DrawnTexture, null), state.textDraw("Pen"));
}

test "mock state stores files and queues owned input paths" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    try state.putFile("a", "one");
    try state.putFile("a", "two");
    try std.testing.expectEqualStrings("two", state.getFile("a").?);
    try state.pushInput(.{ .kind = .file, .path = "book.pdf" });
    const context = Backend.Context{ .state = &state };
    const raw = context.pollInput(std.testing.allocator).?;
    defer if (raw.path) |path| std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("book.pdf", raw.path.?);
    const drained = context.pollInput(std.testing.allocator);
    try std.testing.expectEqual(@as(?input.RawInput, null), drained);
}

test "the mock render queue completes jobs immediately or on demand" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    const context = Backend.Context{ .state = &state };
    var document = try Backend.Document.open(context, std.testing.allocator, "book.pdf");
    defer document.deinit();
    var queue = Backend.RenderQueue{ .state = &state };
    const job = Backend.Job{
        .document = document,
        .generation = 1,
        .page_index = 0,
        .scale = 1,
        .dark_mode = false,
        .purpose = .page,
        .priority = .immediate,
    };

    const first = try queue.submit(job);
    try std.testing.expect(queue.isIdle());
    var result = queue.poll(context, 1).?;
    try std.testing.expectEqual(first, result.job.id);
    result.texture.?.deinit();

    state.auto_complete_renders = false;
    const second = try queue.submit(job);
    try std.testing.expectEqual(@as(usize, 1), queue.pendingCount());
    try std.testing.expectEqual(@as(?Backend.RenderResult, null), queue.poll(context, 1));
    try std.testing.expect(queue.cancel(second));
    try std.testing.expect(!queue.cancel(second));
    _ = try queue.submit(job);
    queue.waitIdle();
    try std.testing.expect(queue.isIdle());
    // A result of another generation is dropped and its texture released.
    try std.testing.expectEqual(@as(?Backend.RenderResult, null), queue.poll(context, 2));
    try std.testing.expectEqual(@as(usize, 2), state.texture_deinit_count);
}
