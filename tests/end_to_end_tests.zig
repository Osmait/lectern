//! End-to-end tests: the production application on the real native stack.
//!
//! SDL's dummy video driver provides the window, Poppler and Cairo rasterize
//! the fixtures, the render worker and the storage thread run for real, and
//! files land in a temporary directory. Input arrives as synthetic native
//! events, so the whole path from an event to pixels and to disk is
//! exercised without a display.

const std = @import("std");
const book_read = @import("book_read");
const app = @import("app");
const annotations = book_read.annotations;
const DocumentKey = app.storage.DocumentKey;

const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("string.h");
});

const fixture = "tests/fixtures/research-methods-eight.pdf";
/// SDL ends each poll cycle with a sentinel, so a few rounds are needed to
/// drain everything that was queued before the call.
const drain_rounds = 4;
/// The left mouse button is bit zero of the motion state.
const left_button_mask: u32 = 1;

const Harness = struct {
    tmp: std.testing.TmpDir,
    context: app.Context,
    storage: app.Storage,
    renders: app.RenderQueue,
    application: app.Application,
    released: bool,

    fn init(self: *Harness) !void {
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.context = try app.Context.init();
        errdefer self.context.deinit();
        self.storage = app.Storage.fromDir(std.testing.io, std.testing.allocator, self.tmp.dir);
        self.renders = app.RenderQueue.init(std.testing.allocator, std.testing.io);
        self.application = app.Application.init(
            std.testing.allocator,
            &self.context,
            &self.storage,
            &self.renders,
        );
        self.released = false;
        self.drain();
    }

    fn deinit(self: *Harness) void {
        if (self.released) return;
        self.released = true;
        self.application.deinit();
        self.renders.deinit();
        self.storage.deinit();
        self.context.deinit();
        self.tmp.cleanup();
    }

    /// Drops what the window queued on its own, like the initial exposure.
    fn drain(self: *Harness) void {
        var round: usize = 0;
        while (round < drain_rounds) : (round += 1) {
            while (self.context.pollInput(std.testing.allocator)) |raw| {
                if (raw.path) |path| std.testing.allocator.free(path);
            }
        }
    }

    /// Feeds every queued native event to the application, exactly as the
    /// frame loop does between waits.
    fn pump(self: *Harness) void {
        var round: usize = 0;
        while (round < drain_rounds) : (round += 1) {
            self.application.step(self.context.pollInput(std.testing.allocator));
        }
    }

    /// Waits for the render worker and delivers what it produced.
    fn settle(self: *Harness) void {
        self.renders.waitIdle();
        self.pump();
    }

    fn pageRect(self: *Harness) app.ui.layout.Rect {
        const application = &self.application;
        return application.layout.pageRect(application.page.size, application.reader.zoom());
    }

    fn pushKey(self: *Harness, scancode: c.SDL_Scancode, keycode: c.SDL_Keycode) !void {
        var event = std.mem.zeroes(c.SDL_Event);
        event.type = c.SDL_EVENT_KEY_DOWN;
        event.key.windowID = self.context.windowId();
        event.key.scancode = scancode;
        event.key.key = keycode;
        try std.testing.expect(c.SDL_PushEvent(&event));
    }

    const MouseKind = enum { down, up, motion };

    fn pushMouse(self: *Harness, kind: MouseKind, x: f32, y: f32) !void {
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
            .motion => {
                event.type = c.SDL_EVENT_MOUSE_MOTION;
                event.motion.windowID = self.context.windowId();
                event.motion.state = left_button_mask;
                event.motion.x = x;
                event.motion.y = y;
            },
        }
        try std.testing.expect(c.SDL_PushEvent(&event));
    }

    /// The file dialog delivers its choice through the same event.
    fn pushChosenFile(self: *Harness, path: [:0]const u8) !void {
        _ = self;
        var event = std.mem.zeroes(c.SDL_Event);
        event.type = c.SDL_EVENT_USER;
        event.user.data1 = c.strdup(path.ptr);
        try std.testing.expect(c.SDL_PushEvent(&event));
    }

    fn pushQuit(self: *Harness) !void {
        _ = self;
        var event = std.mem.zeroes(c.SDL_Event);
        event.type = c.SDL_EVENT_QUIT;
        try std.testing.expect(c.SDL_PushEvent(&event));
    }

    /// Draws a short stroke across the page with the pen held down.
    fn drawStroke(self: *Harness) !void {
        const rect = self.pageRect();
        const x = rect.centerX();
        const y = rect.centerY();
        try self.pushMouse(.down, x, y);
        try self.pushMouse(.motion, x + 40, y + 10);
        try self.pushMouse(.motion, x + 80, y + 20);
        try self.pushMouse(.up, x + 80, y + 20);
    }

    fn readNotes(self: *Harness, notebook: *annotations.Notebook) !annotations.Restored {
        const document = self.application.document orelse return error.NoDocument;
        var name_buffer: [app.storage.name_capacity]u8 = undefined;
        const name = DocumentKey.of(document.path()).notesName(&name_buffer);
        const data = (try self.storage.read(std.testing.allocator, name)) orelse {
            return error.NotesNotWritten;
        };
        defer std.testing.allocator.free(data);
        return notebook.restore(data);
    }

    fn readProgress(self: *Harness) ![]u8 {
        const document = self.application.document orelse return error.NoDocument;
        var name_buffer: [app.storage.name_capacity]u8 = undefined;
        const name = DocumentKey.of(document.path()).progressName(&name_buffer);
        return (try self.storage.read(std.testing.allocator, name)) orelse error.ProgressNotWritten;
    }
};

test "a reading session: open, annotate, turn pages, persist, and reopen" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    const application = &harness.application;

    try harness.pushChosenFile(fixture);
    harness.pump();
    const document = application.document orelse return error.DocumentNotOpened;
    try std.testing.expectEqual(@as(usize, 8), document.pageCount());
    try std.testing.expect(application.page.texture != null);
    try std.testing.expect(!application.dialog_open);

    // The pen opens the annotation margin and a drag records a stroke.
    try harness.pushKey(c.SDL_SCANCODE_UNKNOWN, c.SDLK_P);
    harness.pump();
    try std.testing.expectEqual(annotations.Tool.pen, application.notebook.tool);
    try std.testing.expect(application.layout.panel != null);
    try harness.drawStroke();
    harness.pump();
    try std.testing.expectEqual(@as(usize, 1), application.notebook.strokeCount());
    try std.testing.expect(application.notebook.strokesOn(0)[0].points.len >= 3);
    try std.testing.expect(application.notes.dirty);
    try std.testing.expectEqual(app.ui.frame.SaveStatus.pending, application.save_status);

    // Turning the page renders on the worker; the rail fills in behind it.
    try harness.pushKey(c.SDL_SCANCODE_RIGHT, c.SDLK_UNKNOWN);
    harness.pump();
    try std.testing.expectEqual(@as(usize, 1), application.reader.page_index);
    harness.settle();
    try std.testing.expect(application.page.texture != null);
    try std.testing.expectEqual(@as(usize, 1), application.page.page_index);
    try std.testing.expect(application.renderer.thumbnails.liveCount() > 0);
    try std.testing.expect(application.pages.count() > 0);

    // Dragging the rail scrollbar with the mouse scrolls the page list.
    const bar = application.layout.thumbnailScrollbar(application.thumbnail_scroll, 8) orelse {
        return error.ExpectedScrollbar;
    };
    const thumb_x = application.layout.navigation_width - 5;
    try harness.pushMouse(.down, thumb_x, bar.thumb.y + 6);
    try harness.pushMouse(.motion, thumb_x + 30, bar.thumb.y + 6 + 120);
    try harness.pushMouse(.up, thumb_x + 30, bar.thumb.y + 6 + 120);
    harness.pump();
    try std.testing.expect(application.thumbnail_scroll > 0);
    try std.testing.expectEqual(@as(?f32, null), application.scrollbar_grab);
    try std.testing.expectEqual(@as(usize, 1), application.notebook.strokeCount());
    harness.settle();

    try harness.pushKey(c.SDL_SCANCODE_UNKNOWN, c.SDLK_B);
    try harness.pushKey(c.SDL_SCANCODE_UNKNOWN, c.SDLK_D);
    harness.pump();
    try std.testing.expect(application.reader.isCurrentPageBookmarked());
    try std.testing.expect(!application.preferences.dark_mode);
    harness.settle();
    try std.testing.expect(!application.page.dark_mode);

    // Everything reaches the temporary state directory through the storage
    // thread, in the formats the next session reads.
    application.flushState();
    try std.testing.expectEqual(app.ui.frame.SaveStatus.saved, application.save_status);
    var restored = annotations.Notebook.init(std.testing.allocator);
    defer restored.deinit();
    try restored.open(8);
    const notes = try harness.readNotes(&restored);
    try std.testing.expectEqual(@as(usize, 1), notes.restored);
    try std.testing.expectEqual(@as(usize, 1), restored.strokesOn(0).len);
    const progress = try harness.readProgress();
    defer std.testing.allocator.free(progress);
    try std.testing.expectEqualStrings("page 1\nbookmark 1\n", progress);
    const preferences = (try harness.storage.read(
        std.testing.allocator,
        app.storage.preferences_name,
    )) orelse return error.PreferencesNotWritten;
    defer std.testing.allocator.free(preferences);
    try std.testing.expectEqualStrings("dark 0\n", preferences);

    // Choosing the same file again restores the session.
    try harness.pushChosenFile(fixture);
    harness.pump();
    try std.testing.expectEqual(@as(usize, 1), application.reader.page_index);
    try std.testing.expect(application.reader.isCurrentPageBookmarked());
    try std.testing.expectEqual(@as(usize, 1), application.notebook.strokeCount());
    try std.testing.expectEqual(annotations.Tool.pen, application.notebook.tool);
    harness.settle();
    try std.testing.expect(application.page.texture != null);
}

test "the production loop runs a queued session to completion and exits on quit" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    // The click must land on the page once the pen margin is open, so the
    // page rectangle is computed for that layout from the fixture's size.
    var probe = try app.Document.open(harness.context, std.testing.allocator, fixture);
    defer probe.deinit();
    const page_size = probe.pageSize(0) orelse return error.ExpectedPageSize;
    const layout = app.ui.Layout.compute(harness.context.windowSize(), .{
        .document_open = true,
        .navigation_visible = true,
        .annotations_enabled = true,
    });
    const page_rect = layout.pageRect(page_size, 1.0);

    try harness.pushKey(c.SDL_SCANCODE_UNKNOWN, c.SDLK_P);
    try harness.pushMouse(.down, page_rect.centerX(), page_rect.centerY());
    try harness.pushMouse(.up, page_rect.centerX(), page_rect.centerY());
    try harness.pushKey(c.SDL_SCANCODE_RIGHT, c.SDLK_UNKNOWN);
    try harness.pushKey(c.SDL_SCANCODE_RIGHT, c.SDLK_UNKNOWN);
    try harness.pushQuit();
    try harness.application.run(.{ .initial_path = fixture });

    const application = &harness.application;
    try std.testing.expect(!application.running);
    try std.testing.expectEqual(@as(usize, 2), application.reader.page_index);
    try std.testing.expectEqual(@as(usize, 1), application.notebook.strokeCount());
    try std.testing.expectEqual(app.ui.frame.SaveStatus.saved, application.save_status);
    const progress = try harness.readProgress();
    defer std.testing.allocator.free(progress);
    try std.testing.expectEqualStrings("page 2\n", progress);
}

test "escape quits before any document is open and leaves no state behind" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.pushKey(c.SDL_SCANCODE_ESCAPE, c.SDLK_UNKNOWN);
    try harness.application.run(.{});
    try std.testing.expect(!harness.application.running);
    // No file dialog was pushed at the user while the desk was empty.
    try std.testing.expect(!harness.application.dialog_open);
    try std.testing.expectEqual(@as(?[]u8, null), try harness.storage.read(
        std.testing.allocator,
        app.storage.preferences_name,
    ));
}
