//! Typed boundary around the native C bridge.
//!
//! C types, ownership rules, and integer constants stop here. The interface
//! and application layers only see domain values: raw input records, sizes,
//! rectangles, colors, textures, and documents.

const std = @import("std");
const book_read = @import("book_read");
const annotations = book_read.annotations;
const ui = @import("ui.zig");
const layout = ui.layout;
const theme = ui.theme;
const input = ui.input;
const frame = ui.frame;

const c = @cImport({
    @cInclude("bridge.h");
});

pub const Texture = struct {
    handle: *c.BR_Texture,
    width: u32,
    height: u32,

    fn fromHandle(handle: *c.BR_Texture) Texture {
        var width: c_int = 0;
        var height: c_int = 0;
        c.br_texture_size(handle, &width, &height);
        return .{
            .handle = handle,
            .width = @intCast(@max(width, 0)),
            .height = @intCast(@max(height, 0)),
        };
    }

    pub fn deinit(self: *Texture) void {
        c.br_texture_destroy(self.handle);
        self.* = undefined;
    }
};

pub const TextImage = struct {
    texture: Texture,
    width: f32,
    height: f32,
};

pub const Context = struct {
    handle: *c.BR_Context,

    pub fn init() !Context {
        var error_message: [*c]u8 = null;
        const handle = c.br_init(&error_message) orelse {
            defer if (error_message != null) c.br_free(error_message);
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
        c.br_shutdown(self.handle);
        self.* = undefined;
    }

    /// Message for the most recent native failure. Valid until the next call
    /// into the bridge.
    pub fn lastError(self: Context) [:0]const u8 {
        return std.mem.span(c.br_last_error(self.handle));
    }

    pub fn pollInput(self: Context, allocator: std.mem.Allocator) ?input.RawInput {
        var native: c.BR_Input = undefined;
        if (c.br_poll_input(self.handle, &native) == 0) return null;
        return convertInput(allocator, native);
    }

    pub fn waitInput(self: Context, allocator: std.mem.Allocator, timeout_ms: u32) ?input.RawInput {
        var native: c.BR_Input = undefined;
        const timeout: c_int = @intCast(@min(timeout_ms, std.math.maxInt(c_int)));
        if (c.br_wait_input(self.handle, timeout, &native) == 0) return null;
        return convertInput(allocator, native);
    }

    pub fn ticksMs(self: Context) u64 {
        _ = self;
        return c.br_ticks_ms();
    }

    pub fn windowSize(self: Context) layout.Size {
        var width: f32 = 0;
        var height: f32 = 0;
        c.br_window_size(self.handle, &width, &height);
        return .{ .width = width, .height = height };
    }

    /// Identifies the window in synthetic native events; used by tests.
    pub fn windowId(self: Context) u32 {
        return c.br_window_id(self.handle);
    }

    pub fn pixelDensity(self: Context) f32 {
        return c.br_pixel_density(self.handle);
    }

    pub fn setWindowSize(self: Context, width: u32, height: u32) bool {
        return c.br_set_window_size(self.handle, @intCast(width), @intCast(height)) != 0;
    }

    pub fn setTitle(self: Context, title: [:0]const u8) void {
        c.br_set_title(self.handle, title.ptr);
    }

    pub fn showError(self: Context, message: [:0]const u8) void {
        c.br_show_error(self.handle, message.ptr);
    }

    pub fn openDialog(self: Context) void {
        c.br_open_dialog(self.handle);
    }

    pub fn saveScreenshot(self: Context, path: [:0]const u8) bool {
        return c.br_save_screenshot(self.handle, path.ptr) != 0;
    }

    pub fn beginFrame(self: Context, clear_color: theme.Rgba) frame.FrameInfo {
        var width: f32 = 0;
        var height: f32 = 0;
        var density: f32 = 1;
        c.br_frame_begin(self.handle, toColor(clear_color), &width, &height, &density);
        return .{ .size = .{ .width = width, .height = height }, .density = density };
    }

    pub fn endFrame(self: Context) void {
        c.br_frame_end(self.handle);
    }

    pub fn fillRect(self: Context, rect: layout.Rect, color: theme.Rgba) void {
        c.br_fill_rect(self.handle, toRect(rect), toColor(color));
    }

    pub fn strokeRect(self: Context, rect: layout.Rect, color: theme.Rgba) void {
        c.br_stroke_rect(self.handle, toRect(rect), toColor(color));
    }

    pub fn setClip(self: Context, rect: ?layout.Rect) void {
        if (rect) |clip| {
            const native = toRect(clip);
            c.br_set_clip(self.handle, &native);
        } else {
            c.br_set_clip(self.handle, null);
        }
    }

    pub fn drawTexture(
        self: Context,
        texture: Texture,
        destination: layout.Rect,
        tint: theme.Rgba,
    ) void {
        c.br_draw_texture(self.handle, texture.handle, toRect(destination), toColor(tint));
    }

    pub fn drawTriangles(
        self: Context,
        vertices: []const layout.Vec2,
        indices: []const c_int,
        color: theme.Rgba,
    ) void {
        if (vertices.len == 0 or indices.len == 0) return;
        c.br_draw_triangles(
            self.handle,
            @ptrCast(vertices.ptr),
            vertices.len,
            indices.ptr,
            indices.len,
            toColor(color),
        );
    }

    pub fn createText(self: Context, text: [:0]const u8, size: u8, strong: bool) ?TextImage {
        var width: f32 = 0;
        var height: f32 = 0;
        const handle = c.br_create_text(
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
        return c.br_measure_text(self.handle, text.ptr, size, @intFromBool(strong));
    }

    pub fn createIcon(self: Context, icon: theme.Icon, color: theme.Rgba) ?Texture {
        const handle = c.br_create_icon(self.handle, @intFromEnum(icon), toColor(color)) orelse {
            return null;
        };
        return Texture.fromHandle(handle);
    }
};

pub const Document = struct {
    handle: *c.BR_Document,

    pub fn open(context: Context, allocator: std.mem.Allocator, raw_path: []const u8) !Document {
        const path_z = try allocator.dupeZ(u8, raw_path);
        defer allocator.free(path_z);
        const handle = c.br_pdf_open(context.handle, path_z.ptr) orelse return error.InvalidPdf;
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Document) void {
        c.br_pdf_close(self.handle);
        self.* = undefined;
    }

    pub fn pageCount(self: Document) usize {
        const page_count = c.br_pdf_page_count(self.handle);
        return if (page_count > 0) @intCast(page_count) else 0;
    }

    pub fn path(self: Document) []const u8 {
        return std.mem.span(c.br_pdf_path(self.handle));
    }

    pub fn pageSize(self: Document, page_index: usize) ?layout.Size {
        if (page_index > std.math.maxInt(c_int)) return null;
        var width: f32 = 0;
        var height: f32 = 0;
        const found = c.br_pdf_page_size(self.handle, @intCast(page_index), &width, &height);
        if (found == 0) return null;
        return .{ .width = width, .height = height };
    }

    /// Distinguishes document instances for caches; reopening a file yields
    /// a new identity so stale thumbnails are never shown.
    pub fn identity(self: Document) u64 {
        return @intFromPtr(self.handle);
    }

    pub fn render(
        self: Document,
        context: Context,
        page_index: usize,
        scale: f32,
        dark_mode: bool,
    ) !Texture {
        if (page_index > std.math.maxInt(c_int)) return error.PageRenderFailed;
        const handle = c.br_pdf_render(
            context.handle,
            self.handle,
            @intCast(page_index),
            scale,
            @intFromBool(dark_mode),
        ) orelse return error.PageRenderFailed;
        return Texture.fromHandle(handle);
    }
};

fn convertInput(allocator: std.mem.Allocator, native: c.BR_Input) input.RawInput {
    defer if (native.path != null) c.br_free(native.path);
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
            std.log.err("could not keep the dropped path", .{});
            return .{ .kind = .none };
        };
    }
    return raw;
}

fn toColor(color: theme.Rgba) c.BR_Color {
    return .{ .r = color.red, .g = color.green, .b = color.blue, .a = color.alpha };
}

fn toRect(rect: layout.Rect) c.BR_Rect {
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

comptime {
    checkNativeConstants(input.Kind, "BR_INPUT_");
    checkNativeConstants(input.Key, "BR_KEY_");
    checkNativeConstants(input.Button, "BR_BUTTON_");
    checkNativeConstants(theme.Icon, "BR_ICON_");
    if (@sizeOf(layout.Vec2) != @sizeOf(c.BR_Point) or
        @alignOf(layout.Vec2) != @alignOf(c.BR_Point))
    {
        @compileError("window point ABI does not match the native bridge");
    }
    if (theme.icon_size != c.BR_ICON_SIZE) {
        @compileError("icon size does not match the native bridge");
    }
}
