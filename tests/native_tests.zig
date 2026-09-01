//! Native contract tests. These run with SDL's dummy video backend in CI and
//! exercise only what genuinely crosses the operating-system boundary: raw
//! input, PDF rasterization on the worker thread, text and icon
//! rasterization, and the frame pipeline. Screenshots of every surface are
//! written for manual review.

const std = @import("std");
const book_read = @import("book_read");
const app = @import("app");
const build_options = @import("build_options");
const platform = app.platform;
const ui = app.ui;
const annotations = book_read.annotations;

const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("cairo/cairo.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
});

const screenshot_directory = ".zig-cache/screenshots";
const golden_directory = "tests/golden";
/// Screenshots are compared at a quarter of their size, so font hinting
/// differences average away while layout and color regressions remain.
const golden_scale: usize = 4;
/// Largest allowed difference of one channel of one reduced pixel.
const golden_pixel_tolerance: u32 = 32;
/// Largest allowed mean difference over the whole image.
const golden_mean_tolerance: f64 = 1.5;

/// Compares a saved screenshot with its reference image, or rewrites the
/// reference when the build was configured with `-Dupdate-golden`.
fn checkGolden(name: [:0]const u8, screenshot_path: [:0]const u8) !void {
    const loaded = c.SDL_LoadBMP(screenshot_path.ptr) orelse return error.ScreenshotUnreadable;
    defer c.SDL_DestroySurface(loaded);
    const surface = c.SDL_ConvertSurface(loaded, c.SDL_PIXELFORMAT_ARGB8888) orelse {
        return error.ScreenshotUnreadable;
    };
    defer c.SDL_DestroySurface(surface);
    const width: usize = @intCast(surface.*.w);
    const height: usize = @intCast(surface.*.h);
    const pitch: usize = @intCast(surface.*.pitch);
    const pixels: [*]const u8 = @ptrCast(surface.*.pixels orelse return error.ScreenshotUnreadable);

    const small_width = width / golden_scale;
    const small_height = height / golden_scale;
    const small = c.cairo_image_surface_create(
        c.CAIRO_FORMAT_RGB24,
        @intCast(small_width),
        @intCast(small_height),
    );
    defer c.cairo_surface_destroy(small);
    c.cairo_surface_flush(small);
    const stride: usize = @intCast(c.cairo_image_surface_get_stride(small));
    const data: [*]u8 = c.cairo_image_surface_get_data(small);
    const block_pixels: u32 = golden_scale * golden_scale;
    var y: usize = 0;
    while (y < small_height) : (y += 1) {
        var x: usize = 0;
        while (x < small_width) : (x += 1) {
            var sums = [3]u32{ 0, 0, 0 };
            var dy: usize = 0;
            while (dy < golden_scale) : (dy += 1) {
                var dx: usize = 0;
                while (dx < golden_scale) : (dx += 1) {
                    const offset = (y * golden_scale + dy) * pitch + (x * golden_scale + dx) * 4;
                    sums[0] += pixels[offset];
                    sums[1] += pixels[offset + 1];
                    sums[2] += pixels[offset + 2];
                }
            }
            const target = y * stride + x * 4;
            data[target] = @intCast(sums[0] / block_pixels);
            data[target + 1] = @intCast(sums[1] / block_pixels);
            data[target + 2] = @intCast(sums[2] / block_pixels);
            data[target + 3] = 255;
        }
    }
    c.cairo_surface_mark_dirty(small);

    var path_buffer: [128]u8 = undefined;
    const golden_path = try std.fmt.bufPrintZ(&path_buffer, "{s}/{s}.png", .{
        golden_directory,
        name,
    });
    if (build_options.update_golden) {
        std.Io.Dir.cwd().createDirPath(std.testing.io, golden_directory) catch {};
        const written = c.cairo_surface_write_to_png(small, golden_path.ptr);
        try std.testing.expect(written == c.CAIRO_STATUS_SUCCESS);
        return;
    }

    const golden = c.cairo_image_surface_create_from_png(golden_path.ptr);
    defer c.cairo_surface_destroy(golden);
    if (c.cairo_surface_status(golden) != c.CAIRO_STATUS_SUCCESS) {
        std.debug.print(
            "\nno reference screenshot {s}; create it with zig build test:native -Dupdate-golden\n",
            .{golden_path},
        );
        return error.GoldenMissing;
    }
    const golden_width: usize = @intCast(c.cairo_image_surface_get_width(golden));
    const golden_height: usize = @intCast(c.cairo_image_surface_get_height(golden));
    if (golden_width != small_width or golden_height != small_height) {
        std.debug.print("\nreference {s} is {d}x{d}, screenshot reduces to {d}x{d}\n", .{
            golden_path,
            golden_width,
            golden_height,
            small_width,
            small_height,
        });
        return error.GoldenSizeMismatch;
    }
    c.cairo_surface_flush(golden);
    const golden_stride: usize = @intCast(c.cairo_image_surface_get_stride(golden));
    const golden_data: [*]const u8 = c.cairo_image_surface_get_data(golden);
    var worst: u32 = 0;
    var total: u64 = 0;
    y = 0;
    while (y < small_height) : (y += 1) {
        var x: usize = 0;
        while (x < small_width) : (x += 1) {
            var channel: usize = 0;
            while (channel < 3) : (channel += 1) {
                const ours: i32 = data[y * stride + x * 4 + channel];
                const theirs: i32 = golden_data[y * golden_stride + x * 4 + channel];
                const difference: u32 = @intCast(@abs(ours - theirs));
                worst = @max(worst, difference);
                total += difference;
            }
        }
    }
    const mean = @as(f64, @floatFromInt(total)) /
        @as(f64, @floatFromInt(small_width * small_height * 3));
    if (worst > golden_pixel_tolerance or mean > golden_mean_tolerance) {
        std.debug.print(
            "\n{s} differs from its reference: worst channel difference {d}, mean {d:.2}; " ++
                "inspect {s} and, if the change is intended, run " ++
                "zig build test:native -Dupdate-golden\n",
            .{ name, worst, mean, screenshot_path },
        );
        return error.ScreenshotDiffers;
    }
}

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

    var left = std.mem.zeroes(c.SDL_Event);
    left.type = c.SDL_EVENT_WINDOW_MOUSE_LEAVE;
    left.window.windowID = context.windowId();
    try std.testing.expect(c.SDL_PushEvent(&left));
    const gone = nextInput(context) orelse return error.ExpectedInput;
    try std.testing.expectEqual(ui.input.Kind.mouse_leave, gone.kind);

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

    // Reopening yields a new identity even though the file is the same.
    var again = try platform.Document.open(
        context,
        std.testing.allocator,
        "tests/fixtures/research-methods.pdf",
    );
    defer again.deinit();
    try std.testing.expect(again.identity() != document.identity());

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

test "the native render queue rasterizes on a worker and wakes the main thread" {
    var context = try platform.Context.init();
    defer context.deinit();
    drainInput(context);
    var document = try platform.Document.open(
        context,
        std.testing.allocator,
        "tests/fixtures/research-methods-eight.pdf",
    );
    defer document.deinit();
    var queue = platform.RenderQueue.init(std.testing.allocator, std.testing.io);
    defer queue.deinit();

    const job = platform.RenderQueue.Job{
        .document = document,
        .generation = 1,
        .page_index = 0,
        .scale = 0.5,
        .dark_mode = false,
        .purpose = .page,
        .priority = .immediate,
    };
    const first = try queue.submit(job);
    var invalid = job;
    invalid.page_index = 99;
    invalid.priority = .prefetch;
    const second = try queue.submit(invalid);
    queue.waitIdle();
    try std.testing.expect(queue.isIdle());
    try std.testing.expectEqual(@as(usize, 0), queue.synchronous_render_count);

    // The worker ended the wait with a render notification.
    var woke = false;
    var attempts: usize = 0;
    while (attempts < 8 and !woke) : (attempts += 1) {
        const raw = context.waitInput(std.testing.allocator, 100) orelse continue;
        if (raw.path) |path| std.testing.allocator.free(path);
        woke = raw.kind == .render_ready;
    }
    try std.testing.expect(woke);

    var delivered: usize = 0;
    var failed: usize = 0;
    while (queue.poll(context, 1)) |result| {
        delivered += 1;
        if (result.texture) |texture| {
            try std.testing.expectEqual(first, result.job.id);
            var owned = texture;
            defer owned.deinit();
            const size = document.pageSize(0).?;
            try std.testing.expectApproxEqAbs(
                size.width / 2,
                @as(f32, @floatFromInt(owned.width)),
                1.0,
            );
        } else {
            try std.testing.expectEqual(second, result.job.id);
            failed += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), delivered);
    try std.testing.expectEqual(@as(usize, 1), failed);

    // A result of another generation is released without a texture, and a
    // finished job can no longer be cancelled.
    _ = try queue.submit(job);
    queue.waitIdle();
    try std.testing.expect(!queue.cancel(first));
    try std.testing.expectEqual(@as(?platform.RenderQueue.Result, null), queue.poll(context, 2));
    drainInput(context);
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
        .name = "minimum",
        .window = .{ .width = 900, .height = 600 },
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
    var queue = platform.RenderQueue.init(std.testing.allocator, std.testing.io);
    defer queue.deinit();

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
            .density = info.density,
            .document_identity = document.identity(),
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
            .hover = layout.hoverAt(.{
                .x = layout.toolbar.next.centerX(),
                .y = layout.toolbar.next.centerY(),
            }, true, 0, 8),
            .page_rect = page_rect,
            .strokes = notebook.strokesOn(shot.page_index),
            .strokes_revision = notebook.revision,
        };
        if (shot.navigation_visible) {
            try renderer.thumbnails.prepare(
                &queue,
                document.identity(),
                8,
                shot.dark_mode,
                info.density,
            );
        }
        var report = renderer.draw(context, frame, layout, page);
        if (shot.navigation_visible) {
            const has_thumbnails = renderer.thumbnails.liveCount() > 0;
            try std.testing.expect(report.missing_thumbnails or has_thumbnails);
            renderer.thumbnails.requestVisible(
                &queue,
                document,
                1,
                report.visible_thumbnails,
                shot.dark_mode,
                info.density,
            );
            queue.waitIdle();
            while (queue.poll(context, 1)) |result| {
                renderer.thumbnails.complete(result.job.id, result.job.page_index, result.texture);
            }
            report = renderer.draw(context, frame, layout, page);
            try std.testing.expect(!report.missing_thumbnails);
        }

        var path_buffer: [128]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buffer, "{s}/{s}.bmp", .{
            screenshot_directory,
            shot.name,
        });
        try std.testing.expect(context.saveScreenshot(path));
        context.endFrame();
        try checkGolden(shot.name, path);
    }
    try std.testing.expect(renderer.thumbnails.liveCount() > 0);
    drainInput(context);
}
