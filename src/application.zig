//! Coordinates documents, reading state, annotations, persistence, and the
//! frame loop. Everything native is reached through the comptime backend.
//!
//! The loop sleeps until input arrives, a timer is due, or a background
//! render finishes. Pages are rasterized on the backend's render queue: the
//! page on screen first, then the visible thumbnails, then the neighbors of
//! the current page, so most page turns are instant. Saves are coalesced with
//! short delays, handed to the storage thread, and flushed whenever a
//! document is replaced or the application exits.
//!
//! The application borrows its native resources. Whoever creates the context,
//! the storage, and the render queue releases them after `deinit`.

const std = @import("std");
const lectern = @import("lectern");
const annotations = lectern.annotations;
const progress = lectern.progress;
const Reader = lectern.Reader;
const Preferences = lectern.Preferences;
const ui = @import("ui.zig");
const commands = @import("commands.zig");
const storage_module = @import("storage.zig");
const rendering = @import("rendering.zig");
const page_cache = @import("page_cache.zig");
const arguments = @import("arguments.zig");

const Command = commands.Command;
const Layout = ui.Layout;
const Frame = ui.Frame;
const Size = ui.layout.Size;
const Rect = ui.layout.Rect;
const Vec2 = ui.layout.Vec2;
const Hover = ui.layout.Hover;
const RawInput = ui.input.RawInput;
const SaveStatus = ui.frame.SaveStatus;
const DocumentKey = storage_module.DocumentKey;

pub const RunOptions = arguments.RunOptions;

fn requireDeclarations(
    comptime Type: type,
    comptime name: []const u8,
    comptime declarations: []const []const u8,
) void {
    for (declarations) |declaration| {
        if (!@hasDecl(Type, declaration)) {
            @compileError(name ++ " must declare `" ++ declaration ++ "`");
        }
    }
}

/// Everything a backend must provide, checked up front so a missing piece
/// names itself instead of failing deep inside a generic function.
fn checkBackend(comptime backend: type) void {
    comptime {
        requireDeclarations(backend, "backend", &.{
            "Context", "Document", "Texture", "TextImage", "Storage", "RenderQueue",
        });
        requireDeclarations(backend.Context, "backend.Context", &.{
            "deinit",      "lastError",     "pollInput",  "waitInput",   "ticksMs",
            "windowSize",  "pixelDensity",  "setTitle",   "showError",   "openDialog",
            "beginFrame",  "endFrame",      "fillRect",   "strokeRect",  "setClip",
            "drawTexture", "drawTriangles", "createText", "measureText", "createIcon",
        });
        requireDeclarations(backend.Document, "backend.Document", &.{
            "open", "deinit", "pageCount", "path", "pageSize", "identity", "render",
        });
        requireDeclarations(backend.Texture, "backend.Texture", &.{"deinit"});
        requireDeclarations(backend.Storage, "backend.Storage", &.{
            "isAvailable", "read", "write", "hasPendingWrites", "pollCompletion", "flush",
        });
        requireDeclarations(backend.RenderQueue, "backend.RenderQueue", &.{
            "submit", "cancel", "cancelAll", "reprioritize", "waitIdle", "poll",
        });
    }
}

pub fn ApplicationType(comptime backend: type) type {
    checkBackend(backend);
    return struct {
        const Self = @This();
        const Renderer = ui.Renderer(backend);
        const PageCache = page_cache.PageCache(backend.Texture);
        const Job = rendering.Job(backend.Document);
        const RenderResult = rendering.Result(backend.Document, backend.Texture);

        /// Long enough to merge bursts of edits, short enough that a crash
        /// loses almost nothing.
        pub const save_delay_ms: u64 = 750;
        /// Zoom and resize re-render the page once the user pauses.
        pub const page_render_delay_ms: u64 = 120;
        /// While a write is in flight the loop wakes this often to collect
        /// its completion.
        pub const write_poll_ms: u32 = 50;
        pub const default_page_size = Size{ .width = 612, .height = 792 };

        pub const OpenError = error{ InvalidPdf, EmptyDocument, PageRenderFailed, OutOfMemory };

        /// The page on screen. `scale` and `dark_mode` describe the texture;
        /// `requested_scale` is set while a replacement is being rendered.
        const PageView = struct {
            page_index: usize = 0,
            size: Size = default_page_size,
            scale: f32 = 0,
            dark_mode: bool = false,
            texture: ?backend.Texture = null,
            requested_scale: ?f32 = null,
            /// The last render of this page failed; wait for a change before
            /// asking again, so a broken page never loops on error dialogs.
            failed: bool = false,
        };

        const PendingPage = struct {
            id: u64,
            page_index: usize,
            scale: f32,
            immediate: bool,
        };

        /// One coalesced save: edits mark it dirty and arm its timer.
        const PendingSave = struct {
            dirty: bool = false,
            due: ?u64 = null,

            fn mark(self: *PendingSave, now: u64) void {
                self.dirty = true;
                self.due = now + save_delay_ms;
            }

            fn takeDue(self: *PendingSave, now: u64) bool {
                const due = self.due orelse return false;
                if (now < due) return false;
                self.due = null;
                return true;
            }
        };

        const NavigationTarget = union(enum) {
            next,
            previous,
            first,
            last,
            next_bookmark,
            page: usize,
        };

        allocator: std.mem.Allocator,
        context: *backend.Context,
        storage: *backend.Storage,
        renders: *backend.RenderQueue,
        reader: Reader,
        notebook: annotations.Notebook,
        renderer: Renderer,
        pages: PageCache = .{},
        preferences: Preferences = .{},
        preferences_loaded: bool = false,
        document: ?backend.Document = null,
        document_key: ?DocumentKey = null,
        /// Bumped on every document replacement; render results of an older
        /// generation are dropped unseen.
        generation: u64 = 0,
        page: PageView = .{},
        pending_pages: std.ArrayList(PendingPage) = .empty,
        window: Size,
        layout: Layout,
        hover: Hover = .none,
        mouse: ?Vec2 = null,
        dialog_open: bool = false,
        navigation_visible: bool = true,
        thumbnail_scroll: f32 = 0,
        /// While the rail scrollbar is dragged: the pointer's distance from
        /// the thumb's top when it was grabbed.
        scrollbar_grab: ?f32 = null,
        notes: PendingSave = .{},
        progress_save: PendingSave = .{},
        preferences_save: PendingSave = .{},
        save_status: SaveStatus = .saved,
        render_timer: ?u64 = null,
        /// The display scale the render timer was armed for; the timer only
        /// restarts when the scale keeps changing, which is what a debounce
        /// of a resize or a zoom burst needs.
        stale_scale: f32 = 0,
        needs_redraw: bool = true,
        running: bool = false,

        pub fn init(
            allocator: std.mem.Allocator,
            context: *backend.Context,
            storage: *backend.Storage,
            renders: *backend.RenderQueue,
        ) Self {
            const window = context.windowSize();
            return .{
                .allocator = allocator,
                .context = context,
                .storage = storage,
                .renders = renders,
                .reader = Reader.init(allocator),
                .notebook = annotations.Notebook.init(allocator),
                .renderer = Renderer.init(allocator),
                .window = window,
                .layout = Layout.compute(window, .{
                    .document_open = false,
                    .navigation_visible = false,
                    .annotations_enabled = false,
                }),
            };
        }

        /// Releases everything the application created. Pending edits must
        /// be flushed first with `flushState`; `run` does so before returning.
        pub fn deinit(self: *Self) void {
            self.renders.cancelAll();
            self.renders.waitIdle();
            self.discardRenders();
            self.renderer.deinit();
            self.pages.deinit();
            if (self.page.texture) |*texture| texture.deinit();
            if (self.document) |*document| document.deinit();
            self.notebook.deinit();
            self.reader.deinit();
            self.pending_pages.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn run(self: *Self, options: RunOptions) !void {
            self.loadPreferences();
            // The reader starts on an empty desk. The file dialog opens only
            // when the user asks for it, with the Open button or the O key;
            // a path that cannot be opened reports why and leaves the same
            // choice to the user instead of pushing a dialog at them.
            if (options.initial_path) |path| {
                self.openPdf(path) catch |err| {
                    if (options.smoke_test) return err;
                    self.reportOpenFailure(err);
                };
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
                self.step(next);
            }
            self.flushState();
        }

        /// One turn of the frame loop: handles `first` and every input queued
        /// behind it, runs due timers, collects finished work, and repaints
        /// when needed. `run` sleeps between turns; end-to-end drivers call
        /// this directly with the input they polled themselves.
        pub fn step(self: *Self, first: ?RawInput) void {
            var next = first;
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

        /// Milliseconds the loop may sleep before the earliest timer is due,
        /// or null to sleep until input or a finished render wakes it.
        pub fn waitTimeout(self: *Self, now: u64) ?u32 {
            var earliest: ?u64 = self.render_timer;
            const saves = [_]?u64{
                self.notes.due,
                self.progress_save.due,
                self.preferences_save.due,
            };
            for (saves) |due| {
                if (due) |value| earliest = @min(earliest orelse value, value);
            }
            if (self.storage.hasPendingWrites()) {
                const poll_at = now + write_poll_ms;
                earliest = @min(earliest orelse poll_at, poll_at);
            }
            const due = earliest orelse return null;
            const remaining = if (due > now) due - now else 0;
            return @intCast(std.math.clamp(remaining, 1, std.math.maxInt(u32)));
        }

        pub fn handleInput(self: *Self, raw: RawInput) void {
            defer if (raw.path) |path| self.allocator.free(path);
            switch (raw.kind) {
                .mouse_leave => {
                    self.mouse = null;
                    self.refreshHover();
                    return;
                },
                .window => {
                    self.window = self.context.windowSize();
                    self.refreshLayout();
                },
                // Finished renders are collected by `update` on every turn of
                // the loop; the event only had to end the wait.
                .render_ready => return,
                else => {},
            }
            if (raw.hasPosition()) self.trackMouse(raw.position);
            if (raw.kind == .none) return;
            const command = ui.input.translate(raw, self.inputState()) orelse return;
            self.handleCommand(command);
        }

        /// Executes a command. Only commands that changed something visible
        /// schedule a repaint.
        pub fn handleCommand(self: *Self, command: Command) void {
            switch (command) {
                .quit => {
                    self.running = false;
                    return;
                },
                .redraw => self.needs_redraw = true,
                .next_page => self.navigate(.next),
                .previous_page => self.navigate(.previous),
                .first_page => self.navigate(.first),
                .last_page => self.navigate(.last),
                .select_page => |page_index| self.navigate(.{ .page = page_index }),
                .jump_bookmark => self.navigate(.next_bookmark),
                .toggle_bookmark => {
                    if (self.reader.toggleBookmark()) {
                        self.markProgressDirty();
                        self.needs_redraw = true;
                    }
                },
                .toggle_dark_mode => self.toggleDarkMode(),
                .toggle_pages => {
                    if (self.document != null) {
                        self.navigation_visible = !self.navigation_visible;
                        self.scrollbar_grab = null;
                        self.refreshLayout();
                        self.needs_redraw = true;
                    }
                },
                .scroll_thumbnails => |amount| self.scrollRailTo(self.layout.scrollThumbnails(
                    self.thumbnail_scroll,
                    amount,
                    self.reader.pageCount(),
                )),
                .scroll_thumbnails_to => |scroll| self.scrollRailTo(scroll),
                .scrollbar_grab => |offset| {
                    if (self.document != null and self.navigation_visible) {
                        self.scrollbar_grab = offset;
                        self.needs_redraw = true;
                    }
                },
                .scrollbar_drag => |pointer_y| {
                    if (self.scrollbar_grab) |offset| {
                        self.scrollRailTo(self.layout.scrollForThumb(
                            pointer_y - offset,
                            self.reader.pageCount(),
                        ));
                    }
                },
                .scrollbar_release => {
                    if (self.scrollbar_grab != null) {
                        self.scrollbar_grab = null;
                        self.needs_redraw = true;
                    }
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
                    if (self.reader.zoomIn()) self.zoomChanged();
                },
                .zoom_out => {
                    if (self.reader.zoomOut()) self.zoomChanged();
                },
                .zoom_reset => {
                    if (self.reader.resetZoom()) self.zoomChanged();
                },
                .pen => {
                    self.finishAnnotation();
                    self.notebook.selectPen();
                    self.toolChanged();
                },
                .eraser => {
                    self.finishAnnotation();
                    self.notebook.selectEraser();
                    self.toolChanged();
                },
                .notes_off => {
                    self.finishAnnotation();
                    if (self.notebook.tool != .off) {
                        self.notebook.disableTool();
                        self.toolChanged();
                    }
                },
                .cycle_color => {
                    self.finishAnnotation();
                    self.notebook.cycleColor();
                    self.needs_redraw = true;
                },
                .cycle_size => {
                    self.finishAnnotation();
                    self.notebook.cyclePenSize();
                    self.needs_redraw = true;
                },
                .select_color => |color| {
                    self.finishAnnotation();
                    if (self.notebook.color != color) {
                        self.notebook.selectColor(color);
                        self.needs_redraw = true;
                    }
                },
                .select_size => |pen_size| {
                    self.finishAnnotation();
                    if (self.notebook.pen_size != pen_size) {
                        self.notebook.selectPenSize(pen_size);
                        self.needs_redraw = true;
                    }
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
            self.refreshHover();
        }

        /// Runs every timer that is due and collects finished renders and
        /// writes.
        pub fn update(self: *Self, now: u64) void {
            if (self.render_timer) |due| {
                if (now >= due) {
                    self.render_timer = null;
                    self.refreshPage();
                }
            }
            if (self.notes.takeDue(now)) self.saveNotes();
            if (self.progress_save.takeDue(now)) self.saveProgress();
            if (self.preferences_save.takeDue(now)) self.savePreferences();
            self.collectRenders();
            self.collectSaveResults();
        }

        pub fn draw(self: *Self) void {
            const dark_mode = self.preferences.dark_mode;
            const palette = ui.theme.Palette.forMode(dark_mode);
            const info = self.context.beginFrame(palette.background);
            if (!std.meta.eql(info.size, self.window)) {
                self.window = info.size;
                self.refreshLayout();
                self.refreshHover();
            }
            if (self.document != null) self.schedulePageRenderIfStale(info.density);

            const page_index = self.reader.page_index;
            var document_identity: u64 = 0;
            if (self.document) |document| {
                document_identity = document.identity();
                if (self.navigation_visible) {
                    self.renderer.thumbnails.prepare(
                        self.renders,
                        document_identity,
                        self.reader.pageCount(),
                        dark_mode,
                        info.density,
                    ) catch |err| logFailure("prepare thumbnails", err);
                }
            }
            const active_stroke: []const annotations.Point = if (self.notebook.hasActiveStroke() and
                self.notebook.active_page_index == page_index)
                self.notebook.activePoints()
            else
                &.{};
            const frame = Frame{
                .dark_mode = dark_mode,
                .document_open = self.document != null,
                .density = info.density,
                .document_identity = document_identity,
                .page_index = page_index,
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
                .hover = self.hover,
                .scrollbar_dragging = self.scrollbar_grab != null,
                .page_rect = self.pageRect(),
                .strokes = self.notebook.strokesOn(page_index),
                .strokes_revision = self.notebook.revision,
                .active_stroke = active_stroke,
            };
            const report = self.renderer.draw(
                self.context.*,
                frame,
                self.layout,
                self.page.texture,
            );
            self.context.endFrame();

            if (self.document) |document| {
                if (self.navigation_visible) {
                    self.renderer.thumbnails.requestVisible(
                        self.renders,
                        document,
                        self.generation,
                        report.visible_thumbnails,
                        dark_mode,
                        info.density,
                    );
                }
            }
        }

        /// Writes every pending change and waits for the disk.
        pub fn flushState(self: *Self) void {
            self.finishAnnotation();
            self.notes.due = null;
            self.progress_save.due = null;
            self.preferences_save.due = null;
            self.saveNotes();
            self.saveProgress();
            self.savePreferences();
            self.storage.flush();
            self.collectSaveResults();
        }

        /// Opens a document transactionally: the current document stays
        /// usable until the replacement has been opened, restored, and its
        /// first page rendered.
        pub fn openPdf(self: *Self, raw_path: []const u8) OpenError!void {
            var next_document = try backend.Document.open(self.context.*, self.allocator, raw_path);
            errdefer next_document.deinit();
            const page_count = next_document.pageCount();

            var next_reader = Reader.init(self.allocator);
            errdefer next_reader.deinit();
            try next_reader.open(page_count);

            // Pending edits reach the disk before the candidate's files are
            // read, so reopening the same file never loses the latest notes.
            self.flushState();

            const key = DocumentKey.of(next_document.path());
            var name_buffer: [storage_module.name_capacity]u8 = undefined;
            var legacy_dark_mode: ?bool = null;
            if (try self.storage.read(self.allocator, key.progressName(&name_buffer))) |data| {
                defer self.allocator.free(data);
                legacy_dark_mode = progress.restore(&next_reader, data).legacy_dark_mode;
            }

            var next_notebook = annotations.Notebook.init(self.allocator);
            errdefer next_notebook.deinit();
            next_notebook.tool = self.notebook.tool;
            next_notebook.color = self.notebook.color;
            next_notebook.pen_size = self.notebook.pen_size;
            try next_notebook.open(page_count);
            if (try self.storage.read(self.allocator, key.notesName(&name_buffer))) |data| {
                defer self.allocator.free(data);
                self.restoreNotes(&next_notebook, data) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                };
            }

            const page_size = next_document.pageSize(next_reader.page_index) orelse
                default_page_size;
            const scale = self.scaleFor(page_size, next_reader.zoom(), .{
                .document_open = true,
                .navigation_visible = self.navigation_visible,
                .annotations_enabled = self.notebook.tool != .off,
            });
            var next_texture = try next_document.render(
                self.context.*,
                next_reader.page_index,
                scale,
                self.preferences.dark_mode,
            );
            errdefer next_texture.deinit();

            // Commit. The render worker must be done with the current
            // document before it is closed.
            self.renders.cancelAll();
            self.renders.waitIdle();
            self.pending_pages.clearRetainingCapacity();
            self.generation += 1;
            self.pages.clear();
            if (self.page.texture) |*texture| texture.deinit();
            if (self.document) |*document| document.deinit();
            self.notebook.deinit();
            self.reader.deinit();

            self.document = next_document;
            self.document_key = key;
            self.reader = next_reader;
            self.notebook = next_notebook;
            self.page = .{
                .page_index = next_reader.page_index,
                .size = page_size,
                .scale = scale,
                .dark_mode = self.preferences.dark_mode,
                .texture = next_texture,
            };
            self.notes = .{};
            self.progress_save = .{};
            self.save_status = .saved;
            self.render_timer = null;
            self.thumbnail_scroll = 0;
            self.scrollbar_grab = null;
            self.refreshLayout();
            self.revealCurrentThumbnail();
            self.refreshHover();
            self.updateTitle();
            self.needs_redraw = true;

            // A theme stored by an earlier version inside the document's
            // progress is adopted once, only now that the open succeeded.
            if (!self.preferences_loaded) {
                if (legacy_dark_mode) |dark_mode| {
                    self.preferences_loaded = true;
                    if (self.preferences.dark_mode != dark_mode) {
                        self.preferences.dark_mode = dark_mode;
                        self.refreshPage();
                    }
                    self.markPreferencesDirty();
                }
            }
            self.prefetchNeighbors();
        }

        fn restoreNotes(
            self: *Self,
            notebook: *annotations.Notebook,
            data: []const u8,
        ) error{OutOfMemory}!void {
            _ = self;
            const restored = notebook.restore(data) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    std.log.warn("ignoring invalid annotation file: {s}", .{@errorName(err)});
                    return;
                },
            };
            if (restored.skipped > 0) {
                std.log.warn("ignoring {d} notes on pages this PDF no longer has", .{
                    restored.skipped,
                });
            }
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
            const moved = switch (target) {
                .next => self.reader.nextPage(),
                .previous => self.reader.previousPage(),
                .first => self.reader.firstPage(),
                .last => self.reader.lastPage(),
                .next_bookmark => self.reader.jumpToNextBookmark(),
                .page => |page_index| self.reader.goToPage(page_index),
            };
            if (!moved) return;
            self.showCurrentPage();
            self.markProgressDirty();
            self.updateTitle();
            self.revealCurrentThumbnail();
            self.needs_redraw = true;
        }

        /// Puts the reader's page on screen: from the cache when it was
        /// rendered ahead of time, otherwise as paper until the render lands.
        fn showCurrentPage(self: *Self) void {
            const document = self.document orelse return;
            const page_index = self.reader.page_index;
            const dark_mode = self.preferences.dark_mode;
            if (self.page.texture) |texture| {
                if (self.page.page_index != page_index) {
                    self.pages.put(
                        self.page.page_index,
                        self.page.scale,
                        self.page.dark_mode,
                        texture,
                    );
                    self.page.texture = null;
                }
            }
            const size = document.pageSize(page_index) orelse default_page_size;
            const scale = self.desiredScale(size);
            const cached = self.pages.take(page_index, scale, dark_mode);
            self.page = .{
                .page_index = page_index,
                .size = size,
                .scale = if (cached != null) scale else 0,
                .dark_mode = dark_mode,
                .texture = cached,
            };
            if (cached == null) {
                self.page.requested_scale = scale;
                self.requestPage(page_index, scale, .immediate);
            }
            self.prefetchNeighbors();
        }

        fn toggleDarkMode(self: *Self) void {
            self.preferences.dark_mode = !self.preferences.dark_mode;
            self.markPreferencesDirty();
            self.refreshPage();
            self.needs_redraw = true;
        }

        fn zoomChanged(self: *Self) void {
            if (self.document != null) {
                self.render_timer = self.context.ticksMs() + page_render_delay_ms;
            }
            self.needs_redraw = true;
        }

        fn toolChanged(self: *Self) void {
            self.refreshLayout();
            self.needs_redraw = true;
        }

        /// Asks for the current page at the scale and theme it now needs.
        /// The old texture stays on screen, stretched, until the new one
        /// arrives, so zooming never flashes an empty page.
        fn refreshPage(self: *Self) void {
            const document = self.document orelse return;
            const page_index = self.reader.page_index;
            const dark_mode = self.preferences.dark_mode;
            const size = document.pageSize(page_index) orelse default_page_size;
            const scale = self.desiredScale(size);
            self.page.size = size;
            self.page.failed = false;
            const current = self.page.texture != null and self.page.dark_mode == dark_mode and
                page_cache.scalesMatch(self.page.scale, scale);
            if (current) {
                self.page.requested_scale = null;
                return;
            }
            // Every cached page was rendered for the old scale or theme.
            self.pages.clear();
            self.cancelPendingPages();
            self.page.requested_scale = scale;
            self.requestPage(page_index, scale, .immediate);
            self.prefetchNeighbors();
        }

        fn schedulePageRenderIfStale(self: *Self, density: f32) void {
            if (self.page.failed) return;
            const desired = renderScale(self.layout, self.page.size, self.reader.zoom(), density);
            const current = self.page.requested_scale orelse self.page.scale;
            const stale = current <= 0 or !page_cache.scalesMatch(desired, current) or
                self.page.dark_mode != self.preferences.dark_mode;
            if (!stale) return;
            // Restart the delay only while the target keeps moving, which is
            // what makes a resize render once, after the user pauses.
            if (self.render_timer == null or !page_cache.scalesMatch(desired, self.stale_scale)) {
                self.render_timer = self.context.ticksMs() + page_render_delay_ms;
                self.stale_scale = desired;
            }
        }

        fn desiredScale(self: *Self, page_size: Size) f32 {
            return renderScale(
                self.layout,
                page_size,
                self.reader.zoom(),
                self.context.pixelDensity(),
            );
        }

        fn scaleFor(self: *Self, page_size: Size, zoom: f32, options: ui.layout.Options) f32 {
            const layout = Layout.compute(self.window, options);
            return renderScale(layout, page_size, zoom, self.context.pixelDensity());
        }

        /// Device pixels per PDF point: exactly what the page occupies on
        /// screen, capped so extreme zooms never allocate giant textures.
        fn renderScale(layout: Layout, page_size: Size, zoom: f32, density: f32) f32 {
            const display_scale = layout.pageDisplayScale(page_size, zoom);
            const longest_side = @max(page_size.width, page_size.height);
            return @min(display_scale * density, ui.layout.maximum_page_pixels / longest_side);
        }

        fn requestPage(
            self: *Self,
            page_index: usize,
            scale: f32,
            priority: rendering.Priority,
        ) void {
            const document = self.document orelse return;
            const immediate = priority == .immediate;
            for (self.pending_pages.items) |*pending| {
                if (pending.page_index != page_index) continue;
                if (!page_cache.scalesMatch(pending.scale, scale)) continue;
                if (immediate and !pending.immediate) {
                    self.renders.reprioritize(pending.id, .immediate);
                    pending.immediate = true;
                }
                return;
            }
            if (immediate) {
                // Only the newest page the reader asked for is urgent.
                for (self.pending_pages.items) |*pending| {
                    if (!pending.immediate) continue;
                    self.renders.reprioritize(pending.id, .prefetch);
                    pending.immediate = false;
                }
            }
            const id = self.renders.submit(.{
                .document = document,
                .generation = self.generation,
                .page_index = page_index,
                .scale = scale,
                .dark_mode = self.preferences.dark_mode,
                .purpose = .page,
                .priority = priority,
            }) catch |err| {
                logFailure("request a page render", err);
                return;
            };
            self.pending_pages.append(self.allocator, .{
                .id = id,
                .page_index = page_index,
                .scale = scale,
                .immediate = immediate,
            }) catch |err| logFailure("track a page render", err);
        }

        /// Renders the pages before and after the current one ahead of time.
        fn prefetchNeighbors(self: *Self) void {
            const document = self.document orelse return;
            const page_index = self.reader.page_index;
            const page_count = self.reader.pageCount();
            const neighbors = [_]?usize{
                if (page_index + 1 < page_count) page_index + 1 else null,
                if (page_index > 0) page_index - 1 else null,
            };
            for (neighbors) |candidate| {
                const neighbor = candidate orelse continue;
                const size = document.pageSize(neighbor) orelse default_page_size;
                const scale = self.desiredScale(size);
                if (self.pages.contains(neighbor, scale, self.preferences.dark_mode)) continue;
                self.requestPage(neighbor, scale, .prefetch);
            }
        }

        fn cancelPendingPages(self: *Self) void {
            for (self.pending_pages.items) |pending| _ = self.renders.cancel(pending.id);
            self.pending_pages.clearRetainingCapacity();
        }

        fn forgetPending(self: *Self, id: u64) void {
            for (self.pending_pages.items, 0..) |pending, index| {
                if (pending.id != id) continue;
                _ = self.pending_pages.swapRemove(index);
                return;
            }
        }

        fn collectRenders(self: *Self) void {
            while (self.renders.poll(self.context.*, self.generation)) |result| {
                self.forgetPending(result.job.id);
                switch (result.job.purpose) {
                    .thumbnail => self.renderer.thumbnails.complete(
                        result.job.id,
                        result.job.page_index,
                        result.texture,
                    ),
                    .page => self.receivePage(result),
                }
                self.needs_redraw = true;
            }
        }

        /// Releases every finished render, whatever its generation.
        fn discardRenders(self: *Self) void {
            while (self.renders.poll(self.context.*, self.generation)) |result| {
                var texture = result.texture orelse continue;
                texture.deinit();
            }
        }

        fn receivePage(self: *Self, result: RenderResult) void {
            const job = result.job;
            const texture = result.texture orelse {
                std.log.warn("could not render page {d}", .{job.page_index + 1});
                if (job.page_index == self.reader.page_index and self.page.texture == null) {
                    self.page.failed = true;
                    self.page.requested_scale = null;
                    self.context.showError("This page could not be rendered.");
                }
                return;
            };
            const wanted_scale = self.page.requested_scale orelse self.desiredScale(self.page.size);
            const for_screen = job.page_index == self.reader.page_index and
                job.dark_mode == self.preferences.dark_mode and
                page_cache.scalesMatch(job.scale, wanted_scale);
            if (!for_screen) {
                self.pages.put(job.page_index, job.scale, job.dark_mode, texture);
                return;
            }
            if (self.page.texture) |*old| old.deinit();
            self.page.texture = texture;
            self.page.scale = job.scale;
            self.page.dark_mode = job.dark_mode;
            self.page.requested_scale = null;
            self.page.failed = false;
            self.prefetchNeighbors();
        }

        fn beginAnnotation(self: *Self, point: annotations.Point) void {
            if (self.document == null) return;
            switch (self.notebook.tool) {
                .off => {},
                .pen => {
                    const started = self.notebook.beginStroke(
                        self.reader.page_index,
                        point,
                    ) catch |err| {
                        logFailure("begin stroke", err);
                        return;
                    };
                    if (started) self.needs_redraw = true;
                },
                .eraser => self.eraseAnnotation(point),
            }
        }

        fn continueAnnotation(self: *Self, point: annotations.Point) void {
            switch (self.notebook.tool) {
                .off => {},
                .pen => {
                    const extended = self.notebook.appendPoint(point) catch |err| {
                        logFailure("extend stroke", err);
                        return;
                    };
                    if (extended) self.needs_redraw = true;
                },
                .eraser => self.eraseAnnotation(point),
            }
        }

        fn eraseAnnotation(self: *Self, point: annotations.Point) void {
            if (self.notebook.eraseAt(self.reader.page_index, point)) self.markNotesDirty();
        }

        fn finishAnnotation(self: *Self) void {
            const added_stroke = self.notebook.finishStroke() catch |err| {
                logFailure("finish stroke", err);
                self.notebook.cancelStroke();
                self.needs_redraw = true;
                return;
            };
            if (added_stroke) self.markNotesDirty();
        }

        fn markNotesDirty(self: *Self) void {
            self.notes.mark(self.context.ticksMs());
            self.save_status = .pending;
            self.needs_redraw = true;
        }

        fn markProgressDirty(self: *Self) void {
            self.progress_save.mark(self.context.ticksMs());
        }

        fn markPreferencesDirty(self: *Self) void {
            self.preferences_save.mark(self.context.ticksMs());
        }

        /// Queues the notes for writing. The status stays pending until the
        /// storage reports the write; see `collectSaveResults`.
        fn saveNotes(self: *Self) void {
            if (!self.notes.dirty) return;
            const key = self.document_key orelse return;
            const data = self.notebook.serialize(self.allocator) catch |err| {
                logFailure("serialize notes", err);
                self.markSaveFailed();
                return;
            };
            defer self.allocator.free(data);
            var name_buffer: [storage_module.name_capacity]u8 = undefined;
            self.storage.write(key.notesName(&name_buffer), data) catch |err| {
                logFailure("queue the notes", err);
                self.markSaveFailed();
                return;
            };
            self.notes.dirty = false;
        }

        fn markSaveFailed(self: *Self) void {
            self.save_status = .failed;
            self.needs_redraw = true;
        }

        fn saveProgress(self: *Self) void {
            if (!self.progress_save.dirty) return;
            const key = self.document_key orelse return;
            const data = progress.serialize(self.allocator, self.reader) catch |err| {
                logFailure("serialize progress", err);
                return;
            };
            defer self.allocator.free(data);
            var name_buffer: [storage_module.name_capacity]u8 = undefined;
            self.storage.write(key.progressName(&name_buffer), data) catch |err| {
                logFailure("queue the progress", err);
                return;
            };
            self.progress_save.dirty = false;
        }

        fn savePreferences(self: *Self) void {
            if (!self.preferences_save.dirty) return;
            const data = self.preferences.serialize(self.allocator) catch |err| {
                logFailure("serialize preferences", err);
                return;
            };
            defer self.allocator.free(data);
            self.storage.write(storage_module.preferences_name, data) catch |err| {
                logFailure("queue the preferences", err);
                return;
            };
            self.preferences_save.dirty = false;
        }

        /// Turns write completions into the save status shown in the margin.
        /// A failed notes write marks the notes dirty again, so the next edit
        /// retries; progress and preference failures were logged by the
        /// storage and are retried by the next change.
        fn collectSaveResults(self: *Self) void {
            while (self.storage.pollCompletion()) |completion| {
                const key = self.document_key orelse continue;
                var name_buffer: [storage_module.name_capacity]u8 = undefined;
                if (!completion.name.eql(key.notesName(&name_buffer))) continue;
                if (completion.failed) {
                    self.notes.dirty = true;
                    self.save_status = .failed;
                } else if (!self.notes.dirty) {
                    self.save_status = .saved;
                }
                self.needs_redraw = true;
            }
        }

        fn runSmokeTest(self: *Self) !void {
            self.notebook.tool = .pen;
            _ = try self.notebook.beginStroke(self.reader.page_index, .{ .x = 0.25, .y = 0.25 });
            _ = try self.notebook.appendPoint(.{ .x = 0.5, .y = 0.5 });
            if (!try self.notebook.finishStroke()) return error.AnnotationNotRecorded;
            self.markNotesDirty();
            self.flushState();
            if (self.save_status != .saved) return error.AnnotationSaveFailed;

            const key = self.document_key orelse return error.AnnotationLoadFailed;
            var name_buffer: [storage_module.name_capacity]u8 = undefined;
            const notes = try self.storage.read(self.allocator, key.notesName(&name_buffer));
            const data = notes orelse return error.AnnotationLoadFailed;
            defer self.allocator.free(data);
            var restored = annotations.Notebook.init(self.allocator);
            defer restored.deinit();
            try restored.open(self.reader.pageCount());
            _ = try restored.restore(data);
            if (restored.strokeCount() != self.notebook.strokeCount()) {
                return error.AnnotationRoundTripFailed;
            }
            self.draw();
        }

        fn trackMouse(self: *Self, position: Vec2) void {
            self.mouse = position;
            self.refreshHover();
        }

        /// Resolves the hover once; the renderer receives the result.
        fn refreshHover(self: *Self) void {
            const hover = self.layout.hoverAt(
                self.mouse,
                self.document != null,
                self.thumbnail_scroll,
                self.reader.pageCount(),
            );
            if (std.meta.eql(hover, self.hover)) return;
            self.hover = hover;
            self.needs_redraw = true;
        }

        fn layoutOptions(self: *Self) ui.layout.Options {
            return .{
                .document_open = self.document != null,
                .navigation_visible = self.document != null and self.navigation_visible,
                .annotations_enabled = self.notebook.tool != .off,
            };
        }

        /// The layout depends on the window size and three flags; it is
        /// recomputed when one of them changes and read everywhere else.
        fn refreshLayout(self: *Self) void {
            self.layout = Layout.compute(self.window, self.layoutOptions());
        }

        fn pageRect(self: *Self) ?Rect {
            if (self.document == null) return null;
            return self.layout.pageRect(self.page.size, self.reader.zoom());
        }

        fn inputState(self: *Self) ui.input.State {
            return .{
                .layout = self.layout,
                .page_rect = self.pageRect(),
                .tool = self.notebook.tool,
                .document_open = self.document != null,
                .page_count = self.reader.pageCount(),
                .thumbnail_scroll = self.thumbnail_scroll,
                .stroke_active = self.notebook.hasActiveStroke(),
                .scrollbar_dragging = self.scrollbar_grab != null,
            };
        }

        /// Scrolls the rail to a clamped position and repaints when it moved.
        fn scrollRailTo(self: *Self, scroll: f32) void {
            const clamped = self.layout.clampThumbnailScroll(scroll, self.reader.pageCount());
            if (clamped == self.thumbnail_scroll) return;
            self.thumbnail_scroll = clamped;
            self.needs_redraw = true;
        }

        fn revealCurrentThumbnail(self: *Self) void {
            self.thumbnail_scroll = self.layout.revealThumbnail(
                self.thumbnail_scroll,
                self.reader.page_index,
                self.reader.pageCount(),
            );
        }

        fn documentTitle(self: *Self) []const u8 {
            const document = self.document orelse return "Open PDF";
            return lectern.baseName(document.path());
        }

        fn updateTitle(self: *Self) void {
            var title_buffer: [512]u8 = undefined;
            const title = std.fmt.bufPrintZ(
                &title_buffer,
                "Lectern - {s} - page {d}/{d}",
                .{ self.documentTitle(), self.reader.page_index + 1, self.reader.pageCount() },
            ) catch "Lectern";
            self.context.setTitle(title);
        }

        /// Failures the user already sees in a dialog are logged as warnings;
        /// errors are reserved for conditions nobody handled.
        fn reportOpenFailure(self: *Self, err: OpenError) void {
            std.log.warn("could not open PDF: {s}", .{@errorName(err)});
            switch (err) {
                error.InvalidPdf, error.PageRenderFailed => {
                    self.context.showError(self.context.lastError());
                },
                error.EmptyDocument => self.context.showError("The PDF has no pages."),
                error.OutOfMemory => self.context.showError("Not enough memory to open the PDF."),
            }
        }
    };
}

fn logFailure(operation: []const u8, err: anytype) void {
    std.log.warn("could not {s}: {s}", .{ operation, @errorName(err) });
}

const mock = @import("testing/mock_backend.zig");
const TestApplication = ApplicationType(mock.Backend);

/// Owns the borrowed backend pieces at stable addresses for one test.
const Harness = struct {
    context: mock.Backend.Context,
    storage: mock.Backend.Storage,
    renders: mock.Backend.RenderQueue,
    application: TestApplication,
    released: bool,

    fn init(self: *Harness, allocator: std.mem.Allocator, state: *mock.State) void {
        self.context = .{ .state = state };
        self.storage = .{ .state = state };
        self.renders = .{ .state = state };
        self.application = TestApplication.init(
            allocator,
            &self.context,
            &self.storage,
            &self.renders,
        );
        self.released = false;
    }

    /// Idempotent, so a test can release early to inspect the counters and
    /// still `defer` the release for the failure path.
    fn deinit(self: *Harness) void {
        if (self.released) return;
        self.released = true;
        self.application.deinit();
    }
};

fn seedNotes(state: *mock.State, path: []const u8, page_count: usize) !void {
    var notebook = annotations.Notebook.init(std.testing.allocator);
    defer notebook.deinit();
    try notebook.open(page_count);
    notebook.selectPen();
    _ = try notebook.beginStroke(1, .{ .x = 0.2, .y = 0.3 });
    _ = try notebook.finishStroke();
    _ = try notebook.beginStroke(page_count - 1, .{ .x = 0.4, .y = 0.5 });
    _ = try notebook.finishStroke();
    const data = try notebook.serialize(std.testing.allocator);
    defer std.testing.allocator.free(data);
    var name_buffer: [storage_module.name_capacity]u8 = undefined;
    try state.putFile(DocumentKey.of(path).notesName(&name_buffer), data);
}

fn seedProgress(state: *mock.State, path: []const u8, data: []const u8) !void {
    var name_buffer: [storage_module.name_capacity]u8 = undefined;
    try state.putFile(DocumentKey.of(path).progressName(&name_buffer), data);
}

fn storedProgress(state: *mock.State, path: []const u8) ?[]const u8 {
    var name_buffer: [storage_module.name_capacity]u8 = undefined;
    return state.getFile(DocumentKey.of(path).progressName(&name_buffer));
}

fn storedNotes(state: *mock.State, path: []const u8) ?[]const u8 {
    var name_buffer: [storage_module.name_capacity]u8 = undefined;
    return state.getFile(DocumentKey.of(path).notesName(&name_buffer));
}

fn expectNoTextureLeaks(state: *const mock.State) !void {
    try std.testing.expectEqual(state.texture_create_count, state.texture_deinit_count);
}

test "application opens a document and restores all persisted state" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    try seedProgress(&state, "library/book.pdf", "page 1\nbookmark 1\n");
    try seedNotes(&state, "library/book.pdf", 3);
    try state.putFile(storage_module.preferences_name, "dark 0\n");
    var harness: Harness = undefined;
    harness.init(std.testing.allocator, &state);
    defer harness.deinit();
    const application = &harness.application;
    application.loadPreferences();
    try application.openPdf("library/book.pdf");

    try std.testing.expectEqual(@as(usize, 1), application.reader.page_index);
    try std.testing.expect(!application.preferences.dark_mode);
    try std.testing.expect(application.reader.isCurrentPageBookmarked());
    try std.testing.expectEqual(@as(usize, 2), application.notebook.strokeCount());
    try std.testing.expectEqual(@as(usize, 1), application.page.page_index);
    try std.testing.expect(application.page.texture != null);
    try std.testing.expect(!state.last_render_dark_mode);
    try std.testing.expectEqualStrings("Lectern - book.pdf - page 2/3", state.titleText());
    try std.testing.expectEqual(@as(?u64, null), application.render_timer);
    // The first page renders before the open commits; both neighbors follow.
    try std.testing.expectEqual(@as(usize, 3), state.render_count);

    harness.deinit();
    try std.testing.expectEqual(@as(usize, 1), state.document_deinit_count);
    try expectNoTextureLeaks(&state);
    try std.testing.expectEqual(@as(usize, 0), state.context_deinit_count);
}

test "pages render at the size they occupy on screen" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    state.density = 2;
    var harness: Harness = undefined;
    harness.init(std.testing.allocator, &state);
    defer harness.deinit();
    const application = &harness.application;
    try application.openPdf("book.pdf");

    const letter = TestApplication.default_page_size;
    const expected = application.layout.pageDisplayScale(letter, 1.0) * 2;
    try std.testing.expectApproxEqAbs(expected, state.last_render_scale, 0.001);
    try std.testing.expect(state.last_render_scale * 792 < ui.layout.maximum_page_pixels);

    var index: usize = 0;
    while (index < 15) : (index += 1) application.handleCommand(.zoom_in);
    try std.testing.expect(application.render_timer != null);
    application.update(state.ticks + TestApplication.page_render_delay_ms);
    try std.testing.expectApproxEqAbs(
        ui.layout.maximum_page_pixels / 792,
        state.last_render_scale,
        0.001,
    );
    try std.testing.expectApproxEqAbs(
        ui.layout.maximum_page_pixels / 792,
        application.page.scale,
        0.001,
    );
}

test "the theme is an application preference that survives opening documents" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    try seedProgress(&state, "old.pdf", "page 0\ndark 0\n");
    var harness: Harness = undefined;
    harness.init(std.testing.allocator, &state);
    defer harness.deinit();
    const application = &harness.application;
    application.loadPreferences();
    try std.testing.expect(application.preferences.dark_mode);

    // A legacy per-document theme is adopted once when no preferences exist,
    // and the page already on screen is re-rendered for it.
    try application.openPdf("old.pdf");
    try std.testing.expect(!application.preferences.dark_mode);
    try std.testing.expect(application.preferences_loaded);
    application.update(state.ticks);
    try std.testing.expect(!application.page.dark_mode);
    application.flushState();
    const migrated = state.getFile(storage_module.preferences_name).?;
    try std.testing.expectEqualStrings("dark 0\n", migrated);

    application.handleCommand(.toggle_dark_mode);
    try std.testing.expect(application.preferences.dark_mode);
    try std.testing.expect(state.last_render_dark_mode);
    application.update(state.ticks);
    try std.testing.expect(application.page.dark_mode);
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
    var harness: Harness = undefined;
    harness.init(std.testing.allocator, &state);
    defer harness.deinit();
    const application = &harness.application;
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
    var harness: Harness = undefined;
    harness.init(std.testing.allocator, &state);
    defer harness.deinit();
    const application = &harness.application;
    try application.openPdf("current.pdf");
    application.update(state.ticks);

    state.fail_open = true;
    try std.testing.expectError(error.InvalidPdf, application.openPdf("invalid.pdf"));
    try std.testing.expectEqualStrings("current.pdf", application.document.?.path());
    try std.testing.expectEqual(@as(usize, 0), state.document_deinit_count);

    state.fail_open = false;
    state.fail_render = true;
    try std.testing.expectError(error.PageRenderFailed, application.openPdf("broken.pdf"));
    try std.testing.expectEqualStrings("current.pdf", application.document.?.path());
    try std.testing.expectEqual(@as(usize, 1), state.document_deinit_count);
    try std.testing.expect(application.page.texture != null);

    application.handleCommand(.{ .open_path = "still-broken.pdf" });
    try std.testing.expectEqual(@as(usize, 1), state.show_error_count);
    try std.testing.expectEqualStrings("current.pdf", application.document.?.path());
}

test "empty documents fail transactionally before rendering" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    state.page_count = 0;
    var harness: Harness = undefined;
    harness.init(std.testing.allocator, &state);
    defer harness.deinit();
    const application = &harness.application;

    try std.testing.expectError(error.EmptyDocument, application.openPdf("empty.pdf"));
    try std.testing.expectEqual(@as(?mock.Backend.Document, null), application.document);
    try std.testing.expectEqual(@as(usize, 1), state.document_deinit_count);
    try std.testing.expectEqual(@as(usize, 0), state.render_count);
}

test "successful document replacement releases and saves the previous document" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    var harness: Harness = undefined;
    harness.init(std.testing.allocator, &state);
    defer harness.deinit();
    const application = &harness.application;
    try application.openPdf("first.pdf");
    application.handleCommand(.next_page);
    application.update(state.ticks);
    application.handleCommand(.pen);
    application.handleCommand(.{ .draw_begin = .{ .x = 0.1, .y = 0.1 } });
    try application.openPdf("second.pdf");

    try std.testing.expectEqualStrings("second.pdf", application.document.?.path());
    try std.testing.expectEqual(@as(usize, 2), state.document_open_count);
    try std.testing.expectEqual(@as(usize, 1), state.document_deinit_count);
    try std.testing.expectEqualStrings("page 1\n", storedProgress(&state, "first.pdf").?);
    try std.testing.expect(storedNotes(&state, "first.pdf") != null);
    try std.testing.expect(!application.notes.dirty);
    try std.testing.expectEqual(@as(?u64, null), application.notes.due);
    try std.testing.expectEqual(@as(u64, 2), application.generation);

    harness.deinit();
    try expectNoTextureLeaks(&state);
}

test "render results of a replaced document are dropped unseen" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    state.auto_complete_renders = false;
    var harness: Harness = undefined;
    harness.init(std.testing.allocator, &state);
    defer harness.deinit();
    const application = &harness.application;
    try application.openPdf("first.pdf");
    try std.testing.expectEqual(@as(usize, 1), state.pendingRenderCount());
    // The prefetch of the first document finishes, but its result is only
    // collected after the document was replaced.
    try std.testing.expect(state.completeRender());

    try application.openPdf("second.pdf");
    application.update(state.ticks);
    try std.testing.expectEqual(@as(usize, 0), application.pages.count());
    try std.testing.expect(application.page.texture != null);
    try std.testing.expectEqual(@as(usize, 0), application.page.page_index);

    harness.deinit();
    try expectNoTextureLeaks(&state);
}

test "page turns come from the cache when rendered ahead of time" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    state.auto_complete_renders = false;
    state.page_count = 5;
    var harness: Harness = undefined;
    harness.init(std.testing.allocator, &state);
    defer harness.deinit();
    const application = &harness.application;
    application.navigation_visible = false;
    try application.openPdf("book.pdf");
    // Only the next page is prefetched from the first page.
    try std.testing.expectEqual(@as(usize, 1), state.pendingRenderCount());
    const submitted = state.submitted_job_count;

    // Turning the page before the prefetch finished promotes that request
    // instead of making a second one; paper is shown meanwhile. The new
    // neighbor, page 2, is requested behind it.
    application.handleCommand(.next_page);
    try std.testing.expectEqual(submitted + 1, state.submitted_job_count);
    try std.testing.expectEqual(@as(usize, 2), state.pendingRenderCount());
    try std.testing.expectEqual(@as(?mock.Backend.Texture, null), application.page.texture);
    try std.testing.expectEqual(@as(usize, 1), application.pages.count());
    application.draw();
    // The promoted request runs first.
    try std.testing.expect(state.completeRender());
    try std.testing.expectEqual(@as(usize, 1), state.last_render_page);
    application.update(state.ticks);
    try std.testing.expect(application.page.texture != null);
    try std.testing.expectEqual(@as(usize, 1), application.page.page_index);
    try std.testing.expectEqual(@as(usize, 1), state.pendingRenderCount());

    // Going back is instant because the page was kept when the reader left it.
    application.handleCommand(.previous_page);
    try std.testing.expect(application.page.texture != null);
    try std.testing.expectEqual(@as(usize, 0), application.page.page_index);
    state.completeAllRenders();
    application.update(state.ticks);
    const dark_mode = application.preferences.dark_mode;
    try std.testing.expect(application.pages.contains(1, application.page.scale, dark_mode));
    try std.testing.expect(application.pages.contains(2, application.page.scale, dark_mode));

    harness.deinit();
    try expectNoTextureLeaks(&state);
}

test "a failed page render is reported once and not retried until something changes" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    var harness: Harness = undefined;
    harness.init(std.testing.allocator, &state);
    defer harness.deinit();
    const application = &harness.application;
    application.navigation_visible = false;
    try application.openPdf("book.pdf");
    application.update(state.ticks);

    state.fail_render = true;
    application.handleCommand(.next_page);
    application.handleCommand(.next_page);
    try std.testing.expectEqual(@as(usize, 2), application.reader.page_index);
    application.update(state.ticks);
    try std.testing.expect(application.page.failed);
    try std.testing.expectEqual(@as(?mock.Backend.Texture, null), application.page.texture);
    try std.testing.expectEqual(@as(usize, 1), state.show_error_count);
    const submitted = state.submitted_job_count;
    application.draw();
    application.update(state.ticks + TestApplication.page_render_delay_ms);
    try std.testing.expectEqual(submitted, state.submitted_job_count);
    try std.testing.expectEqual(@as(usize, 1), state.show_error_count);

    // The theme toggle is a change; the page is rendered again and lands.
    state.fail_render = false;
    application.handleCommand(.toggle_dark_mode);
    application.update(state.ticks);
    try std.testing.expect(!application.page.failed);
    try std.testing.expect(application.page.texture != null);
    try std.testing.expectEqual(application.preferences.dark_mode, application.page.dark_mode);
}

test "annotation edits are saved after a short delay and flushed on demand" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    var harness: Harness = undefined;
    harness.init(std.testing.allocator, &state);
    defer harness.deinit();
    const application = &harness.application;
    try application.openPdf("book.pdf");

    application.handleCommand(.pen);
    application.handleCommand(.{ .draw_begin = .{ .x = 0.1, .y = 0.1 } });
    application.handleCommand(.{ .draw_move = .{ .x = 0.5, .y = 0.5 } });
    application.handleCommand(.draw_end);
    try std.testing.expect(application.notes.dirty);
    try std.testing.expectEqual(SaveStatus.pending, application.save_status);
    try std.testing.expectEqual(@as(usize, 0), state.write_count);
    try std.testing.expectEqual(
        @as(?u32, @intCast(TestApplication.save_delay_ms)),
        application.waitTimeout(state.ticks),
    );

    application.update(state.ticks + TestApplication.save_delay_ms - 1);
    try std.testing.expectEqual(@as(usize, 0), state.write_count);
    application.update(state.ticks + TestApplication.save_delay_ms);
    try std.testing.expectEqual(@as(usize, 1), state.write_count);
    try std.testing.expect(!application.notes.dirty);
    try std.testing.expectEqual(SaveStatus.saved, application.save_status);
    try std.testing.expectEqual(@as(?u32, null), application.waitTimeout(state.ticks));

    application.handleCommand(.eraser);
    application.handleCommand(.{ .draw_begin = .{ .x = 0.3, .y = 0.3 } });
    application.handleCommand(.draw_end);
    try std.testing.expectEqual(@as(usize, 0), application.notebook.strokeCount());
    try std.testing.expect(application.notes.dirty);
    application.flushState();
    try std.testing.expectEqual(@as(usize, 2), state.write_count);
    try std.testing.expect(!application.notes.dirty);
}

test "save failures are shown and retried on the next edit" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    var harness: Harness = undefined;
    harness.init(std.testing.allocator, &state);
    defer harness.deinit();
    const application = &harness.application;
    try application.openPdf("book.pdf");
    application.handleCommand(.pen);
    application.handleCommand(.{ .draw_begin = .{ .x = 0.1, .y = 0.1 } });
    application.handleCommand(.draw_end);

    state.fail_write = true;
    application.flushState();
    try std.testing.expectEqual(SaveStatus.failed, application.save_status);
    try std.testing.expect(application.notes.dirty);

    state.fail_write = false;
    application.handleCommand(.note_undo);
    try std.testing.expectEqual(SaveStatus.pending, application.save_status);
    application.flushState();
    try std.testing.expectEqual(SaveStatus.saved, application.save_status);
    try std.testing.expect(!application.notes.dirty);

    // Storage that rejects the write outright is reported the same way.
    application.handleCommand(.{ .draw_begin = .{ .x = 0.2, .y = 0.2 } });
    application.handleCommand(.draw_end);
    state.storage_available = false;
    application.flushState();
    try std.testing.expectEqual(SaveStatus.failed, application.save_status);
    try std.testing.expect(application.notes.dirty);
}

test "application routes navigation, editing, dialog, and quit commands" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    var harness: Harness = undefined;
    harness.init(std.testing.allocator, &state);
    defer harness.deinit();
    const application = &harness.application;
    try application.openPdf("book.pdf");

    application.handleCommand(.next_page);
    application.handleCommand(.previous_page);
    application.handleCommand(.last_page);
    try std.testing.expectEqual(@as(usize, 2), application.reader.page_index);
    application.handleCommand(.first_page);
    application.handleCommand(.toggle_pages);
    try std.testing.expect(!application.navigation_visible);
    try std.testing.expectEqual(@as(f32, 0), application.layout.navigation_width);
    application.handleCommand(.toggle_pages);
    try std.testing.expect(application.navigation_visible);
    application.handleCommand(.{ .select_page = 2 });
    try std.testing.expectEqual(@as(usize, 2), application.reader.page_index);
    application.handleCommand(.{ .select_page = 99 });
    try std.testing.expectEqual(@as(usize, 2), application.reader.page_index);
    application.handleCommand(.first_page);
    application.handleCommand(.zoom_in);
    try std.testing.expect(application.render_timer != null);
    application.handleCommand(.zoom_reset);
    application.handleCommand(.zoom_out);
    try std.testing.expectEqual(@as(u32, 90), application.reader.zoomPercent());
    application.handleCommand(.toggle_bookmark);
    try std.testing.expect(application.progress_save.dirty);
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
    try std.testing.expect(application.layout.panel != null);
    application.handleCommand(.notes_off);
    try std.testing.expectEqual(annotations.Tool.off, application.notebook.tool);
    try std.testing.expect(application.layout.panel == null);

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

test "only commands that change something schedule a repaint" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    var harness: Harness = undefined;
    harness.init(std.testing.allocator, &state);
    defer harness.deinit();
    const application = &harness.application;
    try application.openPdf("book.pdf");
    application.update(state.ticks);

    const unchanged = [_]Command{
        .previous_page,
        .first_page,
        .zoom_reset,
        .notes_off,
        .{ .select_color = .blue },
        .{ .select_size = .medium },
        .{ .scroll_thumbnails = 1 },
        .note_undo,
        .note_clear,
        .{ .select_page = 0 },
        .dialog_closed,
    };
    for (unchanged) |command| {
        application.needs_redraw = false;
        application.handleCommand(command);
        try std.testing.expect(!application.needs_redraw);
    }
    const changed = [_]Command{
        .next_page,
        .zoom_in,
        .toggle_bookmark,
        .pen,
        .cycle_color,
        .redraw,
    };
    for (changed) |command| {
        application.needs_redraw = false;
        application.handleCommand(command);
        try std.testing.expect(application.needs_redraw);
    }
}

test "raw input drives commands, hover redraws, and owned paths" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    var harness: Harness = undefined;
    harness.init(std.testing.allocator, &state);
    defer harness.deinit();
    const application = &harness.application;
    try application.openPdf("book.pdf");
    application.needs_redraw = false;

    application.handleInput(.{ .kind = .mouse_motion, .position = .{ .x = 600, .y = 400 } });
    try std.testing.expect(!application.needs_redraw);
    const next_button = application.layout.toolbar.next;
    const window_size_calls = state.window_size_count;
    application.handleInput(.{
        .kind = .mouse_motion,
        .position = .{ .x = next_button.centerX(), .y = next_button.centerY() },
    });
    try std.testing.expect(application.needs_redraw);
    try std.testing.expect(application.hover.isToolbar(.next));
    // Pointer moves use the cached layout instead of asking the window.
    try std.testing.expectEqual(window_size_calls, state.window_size_count);
    application.needs_redraw = false;
    application.handleInput(.{
        .kind = .mouse_down,
        .button = .left,
        .position = .{ .x = next_button.centerX(), .y = next_button.centerY() },
    });
    try std.testing.expectEqual(@as(usize, 1), application.reader.page_index);
    try std.testing.expect(application.needs_redraw);

    // Leaving the window clears the highlight; a render notification only
    // wakes the loop.
    application.needs_redraw = false;
    application.handleInput(.{ .kind = .mouse_leave });
    try std.testing.expectEqual(@as(?Vec2, null), application.mouse);
    try std.testing.expectEqual(Hover.none, application.hover);
    try std.testing.expect(application.needs_redraw);
    application.needs_redraw = false;
    application.handleInput(.{ .kind = .render_ready });
    try std.testing.expect(!application.needs_redraw);

    application.handleInput(.{ .kind = .key_down, .key = .d });
    try std.testing.expect(!application.preferences.dark_mode);
    application.handleInput(.{ .kind = .none });

    state.window = .{ .width = 1400, .height = 900 };
    application.handleInput(.{ .kind = .window });
    try std.testing.expectEqual(@as(f32, 1400), application.layout.window.width);

    const path = try std.testing.allocator.dupe(u8, "dropped.pdf");
    application.handleInput(.{ .kind = .file, .path = path });
    try std.testing.expectEqualStrings("dropped.pdf", application.document.?.path());
}

fn exerciseApplicationAllocations(allocator: std.mem.Allocator) !void {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    try seedProgress(&state, "allocation-test.pdf", "page 1\nbookmark 2\n");
    try seedNotes(&state, "allocation-test.pdf", 3);
    var harness: Harness = undefined;
    harness.init(allocator, &state);
    defer harness.deinit();
    try harness.application.openPdf("allocation-test.pdf");
    harness.application.update(state.ticks);
    try harness.application.openPdf("allocation-test.pdf");
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
    var harness: Harness = undefined;
    harness.init(std.testing.allocator, &state);
    defer harness.deinit();
    const application = &harness.application;

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
    var name_buffer: [storage_module.name_capacity]u8 = undefined;
    try state.putFile(DocumentKey.of("book.pdf").notesName(&name_buffer), "oops");
    var harness: Harness = undefined;
    harness.init(std.testing.allocator, &state);
    defer harness.deinit();
    const application = &harness.application;

    try application.openPdf("book.pdf");
    try std.testing.expect(application.reader.isOpen());
    try std.testing.expectEqual(@as(usize, 0), application.notebook.strokeCount());
}

test "notes of pages a shorter PDF revision no longer has are skipped" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    try seedNotes(&state, "revised.pdf", 6);
    state.page_count = 3;
    var harness: Harness = undefined;
    harness.init(std.testing.allocator, &state);
    defer harness.deinit();
    const application = &harness.application;

    try application.openPdf("revised.pdf");
    try std.testing.expectEqual(@as(usize, 1), application.notebook.strokeCount());
    try std.testing.expectEqual(@as(usize, 1), application.notebook.strokesOn(1).len);
}

test "interactive run loop waits for input, redraws on demand, and exits" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    state.inputs_arrive_while_waiting = true;
    try state.pushInput(.{ .kind = .key_down, .key = .p });
    try state.pushInput(.{ .kind = .mouse_motion, .position = .{ .x = 5, .y = 5 } });
    try state.pushInput(.{ .kind = .quit });
    var harness: Harness = undefined;
    harness.init(std.testing.allocator, &state);
    defer harness.deinit();
    const application = &harness.application;

    try application.run(.{});
    // Starting without a document never opens the file dialog by itself.
    try std.testing.expectEqual(@as(usize, 0), state.open_dialog_count);
    try std.testing.expect(!application.dialog_open);
    try std.testing.expectEqual(annotations.Tool.pen, application.notebook.tool);
    // The first frame, then one after the pen command; the hover and the quit
    // command do not repaint.
    try std.testing.expectEqual(@as(usize, 2), state.frame_count);
    try std.testing.expectEqual(@as(usize, 3), state.wait_count);
    // Nothing is due, so the loop sleeps until something happens.
    try std.testing.expectEqual(@as(?u32, null), state.last_wait_timeout);
    try std.testing.expect(!application.running);
}

test "a loop step drains queued input, runs timers, and repaints once" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    try state.pushInput(.{ .kind = .key_down, .key = .p });
    try state.pushInput(.{ .kind = .key_down, .key = .c });
    var harness: Harness = undefined;
    harness.init(std.testing.allocator, &state);
    defer harness.deinit();
    const application = &harness.application;
    try application.openPdf("book.pdf");
    application.needs_redraw = false;

    application.step(state.takeInput(std.testing.allocator));
    try std.testing.expectEqual(annotations.Tool.pen, application.notebook.tool);
    try std.testing.expectEqual(annotations.Color.red, application.notebook.color);
    try std.testing.expectEqual(@as(usize, 1), state.frame_count);
    try std.testing.expect(!application.needs_redraw);

    // A step without input still runs due timers.
    application.handleCommand(.zoom_in);
    state.ticks += TestApplication.page_render_delay_ms;
    const renders = state.render_count;
    application.step(null);
    try std.testing.expect(state.render_count > renders);
    try std.testing.expectEqual(@as(?u64, null), application.render_timer);
}

test "drawing without a document shows the empty state and never renders" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    var harness: Harness = undefined;
    harness.init(std.testing.allocator, &state);
    defer harness.deinit();
    const application = &harness.application;
    application.draw();
    try std.testing.expectEqual(@as(usize, 1), state.frame_count);
    try std.testing.expectEqual(@as(usize, 0), state.render_count);
    try std.testing.expectEqual(@as(?u64, null), application.render_timer);
}

test "a continuous resize re-renders the page once, after the user pauses" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    state.page_count = 1;
    var harness: Harness = undefined;
    harness.init(std.testing.allocator, &state);
    defer harness.deinit();
    const application = &harness.application;
    application.navigation_visible = false;
    try application.openPdf("book.pdf");
    application.update(state.ticks);
    application.draw();
    try std.testing.expectEqual(@as(?u64, null), application.render_timer);
    const renders_before = state.render_count;

    // The window grows every 40 ms for over a second; the page is limited by
    // the window height, so every step changes the display scale.
    var height: f32 = 820;
    while (state.ticks < 1200) : (state.ticks += 40) {
        height += 15;
        state.window = .{ .width = 1100, .height = height };
        application.handleCommand(.redraw);
        application.update(state.ticks);
        application.draw();
        try std.testing.expect(application.render_timer != null);
    }
    try std.testing.expectEqual(renders_before, state.render_count);

    application.update(state.ticks + TestApplication.page_render_delay_ms);
    try std.testing.expectEqual(renders_before + 1, state.render_count);
    try std.testing.expect(application.page.texture != null);
    application.draw();
    try std.testing.expectEqual(@as(?u64, null), application.render_timer);
}

test "thumbnails are requested from the renderer's report and delivered by the queue" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    state.page_count = 8;
    state.auto_complete_renders = false;
    var harness: Harness = undefined;
    harness.init(std.testing.allocator, &state);
    defer harness.deinit();
    const application = &harness.application;
    try application.openPdf("book.pdf");
    application.draw();
    const requested = application.renderer.thumbnails.pendingCount();
    try std.testing.expect(requested > 0);
    application.draw();
    try std.testing.expectEqual(requested, application.renderer.thumbnails.pendingCount());

    state.completeAllRenders();
    application.update(state.ticks);
    try std.testing.expectEqual(requested, application.renderer.thumbnails.liveCount());
    try std.testing.expect(application.needs_redraw);

    harness.deinit();
    try expectNoTextureLeaks(&state);
}

test "smoke run requires a document and validates annotation round trips" {
    var missing_state = mock.State.init(std.testing.allocator);
    defer missing_state.deinit();
    var missing_harness: Harness = undefined;
    missing_harness.init(std.testing.allocator, &missing_state);
    defer missing_harness.deinit();
    try std.testing.expectError(
        error.SmokeTestRequiresDocument,
        missing_harness.application.run(.{ .smoke_test = true }),
    );

    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    try seedNotes(&state, "smoke.pdf", 3);
    var harness: Harness = undefined;
    harness.init(std.testing.allocator, &state);
    defer harness.deinit();
    const application = &harness.application;
    try application.run(.{ .initial_path = "smoke.pdf", .smoke_test = true });
    // Existing notes are kept; the smoke stroke is added to them.
    try std.testing.expectEqual(@as(usize, 3), application.notebook.strokeCount());
    try std.testing.expect(storedNotes(&state, "smoke.pdf") != null);
    try std.testing.expectEqual(@as(usize, 1), state.frame_count);
    try std.testing.expect(state.triangle_batch_count >= 1);

    var failing_state = mock.State.init(std.testing.allocator);
    defer failing_state.deinit();
    failing_state.storage_available = false;
    var failing_harness: Harness = undefined;
    failing_harness.init(std.testing.allocator, &failing_state);
    defer failing_harness.deinit();
    try std.testing.expectError(
        error.AnnotationSaveFailed,
        failing_harness.application.run(.{ .initial_path = "smoke.pdf", .smoke_test = true }),
    );
}

test "the rail scrollbar can be dragged with the pointer" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    state.page_count = 40;
    var harness: Harness = undefined;
    harness.init(std.testing.allocator, &state);
    defer harness.deinit();
    const application = &harness.application;
    try application.openPdf("long.pdf");
    application.update(state.ticks);
    const layout = application.layout;
    const bar = layout.thumbnailScrollbar(0, 40).?;
    const thumb_x = layout.navigation_width - 6;

    // Hovering the thumb highlights it; pressing grabs it.
    application.needs_redraw = false;
    application.handleInput(.{
        .kind = .mouse_motion,
        .position = .{ .x = thumb_x, .y = bar.thumb.y + 8 },
    });
    try std.testing.expect(application.hover.isScrollbar());
    try std.testing.expect(application.needs_redraw);
    application.handleInput(.{
        .kind = .mouse_down,
        .button = .left,
        .position = .{ .x = thumb_x, .y = bar.thumb.y + 8 },
    });
    try std.testing.expectApproxEqAbs(@as(f32, 8), application.scrollbar_grab.?, 0.01);
    try std.testing.expectEqual(@as(f32, 0), application.thumbnail_scroll);

    // Dragging keeps the grabbed point under the pointer, even far from the rail.
    application.needs_redraw = false;
    application.handleInput(.{
        .kind = .mouse_motion,
        .left_held = true,
        .position = .{ .x = 600, .y = bar.thumb.y + 8 + 100 },
    });
    try std.testing.expect(application.needs_redraw);
    const dragged = application.layout.thumbnailScrollbar(application.thumbnail_scroll, 40).?;
    try std.testing.expectApproxEqAbs(bar.thumb.y + 100, dragged.thumb.y, 0.5);
    try std.testing.expect(application.thumbnail_scroll > 0);
    try std.testing.expect(!application.notebook.hasActiveStroke());

    // Releasing ends the drag; a later move without the button does nothing.
    application.handleInput(.{
        .kind = .mouse_up,
        .button = .left,
        .position = .{ .x = 600, .y = 700 },
    });
    try std.testing.expectEqual(@as(?f32, null), application.scrollbar_grab);
    const after_release = application.thumbnail_scroll;
    application.handleInput(.{ .kind = .mouse_motion, .position = .{ .x = 600, .y = 750 } });
    try std.testing.expectEqual(after_release, application.thumbnail_scroll);

    // A click on the track jumps so the thumb centers there; the drag is
    // clamped at the ends of the track.
    application.handleInput(.{
        .kind = .mouse_down,
        .button = .left,
        .position = .{ .x = thumb_x, .y = bar.track.bottom() - 2 },
    });
    try std.testing.expectEqual(layout.thumbnailMaxScroll(40), application.thumbnail_scroll);
    application.handleCommand(.{ .scrollbar_grab = 0 });
    application.handleCommand(.{ .scrollbar_drag = -1000 });
    try std.testing.expectEqual(@as(f32, 0), application.thumbnail_scroll);
    application.handleCommand(.scrollbar_release);

    // Hiding the rail lets go of the thumb, and without a document nothing
    // can be grabbed.
    application.handleCommand(.{ .scrollbar_grab = 4 });
    application.handleCommand(.toggle_pages);
    try std.testing.expectEqual(@as(?f32, null), application.scrollbar_grab);
    application.handleCommand(.{ .scrollbar_grab = 4 });
    try std.testing.expectEqual(@as(?f32, null), application.scrollbar_grab);
}

test "a path that fails to open reports the failure and waits for the user" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    state.fail_open = true;
    state.inputs_arrive_while_waiting = true;
    try state.pushInput(.{ .kind = .key_down, .key = .o });
    try state.pushInput(.{ .kind = .quit });
    var harness: Harness = undefined;
    harness.init(std.testing.allocator, &state);
    defer harness.deinit();
    const application = &harness.application;

    try application.run(.{ .initial_path = "missing.pdf" });
    try std.testing.expectEqual(@as(usize, 1), state.show_error_count);
    try std.testing.expectEqual(@as(?mock.Backend.Document, null), application.document);
    // The dialog opened once, when the user pressed O, not before.
    try std.testing.expectEqual(@as(usize, 1), state.open_dialog_count);
    try std.testing.expect(application.dialog_open);
    try std.testing.expect(!application.running);
}
