//! Typed boundary around the native C bridge.
//!
//! C types, ownership rules, and integer constants stop here. The interface
//! and application layers only see domain values: raw input records, sizes,
//! rectangles, colors, textures, documents, and render jobs.
//!
//! After a document is opened, only the render worker calls Poppler for it;
//! page sizes are read once at open time so the main thread never blocks on
//! a render in progress.

const std = @import("std");
const lectern = @import("lectern");
const annotations = lectern.annotations;
const ui = @import("ui.zig");
const rendering = @import("rendering.zig");
const layout = ui.layout;
const theme = ui.theme;
const input = ui.input;
const frame = ui.frame;

const c = @cImport({
    @cInclude("bridge.h");
});

pub const Texture = struct {
    handle: *c.LECTERN_Texture,
    width: u32,
    height: u32,

    fn fromHandle(handle: *c.LECTERN_Texture) Texture {
        var width: c_int = 0;
        var height: c_int = 0;
        c.lectern_texture_size(handle, &width, &height);
        return .{
            .handle = handle,
            .width = @intCast(@max(width, 0)),
            .height = @intCast(@max(height, 0)),
        };
    }

    pub fn deinit(self: *Texture) void {
        c.lectern_texture_destroy(self.handle);
        self.* = undefined;
    }
};

pub const TextImage = struct {
    texture: Texture,
    width: f32,
    height: f32,
};

pub const Context = struct {
    handle: *c.LECTERN_Context,

    pub fn init() error{WindowInitializationFailed}!Context {
        var error_message: [*c]u8 = null;
        const handle = c.lectern_init(&error_message) orelse {
            defer if (error_message != null) c.lectern_free(error_message);
            if (error_message != null) {
                std.log.err("window initialization failed: {s}", .{std.mem.span(error_message)});
            } else {
                std.log.err("window initialization failed", .{});
            }
            return error.WindowInitializationFailed;
        };
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Context) void {
        c.lectern_shutdown(self.handle);
        self.* = undefined;
    }

    /// Message for the most recent native failure. Valid until the next call
    /// into the bridge.
    pub fn lastError(self: Context) [:0]const u8 {
        return std.mem.span(c.lectern_last_error(self.handle));
    }

    pub fn pollInput(self: Context, allocator: std.mem.Allocator) ?input.RawInput {
        var native: c.LECTERN_Input = undefined;
        if (c.lectern_poll_input(self.handle, &native) == 0) return null;
        return convertInput(allocator, native);
    }

    /// Waits for input; a null timeout waits until an event or a finished
    /// render wakes the loop.
    pub fn waitInput(
        self: Context,
        allocator: std.mem.Allocator,
        timeout_ms: ?u32,
    ) ?input.RawInput {
        var native: c.LECTERN_Input = undefined;
        const timeout: c_int = if (timeout_ms) |milliseconds|
            @intCast(@min(milliseconds, std.math.maxInt(c_int)))
        else
            -1;
        if (c.lectern_wait_input(self.handle, timeout, &native) == 0) return null;
        return convertInput(allocator, native);
    }

    pub fn ticksMs(self: Context) u64 {
        _ = self;
        return c.lectern_ticks_ms();
    }

    pub fn windowSize(self: Context) layout.Size {
        var width: f32 = 0;
        var height: f32 = 0;
        c.lectern_window_size(self.handle, &width, &height);
        return .{ .width = width, .height = height };
    }

    /// Identifies the window in synthetic native events; used by tests.
    pub fn windowId(self: Context) u32 {
        return c.lectern_window_id(self.handle);
    }

    pub fn pixelDensity(self: Context) f32 {
        return c.lectern_pixel_density(self.handle);
    }

    pub fn setWindowSize(self: Context, width: u32, height: u32) bool {
        return c.lectern_set_window_size(self.handle, @intCast(width), @intCast(height)) != 0;
    }

    pub fn setTitle(self: Context, title: [:0]const u8) void {
        c.lectern_set_title(self.handle, title.ptr);
    }

    pub fn showError(self: Context, message: [:0]const u8) void {
        c.lectern_show_error(self.handle, message.ptr);
    }

    pub fn openDialog(self: Context) void {
        c.lectern_open_dialog(self.handle);
    }

    pub fn saveScreenshot(self: Context, path: [:0]const u8) bool {
        return c.lectern_save_screenshot(self.handle, path.ptr) != 0;
    }

    pub fn beginFrame(self: Context, clear_color: theme.Rgba) frame.FrameInfo {
        var width: f32 = 0;
        var height: f32 = 0;
        var density: f32 = 1;
        c.lectern_frame_begin(self.handle, toColor(clear_color), &width, &height, &density);
        return .{ .size = .{ .width = width, .height = height }, .density = density };
    }

    pub fn endFrame(self: Context) void {
        c.lectern_frame_end(self.handle);
    }

    pub fn fillRect(self: Context, rect: layout.Rect, color: theme.Rgba) void {
        c.lectern_fill_rect(self.handle, toRect(rect), toColor(color));
    }

    pub fn strokeRect(self: Context, rect: layout.Rect, color: theme.Rgba) void {
        c.lectern_stroke_rect(self.handle, toRect(rect), toColor(color));
    }

    pub fn setClip(self: Context, rect: ?layout.Rect) void {
        if (rect) |clip| {
            const native = toRect(clip);
            c.lectern_set_clip(self.handle, &native);
        } else {
            c.lectern_set_clip(self.handle, null);
        }
    }

    pub fn drawTexture(
        self: Context,
        texture: Texture,
        destination: layout.Rect,
        tint: theme.Rgba,
    ) void {
        c.lectern_draw_texture(self.handle, texture.handle, toRect(destination), toColor(tint));
    }

    /// Draws colored triangles. Points, colors, and indices share the
    /// bridge's memory layout, so nothing is copied here or in the bridge.
    pub fn drawTriangles(
        self: Context,
        vertices: []const layout.Vec2,
        colors: []const theme.FColor,
        indices: []const u32,
    ) void {
        std.debug.assert(vertices.len == colors.len);
        if (vertices.len == 0 or indices.len == 0) return;
        c.lectern_draw_triangles(
            self.handle,
            @ptrCast(vertices.ptr),
            @ptrCast(colors.ptr),
            vertices.len,
            @ptrCast(indices.ptr),
            indices.len,
        );
    }

    pub fn createText(self: Context, text: [:0]const u8, size: u8, strong: bool) ?TextImage {
        var width: f32 = 0;
        var height: f32 = 0;
        const handle = c.lectern_create_text(
            self.handle,
            text.ptr,
            size,
            @intFromBool(strong),
            &width,
            &height,
        ) orelse return null;
        return .{ .texture = Texture.fromHandle(handle), .width = width, .height = height };
    }

    pub fn measureText(self: Context, text: [:0]const u8, size: u8, strong: bool) f32 {
        return c.lectern_measure_text(self.handle, text.ptr, size, @intFromBool(strong));
    }

    pub fn createIcon(self: Context, icon: theme.Icon, color: theme.Rgba) ?Texture {
        const handle = c.lectern_create_icon(
            self.handle,
            @intFromEnum(icon),
            toColor(color),
        ) orelse return null;
        return Texture.fromHandle(handle);
    }

    /// Uploads a page image rendered by the worker. Main thread only.
    fn textureFromImage(self: Context, image: *c.LECTERN_Image) ?Texture {
        const handle = c.lectern_texture_from_image(self.handle, image) orelse return null;
        return Texture.fromHandle(handle);
    }
};

pub const Document = struct {
    handle: *c.LECTERN_Document,
    allocator: std.mem.Allocator,
    /// Read once at open time; null for pages Poppler could not measure.
    page_sizes: []?layout.Size,

    pub fn open(
        context: Context,
        allocator: std.mem.Allocator,
        raw_path: []const u8,
    ) error{ InvalidPdf, OutOfMemory }!Document {
        const path_z = try allocator.dupeZ(u8, raw_path);
        defer allocator.free(path_z);
        const handle = c.lectern_pdf_open(context.handle, path_z.ptr) orelse {
            return error.InvalidPdf;
        };
        errdefer c.lectern_pdf_close(handle);

        const page_count = c.lectern_pdf_page_count(handle);
        const page_sizes = try allocator.alloc(?layout.Size, @intCast(@max(page_count, 0)));
        for (page_sizes, 0..) |*size, index| {
            var width: f32 = 0;
            var height: f32 = 0;
            const found = c.lectern_pdf_page_size(handle, @intCast(index), &width, &height);
            size.* = if (found != 0) .{ .width = width, .height = height } else null;
        }
        return .{ .handle = handle, .allocator = allocator, .page_sizes = page_sizes };
    }

    pub fn deinit(self: *Document) void {
        c.lectern_pdf_close(self.handle);
        self.allocator.free(self.page_sizes);
        self.* = undefined;
    }

    pub fn pageCount(self: Document) usize {
        return self.page_sizes.len;
    }

    pub fn path(self: Document) []const u8 {
        return std.mem.span(c.lectern_pdf_path(self.handle));
    }

    pub fn pageSize(self: Document, page_index: usize) ?layout.Size {
        if (page_index >= self.page_sizes.len) return null;
        return self.page_sizes[page_index];
    }

    /// Distinguishes document instances for caches; reopening a file yields
    /// a new identity so stale thumbnails are never shown.
    pub fn identity(self: Document) u64 {
        return c.lectern_pdf_identity(self.handle);
    }

    /// Rasterizes and uploads on the calling thread. Used when opening a
    /// document, before the worker takes over.
    pub fn render(
        self: Document,
        context: Context,
        page_index: usize,
        scale: f32,
        dark_mode: bool,
    ) error{PageRenderFailed}!Texture {
        if (page_index > std.math.maxInt(c_int)) return error.PageRenderFailed;
        const handle = c.lectern_pdf_render(
            context.handle,
            self.handle,
            @intCast(page_index),
            scale,
            @intFromBool(dark_mode),
        ) orelse return error.PageRenderFailed;
        return Texture.fromHandle(handle);
    }

    /// Rasterizes without touching the window; safe on the worker thread.
    fn renderImage(
        self: Document,
        page_index: usize,
        scale: f32,
        dark_mode: bool,
    ) ?*c.LECTERN_Image {
        if (page_index > std.math.maxInt(c_int)) return null;
        return c.lectern_pdf_render_image(
            self.handle,
            @intCast(page_index),
            scale,
            @intFromBool(dark_mode),
        );
    }
};

/// Rasterizes pages on one worker thread. Results wait as images until the
/// main thread polls them and turns them into textures. A queue must not
/// move after the first job was submitted, because the worker keeps a
/// pointer to it.
pub const RenderQueue = struct {
    pub const Job = rendering.Job(Document);
    pub const Result = rendering.Result(Document, Texture);

    const Completed = struct {
        job: Job,
        image: ?*c.LECTERN_Image,
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    pending: std.ArrayList(Job) = .empty,
    completed: std.ArrayList(Completed) = .empty,
    running: ?u64 = null,
    quit: bool = false,
    thread: ?std.Thread = null,
    next_id: u64 = 1,
    /// Jobs rendered on the caller's thread because no worker could start.
    synchronous_render_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) RenderQueue {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *RenderQueue) void {
        self.mutex.lockUncancelable(self.io);
        self.quit = true;
        self.pending.clearRetainingCapacity();
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
        if (self.thread) |thread| thread.join();
        for (self.completed.items) |done| c.lectern_image_destroy(done.image);
        self.completed.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn submit(self: *RenderQueue, job: Job) error{OutOfMemory}!u64 {
        var owned = job;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        owned.id = self.next_id;
        self.next_id += 1;
        if (self.thread == null) self.startWorkerLocked();
        if (self.thread == null) {
            // No worker: render right here so the reader still works.
            self.synchronous_render_count += 1;
            const image = owned.document.renderImage(
                owned.page_index,
                owned.scale,
                owned.dark_mode,
            );
            errdefer c.lectern_image_destroy(image);
            try self.completed.append(self.allocator, .{ .job = owned, .image = image });
            return owned.id;
        }
        try self.pending.append(self.allocator, owned);
        self.condition.broadcast(self.io);
        return owned.id;
    }

    /// Removes a job that has not started. Returns false when it is running
    /// or already finished; its result then arrives normally.
    pub fn cancel(self: *RenderQueue, id: u64) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.pending.items, 0..) |job, index| {
            if (job.id != id) continue;
            _ = self.pending.orderedRemove(index);
            return true;
        }
        return false;
    }

    pub fn cancelAll(self: *RenderQueue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.pending.clearRetainingCapacity();
    }

    pub fn reprioritize(self: *RenderQueue, id: u64, priority: rendering.Priority) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.pending.items) |*job| {
            if (job.id == id) job.priority = priority;
        }
    }

    pub fn pendingCount(self: *RenderQueue) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.pending.items.len;
    }

    pub fn isIdle(self: *RenderQueue) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.pending.items.len == 0 and self.running == null;
    }

    /// Blocks until no job is pending or running. Bounded by one page render.
    pub fn waitIdle(self: *RenderQueue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.pending.items.len > 0 or self.running != null) {
            self.condition.waitUncancelable(self.io, &self.mutex);
        }
    }

    /// Hands over the next finished job of the current generation as a
    /// texture. Results of earlier generations are released unseen. Main
    /// thread only, because textures are created here.
    pub fn poll(self: *RenderQueue, context: Context, generation: u64) ?Result {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            if (self.completed.items.len == 0) {
                self.mutex.unlock(self.io);
                return null;
            }
            const done = self.completed.orderedRemove(0);
            self.mutex.unlock(self.io);

            if (done.job.generation != generation) {
                c.lectern_image_destroy(done.image);
                continue;
            }
            const image = done.image orelse return .{ .job = done.job, .texture = null };
            defer c.lectern_image_destroy(image);
            return .{ .job = done.job, .texture = context.textureFromImage(image) };
        }
    }

    fn startWorkerLocked(self: *RenderQueue) void {
        const thread = std.Thread.spawn(.{}, worker, .{self}) catch |err| {
            std.log.warn("could not start the render thread: {s}", .{@errorName(err)});
            return;
        };
        // The name only helps profilers and debuggers tell threads apart.
        thread.setName(self.io, "lectern-render") catch {};
        self.thread = thread;
    }

    fn worker(self: *RenderQueue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (true) {
            const index = rendering.nextJobIndex(Document, self.pending.items) orelse {
                if (self.quit) return;
                self.condition.waitUncancelable(self.io, &self.mutex);
                continue;
            };
            const job = self.pending.orderedRemove(index);
            self.running = job.id;
            self.mutex.unlock(self.io);

            const image = job.document.renderImage(job.page_index, job.scale, job.dark_mode);

            self.mutex.lockUncancelable(self.io);
            self.running = null;
            self.completed.append(self.allocator, .{ .job = job, .image = image }) catch {
                c.lectern_image_destroy(image);
            };
            self.condition.broadcast(self.io);
            self.mutex.unlock(self.io);
            c.lectern_wake();
            self.mutex.lockUncancelable(self.io);
        }
    }
};

fn convertInput(allocator: std.mem.Allocator, native: c.LECTERN_Input) input.RawInput {
    defer if (native.path != null) c.lectern_free(native.path);
    var raw = input.RawInput{
        .kind = std.enums.fromInt(input.Kind, native.kind) orelse .none,
        .position = .{ .x = native.x, .y = native.y },
        .wheel = native.wheel,
        .key = std.enums.fromInt(input.Key, native.key) orelse .none,
        .button = std.enums.fromInt(input.Button, native.button) orelse .none,
        .left_held = native.left_held != 0,
    };
    if (native.path != null) {
        raw.path = allocator.dupe(u8, std.mem.span(native.path)) catch {
            // The drop is lost but the reader keeps running; nothing else
            // depends on it, so this is a warning like every handled failure.
            std.log.warn("could not keep the dropped path", .{});
            return .{ .kind = .none };
        };
    }
    return raw;
}

fn toColor(color: theme.Rgba) c.LECTERN_Color {
    return .{ .r = color.red, .g = color.green, .b = color.blue, .a = color.alpha };
}

fn toRect(rect: layout.Rect) c.LECTERN_Rect {
    return .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
}

fn comptimeUpper(comptime name: []const u8) []const u8 {
    comptime {
        var upper: [name.len]u8 = undefined;
        for (name, 0..) |character, index| upper[index] = std.ascii.toUpper(character);
        const result = upper;
        return &result;
    }
}

/// Every Zig enum that mirrors a native constant is checked field by field, so
/// the two sides cannot drift apart silently.
fn checkNativeConstants(comptime Enum: type, comptime prefix: []const u8) void {
    comptime {
        for (std.meta.fields(Enum)) |field| {
            const native_name = prefix ++ comptimeUpper(field.name);
            if (@field(c, native_name) != field.value) {
                @compileError("native constant " ++ native_name ++ " does not match " ++
                    @typeName(Enum));
            }
        }
    }
}

fn checkSameLayout(comptime Zig: type, comptime Native: type, comptime what: []const u8) void {
    comptime {
        if (@sizeOf(Zig) != @sizeOf(Native) or @alignOf(Zig) != @alignOf(Native)) {
            @compileError(what ++ " ABI does not match the native bridge");
        }
    }
}

comptime {
    checkNativeConstants(input.Kind, "LECTERN_INPUT_");
    checkNativeConstants(input.Key, "LECTERN_KEY_");
    checkNativeConstants(input.Button, "LECTERN_BUTTON_");
    checkNativeConstants(theme.Icon, "LECTERN_ICON_");
    checkSameLayout(layout.Vec2, c.LECTERN_Point, "window point");
    checkSameLayout(layout.Rect, c.LECTERN_Rect, "rectangle");
    checkSameLayout(theme.Rgba, c.LECTERN_Color, "color");
    checkSameLayout(theme.FColor, c.LECTERN_FColor, "vertex color");
    checkSameLayout(u32, c_int, "triangle index");
    if (theme.icon_size != c.LECTERN_ICON_SIZE) {
        @compileError("icon size does not match the native bridge");
    }
    if (layout.default_window.width != c.LECTERN_DEFAULT_WINDOW_WIDTH or
        layout.default_window.height != c.LECTERN_DEFAULT_WINDOW_HEIGHT)
    {
        @compileError("default window size does not match the native bridge");
    }
    if (layout.minimum_window.width != c.LECTERN_MINIMUM_WINDOW_WIDTH or
        layout.minimum_window.height != c.LECTERN_MINIMUM_WINDOW_HEIGHT)
    {
        @compileError("minimum window size does not match the native bridge");
    }
    if (layout.maximum_page_pixels > c.LECTERN_MAXIMUM_PAGE_PIXELS) {
        @compileError("the page pixel policy exceeds the native hard limit");
    }
}
