//! Headless workload for profilers.
//!
//! Drives the production application through the real native stack with
//! synthetic input, phase by phase, and prints how long each phase took. Run
//! it under `perf` to see where a real session spends its time: page turns
//! with worker renders, zoom bursts, long pen strokes, thumbnail scrolling,
//! theme toggles, resizes, and saves. Storage is a throwaway directory.

const std = @import("std");
const app = @import("app");

const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

/// SDL ends each poll cycle with a sentinel; a few rounds drain what was
/// queued before the call.
const drain_rounds = 4;
const left_button_mask: u32 = 1;
/// Positions a mouse typically delivers between two frames.
const motions_per_frame = 4;

const Driver = struct {
    allocator: std.mem.Allocator,
    context: *app.Context,
    renders: *app.RenderQueue,
    application: *app.Application,
    frames: usize = 0,

    fn pump(self: *Driver) void {
        var round: usize = 0;
        while (round < drain_rounds) : (round += 1) {
            self.application.step(self.context.pollInput(self.allocator));
        }
    }

    /// Waits for the render worker and delivers what it produced.
    fn settle(self: *Driver) void {
        self.renders.waitIdle();
        self.pump();
    }

    /// Waits until the deferred page render fired and landed.
    fn settleTimers(self: *Driver) void {
        while (self.application.render_timer != null) {
            c.SDL_Delay(5);
            self.pump();
        }
        self.settle();
    }

    fn pageRect(self: *Driver) app.ui.layout.Rect {
        const application = self.application;
        return application.layout.pageRect(application.page.size, application.reader.zoom());
    }

    fn pushKey(self: *Driver, scancode: c.SDL_Scancode, keycode: c.SDL_Keycode) void {
        var event = std.mem.zeroes(c.SDL_Event);
        event.type = c.SDL_EVENT_KEY_DOWN;
        event.key.windowID = self.context.windowId();
        event.key.scancode = scancode;
        event.key.key = keycode;
        _ = c.SDL_PushEvent(&event);
    }

    const MouseKind = enum { down, up, motion, hover };

    fn pushMouse(self: *Driver, kind: MouseKind, x: f32, y: f32) void {
        var event = std.mem.zeroes(c.SDL_Event);
        switch (kind) {
            .down, .up => {
                event.type = if (kind == .down)
                    c.SDL_EVENT_MOUSE_BUTTON_DOWN
                else
                    c.SDL_EVENT_MOUSE_BUTTON_UP;
                event.button.windowID = self.context.windowId();
                event.button.button = c.SDL_BUTTON_LEFT;
                event.button.x = x;
                event.button.y = y;
            },
            .motion, .hover => {
                event.type = c.SDL_EVENT_MOUSE_MOTION;
                event.motion.windowID = self.context.windowId();
                event.motion.state = if (kind == .motion) left_button_mask else 0;
                event.motion.x = x;
                event.motion.y = y;
            },
        }
        _ = c.SDL_PushEvent(&event);
    }

    fn pushWheel(self: *Driver, x: f32, y: f32, amount: f32) void {
        var event = std.mem.zeroes(c.SDL_Event);
        event.type = c.SDL_EVENT_MOUSE_WHEEL;
        event.wheel.windowID = self.context.windowId();
        event.wheel.mouse_x = x;
        event.wheel.mouse_y = y;
        event.wheel.y = amount;
        _ = c.SDL_PushEvent(&event);
    }
};

const Phase = struct {
    name: []const u8,
    iterations: usize,
    nanoseconds: i96,
};

fn now(io: std.Io) std.Io.Timestamp {
    return std.Io.Clock.awake.now(io);
}

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len != 2) {
        std.log.err("usage: lectern-profile PDF", .{});
        return error.InvalidArguments;
    }

    var context = try app.Context.init();
    defer context.deinit();
    var storage = app.Storage.openTemporary(init.io, init.gpa, .{
        .tmpdir = init.environ_map.get("TMPDIR"),
    });
    defer storage.deinit();
    var renders = app.RenderQueue.init(init.gpa, init.io);
    defer renders.deinit();
    var application = app.Application.init(init.gpa, &context, &storage, &renders);
    defer application.deinit();
    var driver = Driver{
        .allocator = init.gpa,
        .context = &context,
        .renders = &renders,
        .application = &application,
    };
    driver.pump();

    var phases: std.ArrayList(Phase) = .empty;
    defer phases.deinit(init.gpa);
    const io = init.io;

    var started = now(io);
    try application.openPdf(arguments[1]);
    driver.settle();
    try phases.append(init.gpa, .{
        .name = "open document",
        .iterations = 1,
        .nanoseconds = started.durationTo(now(io)).toNanoseconds(),
    });
    const page_count = application.reader.pageCount();

    // Page turns: every render lands before the next turn, like a reader
    // who looks at each page.
    started = now(io);
    const turns = 3 * page_count;
    var turn: usize = 0;
    while (turn < turns) : (turn += 1) {
        const forward = (turn / page_count) % 2 == 0;
        const scancode: c.SDL_Scancode = if (forward) c.SDL_SCANCODE_RIGHT else c.SDL_SCANCODE_LEFT;
        driver.pushKey(scancode, c.SDLK_UNKNOWN);
        driver.pump();
        driver.settle();
    }
    try phases.append(init.gpa, .{
        .name = "page turns",
        .iterations = turns,
        .nanoseconds = started.durationTo(now(io)).toNanoseconds(),
    });

    // Zoom bursts: fifteen steps in, the deferred render, fifteen out.
    started = now(io);
    var burst: usize = 0;
    while (burst < 4) : (burst += 1) {
        var step: usize = 0;
        while (step < 15) : (step += 1) {
            const keycode: c.SDL_Keycode = if (burst % 2 == 0) c.SDLK_PLUS else c.SDLK_MINUS;
            driver.pushKey(c.SDL_SCANCODE_UNKNOWN, keycode);
            driver.pump();
        }
        driver.settleTimers();
    }
    try phases.append(init.gpa, .{
        .name = "zoom bursts",
        .iterations = 4,
        .nanoseconds = started.durationTo(now(io)).toNanoseconds(),
    });

    // Pen strokes: long drags with a frame per motion event, then the save.
    driver.pushKey(c.SDL_SCANCODE_UNKNOWN, c.SDLK_P);
    driver.pump();
    started = now(io);
    const strokes = 24;
    const points_per_stroke = 200;
    var stroke: usize = 0;
    while (stroke < strokes) : (stroke += 1) {
        const rect = driver.pageRect();
        const y = rect.y + rect.h * (0.1 + 0.8 * @as(f32, @floatFromInt(stroke)) /
            @as(f32, @floatFromInt(strokes)));
        driver.pushMouse(.down, rect.x + rect.w * 0.1, y);
        driver.pump();
        // A mouse reports several positions per frame; the loop drains
        // them all before it repaints, so they are queued in small bursts.
        var point: usize = 1;
        while (point < points_per_stroke) : (point += 1) {
            const progress = @as(f32, @floatFromInt(point)) /
                @as(f32, @floatFromInt(points_per_stroke));
            const x = rect.x + rect.w * (0.1 + 0.8 * progress);
            driver.pushMouse(.motion, x, y + 6 * @sin(progress * 40));
            if (point % motions_per_frame == 0) driver.pump();
        }
        driver.pushMouse(.up, rect.x + rect.w * 0.9, y);
        driver.pump();
    }
    application.flushState();
    try phases.append(init.gpa, .{
        .name = "pen strokes",
        .iterations = strokes * points_per_stroke,
        .nanoseconds = started.durationTo(now(io)).toNanoseconds(),
    });

    // Thumbnail scrolling: every wheel step repaints the rail and renders
    // the pages that came into view.
    driver.pushKey(c.SDL_SCANCODE_UNKNOWN, c.SDLK_N);
    driver.pump();
    started = now(io);
    const scrolls = 60;
    var scroll: usize = 0;
    while (scroll < scrolls) : (scroll += 1) {
        const direction: f32 = if (scroll < scrolls / 2) -1 else 1;
        driver.pushWheel(40, 400, direction);
        driver.pump();
        driver.settle();
    }
    try phases.append(init.gpa, .{
        .name = "thumbnail scroll",
        .iterations = scrolls,
        .nanoseconds = started.durationTo(now(io)).toNanoseconds(),
    });

    // Theme toggles re-render the page and every thumbnail.
    started = now(io);
    var toggle: usize = 0;
    while (toggle < 6) : (toggle += 1) {
        driver.pushKey(c.SDL_SCANCODE_UNKNOWN, c.SDLK_D);
        driver.pump();
        driver.settle();
    }
    try phases.append(init.gpa, .{
        .name = "theme toggles",
        .iterations = 6,
        .nanoseconds = started.durationTo(now(io)).toNanoseconds(),
    });

    // Resizes: a drag that grows and shrinks the window, then the settle.
    started = now(io);
    var resize: usize = 0;
    while (resize < 20) : (resize += 1) {
        const height: u32 = 700 + 20 * @as(u32, @intCast(resize % 10));
        _ = context.setWindowSize(1100 + 10 * @as(u32, @intCast(resize)), height);
        driver.pump();
    }
    driver.settleTimers();
    try phases.append(init.gpa, .{
        .name = "resizes",
        .iterations = 20,
        .nanoseconds = started.durationTo(now(io)).toNanoseconds(),
    });

    // Hover sweep across the toolbar: repaints only when the control changes.
    started = now(io);
    const sweeps = 400;
    var sweep: usize = 0;
    while (sweep < sweeps) : (sweep += 1) {
        const x: f32 = @floatFromInt(100 + (sweep * 7) % 1000);
        driver.pushMouse(.hover, x, 30);
        driver.pump();
    }
    try phases.append(init.gpa, .{
        .name = "hover sweep",
        .iterations = sweeps,
        .nanoseconds = started.durationTo(now(io)).toNanoseconds(),
    });

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout.interface;
    try out.print("{s:<18} {s:>10} {s:>12} {s:>12}\n", .{
        "phase",
        "iterations",
        "total ms",
        "per item ms",
    });
    for (phases.items) |phase| {
        const total_ms = @as(f64, @floatFromInt(phase.nanoseconds)) / 1e6;
        try out.print("{s:<18} {d:>10} {d:>12.1} {d:>12.3}\n", .{
            phase.name,
            phase.iterations,
            total_ms,
            total_ms / @as(f64, @floatFromInt(phase.iterations)),
        });
    }
    try out.flush();
}
