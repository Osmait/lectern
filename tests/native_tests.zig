//! Native contract tests. These run with SDL's dummy video backend in CI and
//! exercise only what genuinely crosses the operating-system boundary: raw
//! input, PDF rasterization, text and icon rasterization, and the frame
//! pipeline. Screenshots of every surface are written for manual review.

const std = @import("std");
const book_read = @import("book_read");
const app = @import("app");
const platform = app.platform;
const ui = app.ui;
const annotations = book_read.annotations;

const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
});

const screenshot_directory = ".zig-cache/screenshots";

fn drainInput(context: platform.Context) void {
    while (context.pollInput(std.testing.allocator)) |raw| {
        if (raw.path) |path| std.testing.allocator.free(path);
    }
}

/// SDL ends every poll cycle with a sentinel, so an event pushed after the
/// sentinel surfaces on the following poll. The application loop polls again
/// on its next iteration; tests retry explicitly.
fn nextInput(context: platform.Context) ?ui.input.RawInput {
    var attempts: usize = 0;
    while (attempts < 4) : (attempts += 1) {
        if (context.pollInput(std.testing.allocator)) |raw| return raw;
    }
    return null;
}

fn pushKey(scancode: c.SDL_Scancode, keycode: c.SDL_Keycode) !void {
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.scancode = scancode;
    event.key.key = keycode;
    try std.testing.expect(c.SDL_PushEvent(&event));
}

test "native input crosses the bridge as typed raw events" {
    var context = try platform.Context.init();
    defer context.deinit();
    drainInput(context);

    try pushKey(c.SDL_SCANCODE_UNKNOWN, c.SDLK_P);
    try pushKey(c.SDL_SCANCODE_RIGHT, c.SDLK_UNKNOWN);
    try pushKey(c.SDL_SCANCODE_UNKNOWN, c.SDLK_F12);
    const pen = nextInput(context) orelse return error.ExpectedInput;
    try std.testing.expectEqual(ui.input.Kind.key_down, pen.kind);
    try std.testing.expectEqual(ui.input.Key.p, pen.key);
    const right = nextInput(context) orelse return error.ExpectedInput;
    try std.testing.expectEqual(ui.input.Key.right, right.key);
    const unknown = nextInput(context) orelse return error.ExpectedInput;
    try std.testing.expectEqual(ui.input.Key.none, unknown.key);

    var click = std.mem.zeroes(c.SDL_Event);
    click.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
    click.button.windowID = context.windowId();
    click.button.button = c.SDL_BUTTON_LEFT;
    click.button.x = 550;
    click.button.y = 438;
    try std.testing.expect(c.SDL_PushEvent(&click));
    const press = nextInput(context) orelse return error.ExpectedInput;
    try std.testing.expectEqual(ui.input.Kind.mouse_down, press.kind);
    try std.testing.expectEqual(ui.input.Button.left, press.button);
    try std.testing.expectEqual(@as(f32, 550), press.position.x);
    try std.testing.expectEqual(@as(f32, 438), press.position.y);

    var wheel = std.mem.zeroes(c.SDL_Event);
    wheel.type = c.SDL_EVENT_MOUSE_WHEEL;
    wheel.wheel.windowID = context.windowId();
    wheel.wheel.y = 1;
    wheel.wheel.direction = c.SDL_MOUSEWHEEL_FLIPPED;
    wheel.wheel.mouse_x = 40;
    wheel.wheel.mouse_y = 300;
    try std.testing.expect(c.SDL_PushEvent(&wheel));
    const scroll = nextInput(context) orelse return error.ExpectedInput;
    try std.testing.expectEqual(ui.input.Kind.mouse_wheel, scroll.kind);
    try std.testing.expectEqual(@as(f32, -1), scroll.wheel);
    try std.testing.expectEqual(@as(f32, 40), scroll.position.x);

    var dropped = std.mem.zeroes(c.SDL_Event);
    dropped.type = c.SDL_EVENT_USER;
    dropped.user.data1 = c.strdup("chosen-book.pdf");
    try std.testing.expect(c.SDL_PushEvent(&dropped));
    const chosen = nextInput(context) orelse return error.ExpectedInput;
    defer if (chosen.path) |path| std.testing.allocator.free(path);
    try std.testing.expectEqual(ui.input.Kind.file, chosen.kind);
    try std.testing.expectEqualStrings("chosen-book.pdf", chosen.path.?);

    var cancelled = std.mem.zeroes(c.SDL_Event);
    cancelled.type = c.SDL_EVENT_USER;
    try std.testing.expect(c.SDL_PushEvent(&cancelled));
    const closed = nextInput(context) orelse return error.ExpectedInput;
    try std.testing.expectEqual(ui.input.Kind.dialog_closed, closed.kind);

    try std.testing.expectEqual(@as(?ui.input.RawInput, null), context.waitInput(
        std.testing.allocator,
        1,
    ));
    try std.testing.expect(context.ticksMs() > 0);
}

test "native documents open, measure, render at any scale, and reject bad pages" {
    var context = try platform.Context.init();
    defer context.deinit();
    var document = try platform.Document.open(
        context,
        std.testing.allocator,
        "tests/fixtures/research-methods.pdf",
    );
    defer document.deinit();
    try std.testing.expectEqual(@as(usize, 1), document.pageCount());
    try std.testing.expect(std.mem.endsWith(u8, document.path(), "research-methods.pdf"));
    try std.testing.expect(document.identity() != 0);

    const size = document.pageSize(0) orelse return error.ExpectedPageSize;
    try std.testing.expect(size.width > 100 and size.height > 100);
    try std.testing.expectEqual(@as(?ui.layout.Size, null), document.pageSize(1));

    var texture = try document.render(context, 0, 1.0, false);
    defer texture.deinit();
    try std.testing.expectApproxEqAbs(size.width, @as(f32, @floatFromInt(texture.width)), 1.0);
    var small = try document.render(context, 0, 0.25, true);
    defer small.deinit();
    try std.testing.expectApproxEqAbs(size.width / 4, @as(f32, @floatFromInt(small.width)), 1.0);

    try std.testing.expectError(error.PageRenderFailed, document.render(context, 1, 1.0, false));
    try std.testing.expect(context.lastError().len > 0);
    try std.testing.expectError(error.PageRenderFailed, document.render(context, 0, 100.0, false));

    try std.testing.expectError(error.InvalidPdf, platform.Document.open(
        context,
        std.testing.allocator,
        "/definitely/missing/book-read-test.pdf",
    ));
    try std.testing.expect(context.lastError().len > 0);
    try std.testing.expectError(error.InvalidPdf, platform.Document.open(
        context,
        std.testing.allocator,
        "tests/fixtures/style-invalid.txt",
    ));
}

test "native text and icons rasterize with logical metrics" {
    var context = try platform.Context.init();
    defer context.deinit();

    var text = context.createText("Research Methods", 15, true) orelse return error.ExpectedText;
    defer text.texture.deinit();
    try std.testing.expect(text.width > 40 and text.height > 10);
    try std.testing.expectApproxEqAbs(
        text.width,
        context.measureText("Research Methods", 15, true),
        0.01,
    );
    try std.testing.expect(context.measureText("Research", 15, true) < text.width);
    try std.testing.expect(text.texture.width >= @as(u32, @intFromFloat(text.width)));

    const accent = ui.theme.Palette.forMode(false).accent;
    var icon = context.createIcon(.pen, accent) orelse return error.ExpectedIcon;
    defer icon.deinit();
    try std.testing.expectEqual(@as(u32, 40), icon.width);
    try std.testing.expectEqual(@as(u32, 40), icon.height);
}

const Screenshot = struct {
    name: [:0]const u8,
    window: struct { width: u32, height: u32 },
    dark_mode: bool,
    tool: annotations.Tool,
    navigation_visible: bool,
    page_index: usize,
};

const screenshots = [_]Screenshot{
    .{
        .name = "ui-preview",
        .window = .{ .width = 1536, .height = 1024 },
        .dark_mode = false,
        .tool = .pen,
        .navigation_visible = true,
        .page_index = 0,
    },
    .{
        .name = "desktop",
        .window = .{ .width = 1440, .height = 960 },
        .dark_mode = false,
        .tool = .pen,
        .navigation_visible = true,
        .page_index = 0,
    },
    .{
        .name = "compact",
        .window = .{ .width = 900, .height = 700 },
        .dark_mode = false,
        .tool = .pen,
        .navigation_visible = true,
        .page_index = 0,
    },
    .{
        .name = "navigation",
        .window = .{ .width = 1100, .height = 820 },
        .dark_mode = false,
        .tool = .off,
        .navigation_visible = true,
        .page_index = 0,
    },
    .{
        .name = "navigation-dark",
        .window = .{ .width = 1100, .height = 820 },
        .dark_mode = true,
        .tool = .off,
        .navigation_visible = true,
        .page_index = 5,
    },
    .{
        .name = "navigation-hidden",
        .window = .{ .width = 1100, .height = 820 },
        .dark_mode = true,
        .tool = .off,
        .navigation_visible = false,
        .page_index = 0,
    },
};

test "the desktop renderer paints every surface through the native bridge" {
    var context = try platform.Context.init();
    defer context.deinit();
    var document = try platform.Document.open(
        context,
        std.testing.allocator,
        "tests/fixtures/research-methods-eight.pdf",
    );
    defer document.deinit();
    try std.testing.expectEqual(@as(usize, 8), document.pageCount());

    var notebook = annotations.Notebook.init(std.testing.allocator);
    defer notebook.deinit();
    try notebook.open(8);
    notebook.selectPen();
    _ = try notebook.beginStroke(0, .{ .x = 0.17, .y = 0.57 });
    _ = try notebook.appendPoint(.{ .x = 0.72, .y = 0.57 });
    _ = try notebook.finishStroke();
    notebook.selectColor(.black);
    notebook.selectPenSize(.thick);
    _ = try notebook.beginStroke(0, .{ .x = 0.17, .y = 0.62 });
    _ = try notebook.appendPoint(.{ .x = 0.30, .y = 0.60 });
    _ = try notebook.appendPoint(.{ .x = 0.48, .y = 0.63 });
    _ = try notebook.finishStroke();
    notebook.selectColor(.blue);
    notebook.selectPenSize(.medium);

    var renderer = ui.Renderer(platform).init(std.testing.allocator);
    defer renderer.deinit();
    std.Io.Dir.cwd().createDirPath(std.testing.io, screenshot_directory) catch {};

    for (screenshots) |shot| {
        try std.testing.expect(context.setWindowSize(shot.window.width, shot.window.height));
        notebook.tool = shot.tool;
        const palette = ui.theme.Palette.forMode(shot.dark_mode);
        const info = context.beginFrame(palette.background);
        const layout = ui.Layout.compute(info.size, .{
            .document_open = true,
            .navigation_visible = shot.navigation_visible,
            .annotations_enabled = shot.tool != .off,
        });
        const page_size = document.pageSize(shot.page_index) orelse return error.ExpectedPageSize;
        const page_rect = layout.pageRect(page_size, 1.0);
        const scale = layout.pageDisplayScale(page_size, 1.0) * info.density;
        var page = try document.render(context, shot.page_index, scale, shot.dark_mode);
        defer page.deinit();

        const frame = ui.Frame{
            .dark_mode = shot.dark_mode,
            .document_open = true,
            .page_index = shot.page_index,
            .page_count = 8,
            .zoom_percent = 100,
            .bookmarked = shot.page_index == 0,
            .title = "Research Methods.pdf",
            .navigation_visible = shot.navigation_visible,
            .thumbnail_scroll = layout.revealThumbnail(0, shot.page_index, 8),
            .tool = shot.tool,
            .color = .blue,
            .pen_size = .medium,
            .save_status = .saved,
            .mouse = .{ .x = layout.toolbar.next.centerX(), .y = layout.toolbar.next.centerY() },
            .page_rect = page_rect,
        };
        var report = renderer.draw(context, frame, layout, page, &notebook, document, info.density);
        var extra_frames: usize = 0;
        while (report.pending_thumbnails and extra_frames < 8) : (extra_frames += 1) {
            report = renderer.draw(context, frame, layout, page, &notebook, document, info.density);
        }
        try std.testing.expect(!report.pending_thumbnails);

        var path_buffer: [128]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buffer, "{s}/{s}.bmp", .{
            screenshot_directory,
            shot.name,
        });
        try std.testing.expect(context.saveScreenshot(path));
        context.endFrame();
    }
    try std.testing.expect(renderer.thumbnails.liveCount() > 0);
}
