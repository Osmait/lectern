//! Coordinates documents, reading state, annotations, persistence, and the
//! frame loop. Everything native is reached through the comptime backend.
//!
//! The loop sleeps until input arrives or a timer is due, so an idle reader
//! costs nothing. Saves are coalesced with short delays and flushed whenever a
//! document is replaced or the application exits.

const std = @import("std");
const book_read = @import("book_read");
const annotations = book_read.annotations;
const progress = book_read.progress;
const Reader = book_read.Reader;
const Preferences = book_read.Preferences;
const ui = @import("ui.zig");
const commands = @import("commands.zig");
const storage_module = @import("storage.zig");

const Command = commands.Command;
const Layout = ui.Layout;
const Frame = ui.Frame;
const Size = ui.layout.Size;
const Rect = ui.layout.Rect;
const Vec2 = ui.layout.Vec2;
const RawInput = ui.input.RawInput;
const SaveStatus = ui.frame.SaveStatus;
const DocumentKey = storage_module.DocumentKey;

pub fn ApplicationType(comptime backend: type) type {
    return struct {
        const Self = @This();
        const Renderer = ui.Renderer(backend);

        pub const RunOptions = struct {
            initial_path: ?[]const u8 = null,
            smoke_test: bool = false,
        };

        /// Long enough to merge bursts of edits, short enough that a crash
        /// loses almost nothing.
        pub const save_delay_ms: u64 = 750;
        /// Zoom and resize re-render the page once the user pauses.
        pub const page_render_delay_ms: u64 = 120;
        /// Upper bound on sleeping when no timer is pending.
        pub const idle_wait_ms: u32 = 500;
        /// Longest page side ever rasterized, in device pixels.
        pub const maximum_page_pixels: f32 = 3072;
        pub const default_page_size = Size{ .width = 612, .height = 792 };

        const PageView = struct {
            texture: ?backend.Texture = null,
            scale: f32 = 0,
            size: Size = default_page_size,
        };

        const Timers = struct {
            notes: ?u64 = null,
            progress: ?u64 = null,
            preferences: ?u64 = null,
            render: ?u64 = null,
        };

        const NavigationTarget = union(enum) {
            next,
            previous,
            first,
            last,
            next_bookmark,
            page: usize,
        };

        const HoverTarget = union(enum) {
            none,
            toolbar: ui.layout.ToolbarButton,
            panel: ui.layout.PanelControl,
            thumbnail: usize,
        };

        allocator: std.mem.Allocator,
        context: backend.Context,
        storage: backend.Storage,
        reader: Reader,
        notebook: annotations.Notebook,
        renderer: Renderer,
        preferences: Preferences = .{},
        preferences_loaded: bool = false,
        document: ?backend.Document = null,
        document_key: ?DocumentKey = null,
        page: PageView = .{},
        mouse: ?Vec2 = null,
        dialog_open: bool = false,
        navigation_visible: bool = true,
        thumbnail_scroll: f32 = 0,
        notes_dirty: bool = false,
        progress_dirty: bool = false,
        preferences_dirty: bool = false,
        save_status: SaveStatus = .saved,
        timers: Timers = .{},
        needs_redraw: bool = true,
        running: bool = false,

        pub fn init(
            allocator: std.mem.Allocator,
            context: backend.Context,
            storage: backend.Storage,
        ) Self {
            return .{
                .allocator = allocator,
                .context = context,
                .storage = storage,
                .reader = Reader.init(allocator),
                .notebook = annotations.Notebook.init(allocator),
                .renderer = Renderer.init(allocator),
            };
        }

        /// Releases resources without touching storage; call `flushState`
        /// first when pending edits must survive.
        pub fn deinit(self: *Self) void {
            self.renderer.deinit();
            if (self.page.texture) |*texture| texture.deinit();
            if (self.document) |*document| document.deinit();
            self.notebook.deinit();
            self.reader.deinit();
            self.context.deinit();
            self.* = undefined;
        }

        pub fn run(self: *Self, options: RunOptions) !void {
            self.loadPreferences();
            if (options.initial_path) |path| {
                self.openPdf(path) catch |err| {
                    if (options.smoke_test) return err;
                    self.reportOpenFailure(err);
                    self.requestDialog();
                };
            } else if (!options.smoke_test) {
                self.requestDialog();
            }

            if (options.smoke_test) {
                if (self.document == null) return error.SmokeTestRequiresDocument;
                try self.runSmokeTest();
                self.flushState();
                return;
            }

            self.running = true;
            while (self.running) {
                var next = self.context.pollInput(self.allocator);
                if (next == null and !self.needs_redraw) {
                    const timeout = self.waitTimeout(self.context.ticksMs());
                    next = self.context.waitInput(self.allocator, timeout);
                }
                while (next) |raw| {
                    self.handleInput(raw);
                    next = self.context.pollInput(self.allocator);
                }
                self.update(self.context.ticksMs());
                if (self.needs_redraw) {
                    self.needs_redraw = false;
                    self.draw();
                }
            }
            self.flushState();
        }

        /// Milliseconds the loop may sleep before the earliest timer is due.
        pub fn waitTimeout(self: Self, now: u64) u32 {
            var earliest: ?u64 = null;
            inline for (std.meta.fields(Timers)) |field| {
                if (@field(self.timers, field.name)) |due| {
                    earliest = @min(earliest orelse due, due);
                }
            }
            const due = earliest orelse return idle_wait_ms;
            const remaining = if (due > now) due - now else 0;
            return @intCast(std.math.clamp(remaining, 1, std.math.maxInt(u32)));
        }

        pub fn handleInput(self: *Self, raw: RawInput) void {
            defer if (raw.path) |path| self.allocator.free(path);
            if (raw.hasPosition()) self.trackMouse(raw.position);
            if (raw.kind == .none) return;
            const command = ui.input.translate(raw, self.inputState()) orelse return;
            self.handleCommand(command);
        }

        pub fn handleCommand(self: *Self, command: Command) void {
            self.needs_redraw = true;
            switch (command) {
                .quit => {
                    self.running = false;
                    self.needs_redraw = false;
                },
                .redraw => {},
                .next_page => self.navigate(.next),
                .previous_page => self.navigate(.previous),
                .first_page => self.navigate(.first),
                .last_page => self.navigate(.last),
                .select_page => |page_index| self.navigate(.{ .page = page_index }),
                .jump_bookmark => self.navigate(.next_bookmark),
                .toggle_bookmark => {
                    if (self.reader.toggleBookmark()) self.markProgressDirty();
                },
                .toggle_dark_mode => self.toggleDarkMode(),
                .toggle_pages => {
                    if (self.document != null) self.navigation_visible = !self.navigation_visible;
                },
                .scroll_thumbnails => |amount| {
                    self.thumbnail_scroll = self.currentLayout().scrollThumbnails(
                        self.thumbnail_scroll,
                        amount,
                        self.reader.pageCount(),
                    );
                },
                .open_dialog => {
                    self.finishAnnotation();
                    self.requestDialog();
                },
                .dialog_closed => self.dialog_open = false,
                .open_path => |path| {
                    self.dialog_open = false;
                    self.openPdf(path) catch |err| self.reportOpenFailure(err);
                },
                .zoom_in => {
                    if (self.reader.zoomIn()) self.scheduleRender();
                },
                .zoom_out => {
                    if (self.reader.zoomOut()) self.scheduleRender();
                },
                .zoom_reset => {
                    if (self.reader.resetZoom()) self.scheduleRender();
                },
                .pen => {
                    self.finishAnnotation();
                    self.notebook.selectPen();
                },
                .eraser => {
                    self.finishAnnotation();
                    self.notebook.selectEraser();
                },
                .notes_off => {
                    self.finishAnnotation();
                    self.notebook.disableTool();
                },
                .cycle_color => {
                    self.finishAnnotation();
                    self.notebook.cycleColor();
                },
                .cycle_size => {
                    self.finishAnnotation();
                    self.notebook.cyclePenSize();
                },
                .select_color => |color| {
                    self.finishAnnotation();
                    self.notebook.selectColor(color);
                },
                .select_size => |pen_size| {
                    self.finishAnnotation();
                    self.notebook.selectPenSize(pen_size);
                },
                .note_undo => {
                    self.finishAnnotation();
                    if (self.notebook.undoPage(self.reader.page_index)) self.markNotesDirty();
                },
                .note_clear => {
                    self.finishAnnotation();
                    if (self.notebook.clearPage(self.reader.page_index)) self.markNotesDirty();
                },
                .draw_begin => |point| self.beginAnnotation(point),
                .draw_move => |point| self.continueAnnotation(point),
                .draw_end => self.finishAnnotation(),
            }
        }

        /// Runs every timer that is due: deferred page renders and saves.
        pub fn update(self: *Self, now: u64) void {
            if (isDue(self.timers.render, now)) {
                self.timers.render = null;
                _ = self.refreshPage();
            }
            if (isDue(self.timers.notes, now)) {
                self.timers.notes = null;
                self.saveNotes();
            }
            if (isDue(self.timers.progress, now)) {
                self.timers.progress = null;
                self.saveProgress();
            }
            if (isDue(self.timers.preferences, now)) {
                self.timers.preferences = null;
                self.savePreferences();
            }
        }

        pub fn draw(self: *Self) void {
            const palette = ui.theme.Palette.forMode(self.preferences.dark_mode);
            const info = self.context.beginFrame(palette.background);
            const layout = Layout.compute(info.size, self.layoutOptions());
            if (self.document != null) self.schedulePageRenderIfStale(layout, info.density);

            const frame = Frame{
                .dark_mode = self.preferences.dark_mode,
                .document_open = self.document != null,
                .page_index = self.reader.page_index,
                .page_count = self.reader.pageCount(),
                .zoom_percent = self.reader.zoomPercent(),
                .bookmarked = self.reader.isCurrentPageBookmarked(),
                .title = self.documentTitle(),
                .navigation_visible = self.navigation_visible,
                .thumbnail_scroll = self.thumbnail_scroll,
                .tool = self.notebook.tool,
                .color = self.notebook.color,
                .pen_size = self.notebook.pen_size,
                .save_status = self.save_status,
                .mouse = self.mouse,
                .page_rect = self.pageRect(layout),
            };
            const report = self.renderer.draw(
                self.context,
                frame,
                layout,
                self.page.texture,
                &self.notebook,
                self.document,
                info.density,
            );
            self.context.endFrame();
            if (report.pending_thumbnails) self.needs_redraw = true;
        }

        /// Writes every pending change immediately.
        pub fn flushState(self: *Self) void {
            self.finishAnnotation();
            self.saveNotes();
            self.saveProgress();
            self.savePreferences();
            self.timers.notes = null;
            self.timers.progress = null;
            self.timers.preferences = null;
        }

        /// Opens a document transactionally: the current document stays
        /// usable until the replacement has been opened, restored, and
        /// rendered.
        pub fn openPdf(self: *Self, raw_path: []const u8) !void {
            var next_document = try backend.Document.open(self.context, self.allocator, raw_path);
            errdefer next_document.deinit();
            const page_count = next_document.pageCount();

            var next_reader = Reader.init(self.allocator);
            errdefer next_reader.deinit();
            try next_reader.open(page_count);

            const key = DocumentKey.of(next_document.path());
            var name_buffer: [DocumentKey.name_capacity]u8 = undefined;
            if (try self.storage.read(self.allocator, key.progressName(&name_buffer))) |data| {
                defer self.allocator.free(data);
                const restored = progress.restore(&next_reader, data);
                if (!self.preferences_loaded) {
                    if (restored.legacy_dark_mode) |dark_mode| {
                        self.preferences.dark_mode = dark_mode;
                        self.preferences_loaded = true;
                        self.markPreferencesDirty();
                    }
                }
            }

            var next_notebook = annotations.Notebook.init(self.allocator);
            errdefer next_notebook.deinit();
            next_notebook.tool = self.notebook.tool;
            next_notebook.color = self.notebook.color;
            next_notebook.pen_size = self.notebook.pen_size;
            try next_notebook.open(page_count);
            if (try self.storage.read(self.allocator, key.notesName(&name_buffer))) |data| {
                defer self.allocator.free(data);
                next_notebook.restore(data) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => std.log.warn(
                        "ignoring invalid annotation file: {s}",
                        .{@errorName(err)},
                    ),
                };
            }

            const page_size = next_document.pageSize(next_reader.page_index) orelse
                default_page_size;
            const scale = self.desiredScale(page_size, next_reader.zoom(), .{
                .document_open = true,
                .navigation_visible = self.navigation_visible,
                .annotations_enabled = self.notebook.tool != .off,
            });
            var next_texture = try next_document.render(
                self.context,
                next_reader.page_index,
                scale,
                self.preferences.dark_mode,
            );
            errdefer next_texture.deinit();

            self.flushState();
            if (self.page.texture) |*texture| texture.deinit();
            if (self.document) |*document| document.deinit();
            self.notebook.deinit();
            self.reader.deinit();

            self.document = next_document;
            self.document_key = key;
            self.reader = next_reader;
            self.notebook = next_notebook;
            self.page = .{ .texture = next_texture, .scale = scale, .size = page_size };
            self.notes_dirty = false;
            self.progress_dirty = false;
            self.save_status = .saved;
            self.timers.render = null;
            self.thumbnail_scroll = 0;
            self.revealCurrentThumbnail();
            self.updateTitle();
            self.needs_redraw = true;
        }

        fn loadPreferences(self: *Self) void {
            const loaded = self.storage.read(self.allocator, storage_module.preferences_name);
            const data = (loaded catch return) orelse return;
            defer self.allocator.free(data);
            self.preferences = Preferences.parse(data);
            self.preferences_loaded = true;
        }

        fn requestDialog(self: *Self) void {
            if (self.dialog_open) return;
            self.dialog_open = true;
            self.context.openDialog();
        }

        fn navigate(self: *Self, target: NavigationTarget) void {
            if (self.document == null) return;
            self.finishAnnotation();
            const previous_index = self.reader.page_index;
            const moved = switch (target) {
                .next => self.reader.nextPage(),
                .previous => self.reader.previousPage(),
                .first => self.reader.firstPage(),
                .last => self.reader.lastPage(),
                .next_bookmark => self.reader.jumpToNextBookmark(),
                .page => |page_index| self.reader.goToPage(page_index),
            };
            if (!moved) return;
            if (!self.refreshPage()) {
                _ = self.reader.goToPage(previous_index);
                return;
            }
            self.markProgressDirty();
            self.updateTitle();
            self.revealCurrentThumbnail();
        }

        fn toggleDarkMode(self: *Self) void {
            self.preferences.dark_mode = !self.preferences.dark_mode;
            if (self.document != null and !self.refreshPage()) {
                self.preferences.dark_mode = !self.preferences.dark_mode;
                return;
            }
            self.markPreferencesDirty();
        }

        /// Renders the current page now and replaces the displayed texture.
        /// Failures are reported and leave the previous texture in place.
        fn refreshPage(self: *Self) bool {
            const document = self.document orelse return false;
            const page_size = document.pageSize(self.reader.page_index) orelse default_page_size;
            const scale = self.desiredScale(page_size, self.reader.zoom(), self.layoutOptions());
            const texture = document.render(
                self.context,
                self.reader.page_index,
                scale,
                self.preferences.dark_mode,
            ) catch |err| {
                std.log.warn("could not render page: {s}", .{@errorName(err)});
                self.context.showError(self.context.lastError());
                return false;
            };
            if (self.page.texture) |*old| old.deinit();
            self.page = .{ .texture = texture, .scale = scale, .size = page_size };
            self.timers.render = null;
            self.needs_redraw = true;
            return true;
        }

        fn scheduleRender(self: *Self) void {
            if (self.document == null) return;
            self.timers.render = self.context.ticksMs() + page_render_delay_ms;
        }

        fn schedulePageRenderIfStale(self: *Self, layout: Layout, density: f32) void {
            const desired = renderScale(layout, self.page.size, self.reader.zoom(), density);
            const stale = self.page.texture == null or self.page.scale <= 0 or
                @abs(desired / self.page.scale - 1) > 0.01;
            if (stale and self.timers.render == null) self.scheduleRender();
        }

        fn desiredScale(self: Self, page_size: Size, zoom: f32, options: ui.layout.Options) f32 {
            const layout = Layout.compute(self.context.windowSize(), options);
            return renderScale(layout, page_size, zoom, self.context.pixelDensity());
        }

        /// Device pixels per PDF point: exactly what the page occupies on
        /// screen, capped so extreme zooms never allocate giant textures.
        fn renderScale(layout: Layout, page_size: Size, zoom: f32, density: f32) f32 {
            const display_scale = layout.pageDisplayScale(page_size, zoom);
            const longest_side = @max(page_size.width, page_size.height);
            return @min(display_scale * density, maximum_page_pixels / longest_side);
        }

        fn beginAnnotation(self: *Self, point: annotations.Point) void {
            if (self.document == null) return;
            switch (self.notebook.tool) {
                .off => {},
                .pen => {
                    _ = self.notebook.beginStroke(
                        self.reader.page_index,
                        point,
                    ) catch |err| logAnnotationError("begin stroke", err);
                },
                .eraser => self.eraseAnnotation(point),
            }
        }

        fn continueAnnotation(self: *Self, point: annotations.Point) void {
            switch (self.notebook.tool) {
                .off => {},
                .pen => {
                    _ = self.notebook.appendPoint(point) catch |err| {
                        logAnnotationError("extend stroke", err);
                    };
                },
                .eraser => self.eraseAnnotation(point),
            }
        }

        fn eraseAnnotation(self: *Self, point: annotations.Point) void {
            if (self.notebook.eraseAt(self.reader.page_index, point)) self.markNotesDirty();
        }

        fn finishAnnotation(self: *Self) void {
            const added_stroke = self.notebook.finishStroke() catch |err| {
                logAnnotationError("finish stroke", err);
                self.notebook.cancelStroke();
                return;
            };
            if (added_stroke) self.markNotesDirty();
        }

        fn markNotesDirty(self: *Self) void {
            self.notes_dirty = true;
            self.save_status = .pending;
            self.timers.notes = self.context.ticksMs() + save_delay_ms;
            self.needs_redraw = true;
        }

        fn markProgressDirty(self: *Self) void {
            self.progress_dirty = true;
            self.timers.progress = self.context.ticksMs() + save_delay_ms;
        }

        fn markPreferencesDirty(self: *Self) void {
            self.preferences_dirty = true;
            self.timers.preferences = self.context.ticksMs() + save_delay_ms;
        }

        fn saveNotes(self: *Self) void {
            if (!self.notes_dirty) return;
            const key = self.document_key orelse return;
            const data = self.notebook.serialize(self.allocator) catch |err| {
                logAnnotationError("serialize notes", err);
                self.markSaveFailed();
                return;
            };
            defer self.allocator.free(data);
            var name_buffer: [DocumentKey.name_capacity]u8 = undefined;
            self.storage.write(key.notesName(&name_buffer), data) catch |err| {
                std.log.warn("could not save notes: {s}", .{@errorName(err)});
                self.markSaveFailed();
                return;
            };
            self.notes_dirty = false;
            self.save_status = .saved;
            self.needs_redraw = true;
        }

        fn markSaveFailed(self: *Self) void {
            self.save_status = .failed;
            self.needs_redraw = true;
        }

        fn saveProgress(self: *Self) void {
            if (!self.progress_dirty) return;
            const key = self.document_key orelse return;
            const data = progress.serialize(self.allocator, self.reader) catch |err| {
                std.log.warn("could not serialize progress: {s}", .{@errorName(err)});
                return;
            };
            defer self.allocator.free(data);
            var name_buffer: [DocumentKey.name_capacity]u8 = undefined;
            self.storage.write(key.progressName(&name_buffer), data) catch |err| {
                std.log.warn("could not save progress: {s}", .{@errorName(err)});
                return;
            };
            self.progress_dirty = false;
        }

        fn savePreferences(self: *Self) void {
            if (!self.preferences_dirty) return;
            const data = self.preferences.serialize(self.allocator) catch |err| {
                std.log.warn("could not serialize preferences: {s}", .{@errorName(err)});
                return;
            };
            defer self.allocator.free(data);
            self.storage.write(storage_module.preferences_name, data) catch |err| {
                std.log.warn("could not save preferences: {s}", .{@errorName(err)});
                return;
            };
            self.preferences_dirty = false;
        }

        fn runSmokeTest(self: *Self) !void {
            try self.notebook.open(self.reader.pageCount());
            self.notebook.tool = .pen;
            _ = try self.notebook.beginStroke(self.reader.page_index, .{ .x = 0.25, .y = 0.25 });
            _ = try self.notebook.appendPoint(.{ .x = 0.5, .y = 0.5 });
            if (!try self.notebook.finishStroke()) return error.AnnotationNotRecorded;
            self.markNotesDirty();
            self.saveNotes();
            if (self.notes_dirty) return error.AnnotationSaveFailed;

            const key = self.document_key orelse return error.AnnotationLoadFailed;
            var name_buffer: [DocumentKey.name_capacity]u8 = undefined;
            const notes = try self.storage.read(self.allocator, key.notesName(&name_buffer));
            const data = notes orelse return error.AnnotationLoadFailed;
            defer self.allocator.free(data);
            var restored = annotations.Notebook.init(self.allocator);
            defer restored.deinit();
            try restored.open(self.reader.pageCount());
            try restored.restore(data);
            if (restored.strokeCount() != 1) return error.AnnotationRoundTripFailed;
            self.draw();
        }

        fn trackMouse(self: *Self, position: Vec2) void {
            const before = self.hoverTarget(self.mouse);
            self.mouse = position;
            if (!std.meta.eql(before, self.hoverTarget(self.mouse))) self.needs_redraw = true;
        }

        fn hoverTarget(self: Self, position: ?Vec2) HoverTarget {
            const point = position orelse return .none;
            const layout = self.currentLayout();
            if (layout.toolbarHit(point, self.document != null)) |button| {
                return .{ .toolbar = button };
            }
            if (layout.panelHit(point)) |control| return .{ .panel = control };
            if (layout.thumbnailAt(point, self.thumbnail_scroll, self.reader.pageCount())) |index| {
                return .{ .thumbnail = index };
            }
            return .none;
        }

        fn layoutOptions(self: Self) ui.layout.Options {
            return .{
                .document_open = self.document != null,
                .navigation_visible = self.document != null and self.navigation_visible,
                .annotations_enabled = self.notebook.tool != .off,
            };
        }

        fn currentLayout(self: Self) Layout {
            return Layout.compute(self.context.windowSize(), self.layoutOptions());
        }

        fn pageRect(self: Self, layout: Layout) ?Rect {
            if (self.document == null) return null;
            return layout.pageRect(self.page.size, self.reader.zoom());
        }

        fn inputState(self: Self) ui.input.State {
            const layout = self.currentLayout();
            return .{
                .layout = layout,
                .page_rect = self.pageRect(layout),
                .tool = self.notebook.tool,
                .document_open = self.document != null,
                .page_count = self.reader.pageCount(),
                .thumbnail_scroll = self.thumbnail_scroll,
                .stroke_active = self.notebook.hasActiveStroke(),
            };
        }

        fn revealCurrentThumbnail(self: *Self) void {
            self.thumbnail_scroll = self.currentLayout().revealThumbnail(
                self.thumbnail_scroll,
                self.reader.page_index,
                self.reader.pageCount(),
            );
        }

        fn documentTitle(self: Self) []const u8 {
            const document = self.document orelse return "Open PDF";
            return book_read.baseName(document.path());
        }

        fn updateTitle(self: Self) void {
            var title_buffer: [512]u8 = undefined;
            const title = std.fmt.bufPrintZ(
                &title_buffer,
                "Book Read - {s} - page {d}/{d}",
                .{ self.documentTitle(), self.reader.page_index + 1, self.reader.pageCount() },
            ) catch "Book Read";
            self.context.setTitle(title);
        }

        /// Failures the user already sees in a dialog are logged as warnings;
        /// errors are reserved for conditions nobody handled.
        fn reportOpenFailure(self: *Self, err: anyerror) void {
            std.log.warn("could not open PDF: {s}", .{@errorName(err)});
            switch (err) {
                error.InvalidPdf, error.PageRenderFailed => {
                    self.context.showError(self.context.lastError());
                },
                error.EmptyDocument => self.context.showError("The PDF has no pages."),
                else => self.context.showError("The PDF could not be opened."),
            }
        }

        fn isDue(timer: ?u64, now: u64) bool {
            const due = timer orelse return false;
            return now >= due;
        }
    };
}

fn logAnnotationError(operation: []const u8, err: anyerror) void {
    std.log.warn("could not {s}: {s}", .{ operation, @errorName(err) });
}

const mock = @import("testing/mock_backend.zig");
const TestApplication = ApplicationType(mock.Backend);

fn initTestApplication(state: *mock.State) TestApplication {
    return TestApplication.init(
        std.testing.allocator,
        .{ .state = state },
        .{ .state = state },
    );
}

fn seedNotes(state: *mock.State, path: []const u8) !void {
    var notebook = annotations.Notebook.init(std.testing.allocator);
    defer notebook.deinit();
    try notebook.open(3);
    notebook.selectPen();
    _ = try notebook.beginStroke(1, .{ .x = 0.2, .y = 0.3 });
    _ = try notebook.finishStroke();
    const data = try notebook.serialize(std.testing.allocator);
    defer std.testing.allocator.free(data);
    var name_buffer: [DocumentKey.name_capacity]u8 = undefined;
    try state.putFile(DocumentKey.of(path).notesName(&name_buffer), data);
}

fn seedProgress(state: *mock.State, path: []const u8, data: []const u8) !void {
    var name_buffer: [DocumentKey.name_capacity]u8 = undefined;
    try state.putFile(DocumentKey.of(path).progressName(&name_buffer), data);
}

fn storedProgress(state: *mock.State, path: []const u8) ?[]const u8 {
    var name_buffer: [DocumentKey.name_capacity]u8 = undefined;
    return state.getFile(DocumentKey.of(path).progressName(&name_buffer));
}

fn storedNotes(state: *mock.State, path: []const u8) ?[]const u8 {
    var name_buffer: [DocumentKey.name_capacity]u8 = undefined;
    return state.getFile(DocumentKey.of(path).notesName(&name_buffer));
}

test "application opens a document and restores all persisted state" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    try seedProgress(&state, "library/book.pdf", "page 1\nbookmark 1\n");
    try seedNotes(&state, "library/book.pdf");
    try state.putFile(storage_module.preferences_name, "dark 0\n");
    var application = initTestApplication(&state);
    application.loadPreferences();
    try application.openPdf("library/book.pdf");

    try std.testing.expectEqual(@as(usize, 1), application.reader.page_index);
    try std.testing.expect(!application.preferences.dark_mode);
    try std.testing.expect(application.reader.isCurrentPageBookmarked());
    try std.testing.expectEqual(@as(usize, 1), application.notebook.strokeCount());
    try std.testing.expectEqual(@as(usize, 1), state.last_render_page);
    try std.testing.expect(!state.last_render_dark_mode);
    try std.testing.expectEqualStrings("Book Read - book.pdf - page 2/3", state.titleText());
    try std.testing.expectEqual(@as(?u64, null), application.timers.render);

    application.deinit();
    try std.testing.expectEqual(@as(usize, 1), state.document_deinit_count);
    try std.testing.expectEqual(@as(usize, 1), state.texture_deinit_count);
    try std.testing.expectEqual(@as(usize, 1), state.context_deinit_count);
}

test "pages render at the size they occupy on screen" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    state.density = 2;
    var application = initTestApplication(&state);
    defer application.deinit();
    try application.openPdf("book.pdf");

    const layout = application.currentLayout();
    const expected = layout.pageDisplayScale(TestApplication.default_page_size, 1.0) * 2;
    try std.testing.expectApproxEqAbs(expected, state.last_render_scale, 0.001);
    try std.testing.expect(state.last_render_scale * 792 < TestApplication.maximum_page_pixels);

    var index: usize = 0;
    while (index < 15) : (index += 1) application.handleCommand(.zoom_in);
    application.update(state.ticks + TestApplication.page_render_delay_ms);
    try std.testing.expectApproxEqAbs(
        TestApplication.maximum_page_pixels / 792,
        state.last_render_scale,
        0.001,
    );
}

test "the theme is an application preference that survives opening documents" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    try seedProgress(&state, "old.pdf", "page 0\ndark 0\n");
    var application = initTestApplication(&state);
    defer application.deinit();
    application.loadPreferences();
    try std.testing.expect(application.preferences.dark_mode);

    // A legacy per-document theme is adopted once when no preferences exist.
    try application.openPdf("old.pdf");
    try std.testing.expect(!application.preferences.dark_mode);
    try std.testing.expect(application.preferences_loaded);
    const migrated = state.getFile(storage_module.preferences_name).?;
    try std.testing.expectEqualStrings("dark 0\n", migrated);

    application.handleCommand(.toggle_dark_mode);
    try std.testing.expect(application.preferences.dark_mode);
    try std.testing.expect(state.last_render_dark_mode);
    try application.openPdf("new.pdf");
    try std.testing.expect(application.preferences.dark_mode);
    try std.testing.expect(state.last_render_dark_mode);

    application.handleCommand(.toggle_bookmark);
    application.flushState();
    const toggled = state.getFile(storage_module.preferences_name).?;
    try std.testing.expectEqualStrings("dark 1\n", toggled);
    const new_progress = storedProgress(&state, "new.pdf").?;
    try std.testing.expect(std.mem.indexOf(u8, new_progress, "dark") == null);
}

test "pen settings survive opening another document" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    var application = initTestApplication(&state);
    defer application.deinit();
    try application.openPdf("first.pdf");
    application.handleCommand(.pen);
    application.handleCommand(.{ .select_color = .purple });
    application.handleCommand(.{ .select_size = .thick });

    try application.openPdf("second.pdf");
    try std.testing.expectEqual(annotations.Tool.pen, application.notebook.tool);
    try std.testing.expectEqual(annotations.Color.purple, application.notebook.color);
    try std.testing.expectEqual(annotations.PenSize.thick, application.notebook.pen_size);
}

test "failed replacement opens and renders preserve the current document" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    var application = initTestApplication(&state);
    defer application.deinit();
    try application.openPdf("current.pdf");

    state.fail_open = true;
    try std.testing.expectError(error.InvalidPdf, application.openPdf("invalid.pdf"));
    try std.testing.expectEqualStrings("current.pdf", application.document.?.path());
    try std.testing.expectEqual(@as(usize, 0), state.document_deinit_count);

    state.fail_open = false;
    state.fail_render = true;
    try std.testing.expectError(error.PageRenderFailed, application.openPdf("broken.pdf"));
    try std.testing.expectEqualStrings("current.pdf", application.document.?.path());
    try std.testing.expectEqual(@as(usize, 1), state.document_deinit_count);
    try std.testing.expectEqual(@as(usize, 0), state.texture_deinit_count);

    application.handleCommand(.{ .open_path = "still-broken.pdf" });
    try std.testing.expectEqual(@as(usize, 1), state.show_error_count);
    try std.testing.expectEqualStrings("current.pdf", application.document.?.path());
}

test "empty documents fail transactionally before rendering" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    state.page_count = 0;
    var application = initTestApplication(&state);
    defer application.deinit();

    try std.testing.expectError(error.EmptyDocument, application.openPdf("empty.pdf"));
    try std.testing.expectEqual(@as(?mock.Backend.Document, null), application.document);
    try std.testing.expectEqual(@as(usize, 1), state.document_deinit_count);
    try std.testing.expectEqual(@as(usize, 0), state.render_count);
}

test "successful document replacement releases and saves the previous document" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    var application = initTestApplication(&state);
    defer application.deinit();
    try application.openPdf("first.pdf");
    application.handleCommand(.next_page);
    application.handleCommand(.pen);
    application.handleCommand(.{ .draw_begin = .{ .x = 0.1, .y = 0.1 } });
    try application.openPdf("second.pdf");

    try std.testing.expectEqualStrings("second.pdf", application.document.?.path());
    try std.testing.expectEqual(@as(usize, 2), state.document_open_count);
    try std.testing.expectEqual(@as(usize, 1), state.document_deinit_count);
    // One texture was replaced by the page change and one by the new document.
    try std.testing.expectEqual(@as(usize, 2), state.texture_deinit_count);
    try std.testing.expectEqualStrings("page 1\n", storedProgress(&state, "first.pdf").?);
    try std.testing.expect(storedNotes(&state, "first.pdf") != null);
    try std.testing.expect(!application.notes_dirty);
    try std.testing.expectEqual(@as(?u64, null), application.timers.notes);
}

test "page and theme render failures roll back reader state" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    var application = initTestApplication(&state);
    defer application.deinit();
    try application.openPdf("book.pdf");

    state.fail_render = true;
    application.handleCommand(.next_page);
    try std.testing.expectEqual(@as(usize, 0), application.reader.page_index);
    application.handleCommand(.toggle_dark_mode);
    try std.testing.expect(application.preferences.dark_mode);
    try std.testing.expectEqual(@as(usize, 2), state.show_error_count);
    try std.testing.expectEqual(@as(usize, 0), state.texture_deinit_count);

    state.fail_render = false;
    application.handleCommand(.next_page);
    try std.testing.expectEqual(@as(usize, 1), application.reader.page_index);
    try std.testing.expectEqual(@as(usize, 1), state.texture_deinit_count);
    application.handleCommand(.toggle_dark_mode);
    try std.testing.expect(!application.preferences.dark_mode);
    try std.testing.expectEqual(@as(usize, 2), state.texture_deinit_count);
}

test "annotation edits are saved after a short delay and flushed on demand" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    var application = initTestApplication(&state);
    defer application.deinit();
    try application.openPdf("book.pdf");

    application.handleCommand(.pen);
    application.handleCommand(.{ .draw_begin = .{ .x = 0.1, .y = 0.1 } });
    application.handleCommand(.{ .draw_move = .{ .x = 0.5, .y = 0.5 } });
    application.handleCommand(.draw_end);
    try std.testing.expect(application.notes_dirty);
    try std.testing.expectEqual(SaveStatus.pending, application.save_status);
    try std.testing.expectEqual(@as(usize, 0), state.write_count);
    try std.testing.expectEqual(
        @as(u32, @intCast(TestApplication.save_delay_ms)),
        application.waitTimeout(state.ticks),
    );

    application.update(state.ticks + TestApplication.save_delay_ms - 1);
    try std.testing.expectEqual(@as(usize, 0), state.write_count);
    application.update(state.ticks + TestApplication.save_delay_ms);
    try std.testing.expectEqual(@as(usize, 1), state.write_count);
    try std.testing.expect(!application.notes_dirty);
    try std.testing.expectEqual(SaveStatus.saved, application.save_status);
    try std.testing.expectEqual(TestApplication.idle_wait_ms, application.waitTimeout(state.ticks));

    application.handleCommand(.eraser);
    application.handleCommand(.{ .draw_begin = .{ .x = 0.3, .y = 0.3 } });
    application.handleCommand(.draw_end);
    try std.testing.expectEqual(@as(usize, 0), application.notebook.strokeCount());
    try std.testing.expect(application.notes_dirty);
    application.flushState();
    try std.testing.expectEqual(@as(usize, 2), state.write_count);
    try std.testing.expect(!application.notes_dirty);
}

test "save failures are shown and retried on the next edit" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    var application = initTestApplication(&state);
    defer application.deinit();
    try application.openPdf("book.pdf");
    application.handleCommand(.pen);
    application.handleCommand(.{ .draw_begin = .{ .x = 0.1, .y = 0.1 } });
    application.handleCommand(.draw_end);

    state.fail_write = true;
    application.flushState();
    try std.testing.expectEqual(SaveStatus.failed, application.save_status);
    try std.testing.expect(application.notes_dirty);

    state.fail_write = false;
    application.handleCommand(.note_undo);
    try std.testing.expectEqual(SaveStatus.pending, application.save_status);
    application.flushState();
    try std.testing.expectEqual(SaveStatus.saved, application.save_status);
    try std.testing.expect(!application.notes_dirty);
}

test "application routes navigation, editing, dialog, and quit commands" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    var application = initTestApplication(&state);
    defer application.deinit();
    try application.openPdf("book.pdf");

    application.handleCommand(.next_page);
    application.handleCommand(.previous_page);
    application.handleCommand(.last_page);
    try std.testing.expectEqual(@as(usize, 2), application.reader.page_index);
    application.handleCommand(.first_page);
    application.handleCommand(.toggle_pages);
    try std.testing.expect(!application.navigation_visible);
    application.handleCommand(.toggle_pages);
    try std.testing.expect(application.navigation_visible);
    application.handleCommand(.{ .select_page = 2 });
    try std.testing.expectEqual(@as(usize, 2), application.reader.page_index);
    application.handleCommand(.{ .select_page = 99 });
    try std.testing.expectEqual(@as(usize, 2), application.reader.page_index);
    application.handleCommand(.first_page);
    application.handleCommand(.zoom_in);
    try std.testing.expect(application.timers.render != null);
    application.handleCommand(.zoom_reset);
    application.handleCommand(.zoom_out);
    try std.testing.expectEqual(@as(u32, 90), application.reader.zoomPercent());
    application.handleCommand(.toggle_bookmark);
    try std.testing.expect(application.progress_dirty);
    application.handleCommand(.jump_bookmark);
    application.handleCommand(.open_dialog);
    application.handleCommand(.open_dialog);
    try std.testing.expectEqual(@as(usize, 1), state.open_dialog_count);
    application.handleCommand(.dialog_closed);
    application.handleCommand(.open_dialog);
    try std.testing.expectEqual(@as(usize, 2), state.open_dialog_count);
    application.handleCommand(.{ .scroll_thumbnails = -1 });
    try std.testing.expectEqual(@as(f32, 0), application.thumbnail_scroll);

    application.handleCommand(.cycle_color);
    application.handleCommand(.cycle_size);
    try std.testing.expectEqual(annotations.Color.red, application.notebook.color);
    try std.testing.expectEqual(annotations.PenSize.thick, application.notebook.pen_size);
    application.handleCommand(.{ .select_color = .yellow });
    application.handleCommand(.{ .select_size = .thin });
    try std.testing.expectEqual(annotations.Color.yellow, application.notebook.color);
    try std.testing.expectEqual(annotations.PenSize.thin, application.notebook.pen_size);
    application.handleCommand(.pen);
    try std.testing.expectEqual(annotations.Tool.pen, application.notebook.tool);
    application.handleCommand(.notes_off);
    try std.testing.expectEqual(annotations.Tool.off, application.notebook.tool);

    application.notebook.selectPen();
    for (0..2) |_| {
        _ = try application.notebook.beginStroke(0, .{ .x = 0.2, .y = 0.2 });
        _ = try application.notebook.finishStroke();
    }
    application.handleCommand(.note_undo);
    try std.testing.expectEqual(@as(usize, 1), application.notebook.strokeCount());
    application.handleCommand(.note_clear);
    try std.testing.expectEqual(@as(usize, 0), application.notebook.strokeCount());

    application.handleCommand(.redraw);
    application.handleCommand(.{ .open_path = "replacement.pdf" });
    try std.testing.expectEqualStrings("replacement.pdf", application.document.?.path());
    try std.testing.expect(!application.dialog_open);

    application.running = true;
    application.handleCommand(.quit);
    try std.testing.expect(!application.running);
}

test "raw input drives commands, hover redraws, and owned paths" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    var application = initTestApplication(&state);
    defer application.deinit();
    try application.openPdf("book.pdf");
    application.needs_redraw = false;

    application.handleInput(.{ .kind = .mouse_motion, .position = .{ .x = 600, .y = 400 } });
    try std.testing.expect(!application.needs_redraw);
    const next_button = application.currentLayout().toolbar.next;
    application.handleInput(.{
        .kind = .mouse_motion,
        .position = .{ .x = next_button.centerX(), .y = next_button.centerY() },
    });
    try std.testing.expect(application.needs_redraw);
    application.needs_redraw = false;
    application.handleInput(.{
        .kind = .mouse_down,
        .button = .left,
        .position = .{ .x = next_button.centerX(), .y = next_button.centerY() },
    });
    try std.testing.expectEqual(@as(usize, 1), application.reader.page_index);
    try std.testing.expect(application.needs_redraw);

    application.handleInput(.{ .kind = .key_down, .key = .d });
    try std.testing.expect(!application.preferences.dark_mode);
    application.handleInput(.{ .kind = .none });

    const path = try std.testing.allocator.dupe(u8, "dropped.pdf");
    application.handleInput(.{ .kind = .file, .path = path });
    try std.testing.expectEqualStrings("dropped.pdf", application.document.?.path());
}

fn exerciseApplicationAllocations(allocator: std.mem.Allocator) !void {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    try seedProgress(&state, "allocation-test.pdf", "page 1\nbookmark 2\n");
    try seedNotes(&state, "allocation-test.pdf");
    var application = TestApplication.init(allocator, .{ .state = &state }, .{ .state = &state });
    defer application.deinit();
    try application.openPdf("allocation-test.pdf");
    try application.openPdf("allocation-test.pdf");
}

test "application document opening is leak-free across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseApplicationAllocations,
        .{},
    );
}

test "page navigation visibility changes only while a document is open" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    var application = initTestApplication(&state);
    defer application.deinit();

    application.handleCommand(.toggle_pages);
    try std.testing.expect(application.navigation_visible);
    application.handleCommand(.next_page);
    application.handleCommand(.{ .draw_begin = .{ .x = 0.5, .y = 0.5 } });
    try std.testing.expect(!application.notebook.hasActiveStroke());

    try application.openPdf("book.pdf");
    application.handleCommand(.toggle_pages);
    try std.testing.expect(!application.navigation_visible);
}

test "corrupt annotation state is ignored while the PDF remains usable" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    var name_buffer: [DocumentKey.name_capacity]u8 = undefined;
    try state.putFile(DocumentKey.of("book.pdf").notesName(&name_buffer), "oops");
    var application = initTestApplication(&state);
    defer application.deinit();

    try application.openPdf("book.pdf");
    try std.testing.expect(application.reader.isOpen());
    try std.testing.expectEqual(@as(usize, 0), application.notebook.strokeCount());
}

test "interactive run loop waits for input, redraws on demand, and exits" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    state.inputs_arrive_while_waiting = true;
    try state.pushInput(.{ .kind = .key_down, .key = .p });
    try state.pushInput(.{ .kind = .mouse_motion, .position = .{ .x = 5, .y = 5 } });
    try state.pushInput(.{ .kind = .quit });
    var application = initTestApplication(&state);
    defer application.deinit();

    try application.run(.{});
    try std.testing.expectEqual(@as(usize, 1), state.open_dialog_count);
    try std.testing.expectEqual(annotations.Tool.pen, application.notebook.tool);
    // The first frame, then one after the pen command; the hover and the quit
    // command do not repaint.
    try std.testing.expectEqual(@as(usize, 2), state.frame_count);
    try std.testing.expectEqual(@as(usize, 3), state.wait_count);
    try std.testing.expectEqual(TestApplication.idle_wait_ms, state.last_wait_timeout);
    try std.testing.expect(!application.running);
}

test "drawing without a document shows the empty state and never renders" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    var application = initTestApplication(&state);
    defer application.deinit();
    application.draw();
    try std.testing.expectEqual(@as(usize, 1), state.frame_count);
    try std.testing.expectEqual(@as(usize, 0), state.render_count);
    try std.testing.expectEqual(@as(?u64, null), application.timers.render);
}

test "resizing the window schedules one page re-render after a pause" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    var application = initTestApplication(&state);
    defer application.deinit();
    application.navigation_visible = false;
    try application.openPdf("book.pdf");
    application.draw();
    try std.testing.expectEqual(@as(?u64, null), application.timers.render);

    state.window = .{ .width = 1600, .height = 1000 };
    application.draw();
    try std.testing.expect(application.timers.render != null);
    application.draw();
    try std.testing.expectEqual(@as(usize, 1), state.render_count);
    application.update(state.ticks + TestApplication.page_render_delay_ms);
    try std.testing.expectEqual(@as(usize, 2), state.render_count);
    application.draw();
    try std.testing.expectEqual(@as(?u64, null), application.timers.render);
}

test "smoke run requires a document and validates annotation round trips" {
    var missing_state = mock.State.init(std.testing.allocator);
    defer missing_state.deinit();
    var missing_application = initTestApplication(&missing_state);
    defer missing_application.deinit();
    try std.testing.expectError(
        error.SmokeTestRequiresDocument,
        missing_application.run(.{ .smoke_test = true }),
    );

    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    var application = initTestApplication(&state);
    defer application.deinit();
    try application.run(.{ .initial_path = "smoke.pdf", .smoke_test = true });
    try std.testing.expectEqual(@as(usize, 1), application.notebook.strokeCount());
    try std.testing.expect(storedNotes(&state, "smoke.pdf") != null);
    try std.testing.expectEqual(@as(usize, 1), state.frame_count);
    try std.testing.expect(state.triangle_batch_count >= 1);

    var failing_state = mock.State.init(std.testing.allocator);
    defer failing_state.deinit();
    failing_state.storage_available = false;
    var failing_application = initTestApplication(&failing_state);
    defer failing_application.deinit();
    try std.testing.expectError(
        error.AnnotationSaveFailed,
        failing_application.run(.{ .initial_path = "smoke.pdf", .smoke_test = true }),
    );
}
