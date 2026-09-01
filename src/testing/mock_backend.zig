//! In-memory backend for application and interface tests.
//!
//! Every native concept has a counting stand-in: textures, documents, input,
//! the clock, and storage. Tests inject failures through `State` flags.

const std = @import("std");
const ui = @import("../ui.zig");
const input = ui.input;
const layout = ui.layout;
const theme = ui.theme;
const frame_module = ui.frame;

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
    last_wait_timeout: u32 = 0,
    write_count: usize = 0,
    read_count: usize = 0,

    ticks: u64 = 0,
    window: layout.Size = .{ .width = 1100, .height = 820 },
    density: f32 = 1,
    title: [256]u8 = undefined,
    title_length: usize = 0,
    inputs: std.ArrayList(input.RawInput) = .empty,
    input_index: usize = 0,
    files: std.StringHashMapUnmanaged([]u8) = .empty,

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
        self.* = undefined;
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

    fn takeInput(self: *State, allocator: std.mem.Allocator) ?input.RawInput {
        if (self.input_index >= self.inputs.items.len) return null;
        var raw = self.inputs.items[self.input_index];
        self.input_index += 1;
        if (raw.path) |path| {
            raw.path = allocator.dupe(u8, path) catch null;
        }
        return raw;
    }
};

pub const Backend = struct {
    pub const Texture = struct {
        state: *State,
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

        pub fn waitInput(
            self: Context,
            allocator: std.mem.Allocator,
            timeout_ms: u32,
        ) ?input.RawInput {
            self.state.wait_count += 1;
            self.state.last_wait_timeout = timeout_ms;
            self.state.ticks += timeout_ms;
            return self.state.takeInput(allocator);
        }

        pub fn ticksMs(self: Context) u64 {
            return self.state.ticks;
        }

        pub fn windowSize(self: Context) layout.Size {
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
            return .{ .size = self.state.window, .density = self.state.density };
        }

        pub fn endFrame(self: Context) void {
            _ = self;
        }

        pub fn fillRect(self: Context, rect: layout.Rect, color: theme.Rgba) void {
            _ = rect;
            _ = color;
            self.state.fill_rect_count += 1;
        }

        pub fn strokeRect(self: Context, rect: layout.Rect, color: theme.Rgba) void {
            _ = self;
            _ = rect;
            _ = color;
        }

        pub fn setClip(self: Context, rect: ?layout.Rect) void {
            _ = self;
            _ = rect;
        }

        pub fn drawTexture(
            self: Context,
            texture: Texture,
            destination: layout.Rect,
            tint: theme.Rgba,
        ) void {
            _ = texture;
            _ = destination;
            _ = tint;
            self.state.draw_texture_count += 1;
        }

        pub fn drawTriangles(
            self: Context,
            vertices: []const layout.Vec2,
            indices: []const c_int,
            color: theme.Rgba,
        ) void {
            _ = vertices;
            _ = color;
            self.state.triangle_batch_count += 1;
            self.state.triangle_count += indices.len / 3;
        }

        pub fn createText(self: Context, text: [:0]const u8, size: u8, strong: bool) ?TextImage {
            if (self.state.fail_text) return null;
            self.state.text_create_count += 1;
            self.state.texture_create_count += 1;
            const width = self.measureText(text, size, strong);
            return .{
                .texture = .{
                    .state = self.state,
                    .width = @intFromFloat(width),
                    .height = size + 6,
                },
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
            _ = icon;
            _ = color;
            self.state.icon_create_count += 1;
            self.state.texture_create_count += 1;
            return .{ .state = self.state, .width = 40, .height = 40 };
        }
    };

    pub const Document = struct {
        state: *State,
        path_value: []const u8,
        serial: u64,

        pub fn open(
            context: Context,
            allocator: std.mem.Allocator,
            raw_path: []const u8,
        ) !Document {
            _ = allocator;
            if (context.state.fail_open) return error.InvalidPdf;
            // The native document keeps its own copy of the path, so the mock
            // does too; callers may free the argument right after opening.
            const path_copy = try context.state.allocator.dupe(u8, raw_path);
            context.state.document_open_count += 1;
            return .{
                .state = context.state,
                .path_value = path_copy,
                .serial = context.state.document_open_count,
            };
        }

        pub fn deinit(self: *Document) void {
            self.state.document_deinit_count += 1;
            self.state.allocator.free(self.path_value);
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
        ) !Texture {
            _ = context;
            self.state.render_count += 1;
            self.state.last_render_page = page_index;
            self.state.last_render_dark_mode = dark_mode;
            self.state.last_render_scale = scale;
            if (self.state.fail_render) return error.PageRenderFailed;
            if (page_index >= self.state.page_count) return error.PageRenderFailed;
            self.state.texture_create_count += 1;
            return .{
                .state = self.state,
                .width = @intFromFloat(self.state.page_size.width * scale),
                .height = @intFromFloat(self.state.page_size.height * scale),
            };
        }
    };

    pub const Storage = struct {
        state: *State,

        pub fn isAvailable(self: Storage) bool {
            return self.state.storage_available;
        }

        pub fn read(
            self: Storage,
            allocator: std.mem.Allocator,
            name: []const u8,
        ) error{OutOfMemory}!?[]u8 {
            self.state.read_count += 1;
            if (!self.state.storage_available) return null;
            const data = self.state.files.get(name) orelse return null;
            return try allocator.dupe(u8, data);
        }

        pub fn write(self: Storage, name: []const u8, data: []const u8) !void {
            self.state.write_count += 1;
            if (!self.state.storage_available) return error.StorageUnavailable;
            if (self.state.fail_write) return error.WriteFailed;
            try self.state.putFile(name, data);
        }
    };
};

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
