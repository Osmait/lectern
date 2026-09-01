//! Draws a frame through the backend's primitives.
//!
//! The renderer owns every texture cache and scratch buffer. It reads only the
//! `Frame` and the layout it is given, plus the page texture, so the same code
//! paints the real window and the in-memory test backend. Finished strokes
//! are tessellated once per page revision and drawn as one batch.

const std = @import("std");
const book_read = @import("book_read");
const annotations = book_read.annotations;
const layout_module = @import("layout.zig");
const theme_module = @import("theme.zig");
const geometry = @import("geometry.zig");
const frame_module = @import("frame.zig");
const text_cache = @import("text_cache.zig");
const icon_cache = @import("icon_cache.zig");
const thumbnails_module = @import("thumbnails.zig");

const Layout = layout_module.Layout;
const Rect = layout_module.Rect;
const Vec2 = layout_module.Vec2;
const Palette = theme_module.Palette;
const Rgba = theme_module.Rgba;
const Icon = theme_module.Icon;
const Frame = frame_module.Frame;

pub const maximum_title_length = 92;

const TitleCache = struct {
    source: [text_cache.maximum_text_length]u8 = undefined,
    source_length: usize = 0,
    available_width: f32 = -1,
    size: u8 = 0,
    density_key: u32 = 0,
    result: [text_cache.maximum_text_length]u8 = undefined,
    result_length: usize = 0,
};

pub fn Renderer(comptime backend: type) type {
    return struct {
        const Self = @This();
        const TextCache = text_cache.TextCache(backend);
        const IconCache = icon_cache.IconCache(backend);
        const Thumbnails = thumbnails_module.Thumbnails(backend);

        pub const Report = struct {
            /// Thumbnail range that was drawn; the application requests the
            /// renders that are missing from it.
            visible_thumbnails: layout_module.VisibleThumbnails = .{ .first = 0, .end = 0 },
            missing_thumbnails: bool = false,
        };

        /// Geometry of the finished strokes of one page, reused across
        /// frames until the strokes, the page rectangle, or the theme change.
        const StrokeGeometry = struct {
            mesh: geometry.Mesh = .{},
            document_identity: u64 = 0,
            page_index: usize = 0,
            revision: u64 = 0,
            dark_mode: bool = false,
            page_rect: Rect = Rect.empty,
            valid: bool = false,
            rebuild_count: usize = 0,

            fn matches(self: StrokeGeometry, frame: Frame, page_rect: Rect) bool {
                return self.valid and self.document_identity == frame.document_identity and
                    self.page_index == frame.page_index and
                    self.revision == frame.strokes_revision and
                    self.dark_mode == frame.dark_mode and
                    std.meta.eql(self.page_rect, page_rect);
            }
        };

        allocator: std.mem.Allocator,
        text_cache: TextCache = .{},
        icon_cache: IconCache = .{},
        thumbnails: Thumbnails,
        strokes: StrokeGeometry = .{},
        /// Geometry rebuilt every frame: the stroke being drawn and the
        /// swatches of the annotation margin.
        scratch: geometry.Mesh = .{},
        window_points: std.ArrayList(Vec2) = .empty,
        title_cache: TitleCache = .{},
        density: f32 = 1,
        palette: Palette = Palette.forMode(true),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .thumbnails = Thumbnails.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.text_cache.deinit();
            self.icon_cache.deinit();
            self.thumbnails.deinit();
            self.strokes.mesh.deinit(self.allocator);
            self.scratch.deinit(self.allocator);
            self.window_points.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn draw(
            self: *Self,
            context: backend.Context,
            frame: Frame,
            layout: Layout,
            page_texture: ?backend.Texture,
        ) Report {
            self.density = frame.density;
            self.palette = Palette.forMode(frame.dark_mode);
            var report = Report{};

            self.drawHeader(context, frame, layout);
            self.drawPage(context, frame, layout, page_texture);
            if (frame.navigation_visible and frame.document_open) {
                report = self.drawRail(context, frame, layout);
            }
            if (layout.panel) |panel| self.drawPanel(context, frame, panel);
            return report;
        }

        fn drawHeader(self: *Self, context: backend.Context, frame: Frame, layout: Layout) void {
            const palette = self.palette;
            const width = layout.window.width;
            context.fillRect(
                .{ .x = 0, .y = 0, .w = width, .h = layout_module.header_height },
                palette.header,
            );
            context.fillRect(
                .{ .x = 0, .y = layout_module.header_height - 1, .w = width, .h = 1 },
                palette.border,
            );
            self.drawText(
                context,
                layout_module.wordmark_x,
                layout_module.wordmark_y,
                "BOOK READ",
                15,
                true,
                palette.header_text,
            );

            const hover = frame.hover;
            const toolbar = layout.toolbar;
            if (frame.document_open) {
                self.drawButton(
                    context,
                    toolbar.pages,
                    .pages,
                    frame.navigation_visible,
                    hover.isToolbar(.pages),
                );
            } else {
                self.drawIcon(
                    context,
                    .pages,
                    toolbar.pages.centerX(),
                    toolbar.pages.centerY(),
                    palette.muted,
                );
            }

            if (hover.isToolbar(.open)) context.fillRect(toolbar.open, palette.hover);
            self.drawIcon(
                context,
                .open,
                toolbar.open.x + 18,
                toolbar.open.centerY(),
                palette.header_text,
            );
            const title = self.truncatedTitle(
                context,
                if (frame.document_open) frame.title else "Open PDF",
                toolbar.open.w - 42,
                15,
            );
            self.drawText(
                context,
                toolbar.open.x + 36,
                toolbar.open.centerY() - 10,
                title,
                15,
                false,
                palette.header_text,
            );

            self.drawButton(
                context,
                toolbar.previous,
                .previous,
                false,
                hover.isToolbar(.previous),
            );
            self.drawButton(context, toolbar.next, .next, false, hover.isToolbar(.next));
            var page_label: [48]u8 = undefined;
            const page_text = std.fmt.bufPrint(&page_label, "{d} / {d}", .{
                if (frame.document_open) frame.page_index + 1 else 0,
                frame.page_count,
            }) catch "";
            self.drawCenteredText(context, toolbar.page_label, page_text, 15, palette.header_text);

            self.drawButton(
                context,
                toolbar.bookmark,
                .bookmark,
                frame.bookmarked,
                hover.isToolbar(.bookmark),
            );
            self.drawButton(context, toolbar.jump, .jump, false, hover.isToolbar(.jump));
            self.drawButton(
                context,
                toolbar.theme,
                .theme,
                frame.dark_mode,
                hover.isToolbar(.theme),
            );
            self.drawButton(context, toolbar.zoom_out, .minus, false, hover.isToolbar(.zoom_out));
            self.drawButton(context, toolbar.zoom_in, .plus, false, hover.isToolbar(.zoom_in));
            if (hover.isToolbar(.zoom_reset)) context.fillRect(toolbar.zoom_reset, palette.hover);
            var zoom_label: [16]u8 = undefined;
            const zoom_text = std.fmt.bufPrint(&zoom_label, "{d}%", .{frame.zoom_percent}) catch "";
            self.drawCenteredText(context, toolbar.zoom_reset, zoom_text, 14, palette.header_text);
            self.drawButton(
                context,
                toolbar.annotations,
                .pen,
                frame.annotationsEnabled(),
                hover.isToolbar(.annotations),
            );
        }

        fn drawPage(
            self: *Self,
            context: backend.Context,
            frame: Frame,
            layout: Layout,
            page_texture: ?backend.Texture,
        ) void {
            const page_rect = frame.page_rect orelse return self.drawEmptyState(context, layout);
            if (page_texture) |texture| {
                context.drawTexture(texture, page_rect, theme_module.white);
            } else {
                // The rasterization is still on its way; paper keeps the
                // layout stable and the strokes readable meanwhile.
                context.fillRect(page_rect, self.palette.paper);
                context.strokeRect(page_rect, self.palette.border);
            }

            self.drawFinishedStrokes(context, frame, page_rect);
            if (frame.active_stroke.len > 0) {
                self.scratch.clear();
                self.appendStroke(
                    &self.scratch,
                    page_rect,
                    frame.active_stroke,
                    theme_module.inkColor(frame.color, frame.dark_mode),
                    theme_module.penWidth(frame.pen_size),
                ) catch return;
                self.drawMesh(context, self.scratch);
            }
        }

        fn drawFinishedStrokes(
            self: *Self,
            context: backend.Context,
            frame: Frame,
            page_rect: Rect,
        ) void {
            const cache = &self.strokes;
            if (!cache.matches(frame, page_rect)) {
                cache.valid = false;
                cache.mesh.clear();
                for (frame.strokes) |stroke| {
                    self.appendStroke(
                        &cache.mesh,
                        page_rect,
                        stroke.points,
                        theme_module.inkColor(stroke.color, frame.dark_mode),
                        theme_module.penWidth(stroke.pen_size),
                    ) catch return;
                }
                cache.document_identity = frame.document_identity;
                cache.page_index = frame.page_index;
                cache.revision = frame.strokes_revision;
                cache.dark_mode = frame.dark_mode;
                cache.page_rect = page_rect;
                cache.valid = true;
                cache.rebuild_count += 1;
            }
            self.drawMesh(context, cache.mesh);
        }

        fn drawEmptyState(self: *Self, context: backend.Context, layout: Layout) void {
            const message = "OPEN A PDF TO START";
            const entry = self.text_cache.get(context, message, 14, true, self.density) orelse {
                return;
            };
            context.drawTexture(entry.texture.?, .{
                .x = layout.content.x + (layout.content.w - entry.width) / 2,
                .y = layout.window.height / 2,
                .w = entry.width,
                .h = entry.height,
            }, self.palette.muted);
        }

        /// Converts normalized page points to window points and appends the
        /// stroke geometry to `mesh`.
        fn appendStroke(
            self: *Self,
            mesh: *geometry.Mesh,
            page_rect: Rect,
            points: []const annotations.Point,
            color: Rgba,
            width: f32,
        ) error{OutOfMemory}!void {
            if (points.len == 0) return;
            self.window_points.clearRetainingCapacity();
            try self.window_points.ensureTotalCapacity(self.allocator, points.len);
            for (points) |point| {
                self.window_points.appendAssumeCapacity(.{
                    .x = page_rect.x + point.x * page_rect.w,
                    .y = page_rect.y + point.y * page_rect.h,
                });
            }
            try geometry.appendStroke(mesh, self.allocator, self.window_points.items, width, color);
        }

        fn drawMesh(self: *Self, context: backend.Context, mesh: geometry.Mesh) void {
            _ = self;
            if (mesh.isEmpty()) return;
            context.drawTriangles(mesh.vertices.items, mesh.colors.items, mesh.indices.items);
        }

        fn drawRail(self: *Self, context: backend.Context, frame: Frame, layout: Layout) Report {
            const palette = self.palette;
            const navigation_width = layout.navigation_width;
            const height = layout.window.height;
            context.fillRect(.{
                .x = 0,
                .y = layout_module.header_height,
                .w = navigation_width,
                .h = height - layout_module.header_height,
            }, palette.panel);
            context.fillRect(.{
                .x = navigation_width - 1,
                .y = layout_module.header_height,
                .w = 1,
                .h = height - layout_module.header_height,
            }, palette.border);
            self.drawIcon(context, .pages, 25, layout_module.header_height + 24, palette.muted);
            self.drawText(
                context,
                44,
                layout_module.header_height + 14,
                "PAGES",
                13,
                true,
                palette.muted,
            );

            context.setClip(.{
                .x = 0,
                .y = layout_module.thumbnail_list_top,
                .w = navigation_width - 1,
                .h = height - layout_module.thumbnail_list_top,
            });
            const visible = layout.visibleThumbnails(frame.thumbnail_scroll, frame.page_count);
            var report = Report{ .visible_thumbnails = visible };
            var index = visible.first;
            while (index < visible.end) : (index += 1) {
                const slot = layout.thumbnailSlot(index, frame.thumbnail_scroll);
                if (frame.hover.isThumbnail(index)) context.fillRect(slot, palette.hover);

                const lookup = self.thumbnails.get(index);
                if (lookup.missing) report.missing_thumbnails = true;
                const bounds = layout.thumbnailImageBounds(slot);
                var destination = bounds;
                if (lookup.texture) |texture| {
                    const texture_width: f32 = @floatFromInt(@max(texture.width, 1));
                    const texture_height: f32 = @floatFromInt(@max(texture.height, 1));
                    const fit = @min(bounds.w / texture_width, bounds.h / texture_height);
                    destination.w = texture_width * fit;
                    destination.h = texture_height * fit;
                    destination.x = (navigation_width - destination.w) / 2;
                    context.drawTexture(texture, destination, theme_module.white);
                } else {
                    context.fillRect(destination, palette.surface);
                }

                const selected = index == frame.page_index;
                context.strokeRect(destination, if (selected) palette.accent else palette.border);
                if (selected) context.strokeRect(destination.inset(-2), palette.accent);

                var label_buffer: [24]u8 = undefined;
                const label = std.fmt.bufPrint(&label_buffer, "{d}", .{index + 1}) catch "";
                const density = self.density;
                const entry = self.text_cache.get(context, label, 13, selected, density) orelse {
                    continue;
                };
                context.drawTexture(entry.texture.?, .{
                    .x = (navigation_width - entry.width) / 2,
                    .y = slot.y + layout_module.thumbnail_label_offset,
                    .w = entry.width,
                    .h = entry.height,
                }, if (selected) palette.accent else palette.muted);
            }
            context.setClip(null);

            const maximum_scroll = layout.thumbnailMaxScroll(frame.page_count);
            if (maximum_scroll > 0) {
                const track_top = layout_module.thumbnail_list_top;
                const track_height = height - track_top - 8;
                const viewport_height = layout.thumbnailViewportHeight();
                const content_height = @as(f32, @floatFromInt(frame.page_count)) *
                    layout_module.thumbnail_slot_height;
                const thumb_height = std.math.clamp(
                    track_height * viewport_height / content_height,
                    32,
                    track_height,
                );
                const thumb_y = track_top + (track_height - thumb_height) *
                    frame.thumbnail_scroll / maximum_scroll;
                context.fillRect(
                    .{ .x = navigation_width - 4, .y = thumb_y, .w = 2, .h = thumb_height },
                    palette.muted,
                );
            }
            return report;
        }

        fn drawPanel(
            self: *Self,
            context: backend.Context,
            frame: Frame,
            panel: layout_module.Panel,
        ) void {
            const palette = self.palette;
            const hover = frame.hover;
            context.fillRect(panel.bounds, palette.panel);
            context.fillRect(.{
                .x = panel.bounds.x,
                .y = panel.bounds.y,
                .w = 1,
                .h = panel.bounds.h,
            }, palette.border);

            self.drawText(
                context,
                panel.content_left,
                panel.title_y + 12,
                "ANNOTATION MARGIN",
                13,
                true,
                palette.text,
            );
            if (hover.isPanel(.close)) context.fillRect(panel.close, palette.hover);
            self.drawIcon(
                context,
                .close,
                panel.close.centerX(),
                panel.close.centerY(),
                palette.text,
            );

            self.drawPanelTab(context, .{
                .rect = panel.pen,
                .icon = .pen,
                .label = "Pen",
                .selected = frame.tool == .pen,
                .hovered = hover.isPanel(.pen),
                .icon_shift_x = 15,
                .text_shift_x = 25,
                .content_shift_y = -8,
            });
            self.drawPanelTab(context, .{
                .rect = panel.eraser,
                .icon = .eraser,
                .label = "Eraser",
                .selected = frame.tool == .eraser,
                .hovered = hover.isPanel(.eraser),
                .icon_shift_x = -10,
                .text_shift_x = -5,
                .content_shift_y = -8,
            });
            context.fillRect(.{
                .x = panel.pen.x,
                .y = panel.pen.bottom() - 1,
                .w = panel.pen.w + panel.eraser.w + layout_module.panel_tab_gap,
                .h = 1,
            }, palette.border);

            const label_x = panel.content_left;
            self.drawText(context, label_x, panel.ink_label_y, "Ink", 14, true, palette.muted);
            self.scratch.clear();
            for (panel.colors, annotations.Color.swatches) |rect, color| {
                self.appendSwatch(
                    .{ .x = rect.centerX(), .y = rect.centerY() },
                    theme_module.inkColor(color, frame.dark_mode),
                    frame.color == color,
                    hover.isColor(color),
                ) catch break;
            }
            self.drawMesh(context, self.scratch);

            self.drawText(context, label_x, panel.width_label_y, "Width", 14, true, palette.muted);
            const preview_widths = [_]f32{ 1, 3, 7 };
            for (panel.sizes, annotations.PenSize.all, preview_widths) |rect, size, line_width| {
                self.drawSizeButton(
                    context,
                    rect,
                    line_width,
                    frame.pen_size == size,
                    hover.isSize(size),
                );
            }

            context.fillRect(.{
                .x = panel.content_left,
                .y = panel.edit_divider_y,
                .w = panel.inner_width,
                .h = 1,
            }, palette.border);
            self.drawActionRow(context, .{
                .rect = panel.undo,
                .icon = .undo,
                .label = "Undo",
                .foreground = palette.text,
                .hovered = hover.isPanel(.undo),
            });
            self.drawActionRow(context, .{
                .rect = panel.clear,
                .icon = .clear,
                .label = "Clear page",
                .foreground = palette.danger,
                .hovered = hover.isPanel(.clear),
            });
            context.fillRect(.{
                .x = panel.content_left,
                .y = panel.completion_divider_y,
                .w = panel.inner_width,
                .h = 1,
            }, palette.border);
            self.drawActionRow(context, .{
                .rect = panel.done,
                .icon = .done,
                .label = "Done",
                .foreground = palette.accent,
                .hovered = hover.isPanel(.done),
            });

            const status_icon: Icon = if (frame.save_status == .failed) .alert else .saved;
            const status_color = switch (frame.save_status) {
                .saved => palette.success,
                .pending => palette.muted,
                .failed => palette.danger,
            };
            const status_center_y = panel.save_status_y + layout_module.panel_status_height / 2;
            self.drawIcon(context, status_icon, panel.bounds.x + 32, status_center_y, status_color);
            self.drawText(
                context,
                panel.bounds.x + 56,
                panel.save_status_y + 1,
                frame.save_status.label(),
                16,
                false,
                if (frame.save_status == .failed) palette.danger else palette.muted,
            );
        }

        fn drawButton(
            self: *Self,
            context: backend.Context,
            rect: Rect,
            icon: Icon,
            selected: bool,
            hovered: bool,
        ) void {
            const palette = self.palette;
            if (hovered) context.fillRect(rect, palette.hover);
            if (selected) {
                context.fillRect(
                    .{ .x = rect.x, .y = rect.y + rect.h - 2, .w = rect.w, .h = 2 },
                    palette.accent,
                );
            }
            self.drawIcon(
                context,
                icon,
                rect.centerX(),
                rect.centerY(),
                if (selected) palette.accent else palette.header_text,
            );
        }

        const Tab = struct {
            rect: Rect,
            icon: Icon,
            label: []const u8,
            selected: bool,
            hovered: bool,
            icon_shift_x: f32,
            text_shift_x: f32,
            content_shift_y: f32,
        };

        fn drawPanelTab(self: *Self, context: backend.Context, tab: Tab) void {
            const palette = self.palette;
            const rect = tab.rect;
            if (tab.hovered) context.fillRect(rect, palette.hover);
            const color = if (tab.selected) palette.accent else palette.text;
            self.drawIcon(
                context,
                tab.icon,
                rect.x + 20 + tab.icon_shift_x,
                rect.centerY() + tab.content_shift_y,
                color,
            );
            self.drawText(
                context,
                rect.x + 40 + tab.text_shift_x,
                rect.centerY() - 11 + tab.content_shift_y,
                tab.label,
                16,
                tab.selected,
                color,
            );
            if (tab.selected) {
                context.fillRect(.{
                    .x = rect.x,
                    .y = rect.y + rect.h - 2,
                    .w = @min(rect.w, 100),
                    .h = 2,
                }, palette.accent);
            }
        }

        const Row = struct {
            rect: Rect,
            icon: Icon,
            label: []const u8,
            foreground: Rgba,
            hovered: bool,
        };

        fn drawActionRow(self: *Self, context: backend.Context, row: Row) void {
            const rect = row.rect;
            if (row.hovered) context.fillRect(rect, self.palette.hover);
            self.drawIcon(context, row.icon, rect.x + 18, rect.centerY(), row.foreground);
            const text_y = rect.centerY() - 11;
            self.drawText(context, rect.x + 40, text_y, row.label, 15, true, row.foreground);
        }

        /// Appends the rings of one swatch to the scratch mesh. All swatches
        /// share a single draw call thanks to per-vertex colors.
        fn appendSwatch(
            self: *Self,
            center: Vec2,
            color: Rgba,
            selected: bool,
            hovered: bool,
        ) error{OutOfMemory}!void {
            const palette = self.palette;
            if (selected) {
                try self.appendRing(center, 22, palette.accent);
                try self.appendRing(center, 19, palette.panel);
                try self.appendRing(center, 17, color);
            } else if (hovered) {
                try self.appendRing(center, 20, palette.text);
                try self.appendRing(center, 18, palette.panel);
                try self.appendRing(center, 17, color);
            } else {
                try self.appendRing(center, 19, color);
            }
        }

        fn appendRing(self: *Self, center: Vec2, radius: f32, color: Rgba) error{OutOfMemory}!void {
            try geometry.appendCircle(
                &self.scratch,
                self.allocator,
                center,
                radius,
                color,
                geometry.circle_segments,
            );
        }

        fn drawSizeButton(
            self: *Self,
            context: backend.Context,
            rect: Rect,
            line_width: f32,
            selected: bool,
            hovered: bool,
        ) void {
            const palette = self.palette;
            context.fillRect(rect, if (hovered) palette.hover else palette.surface);
            context.strokeRect(rect, if (selected) palette.accent else palette.border);
            context.fillRect(.{
                .x = rect.x + 14,
                .y = rect.centerY() - line_width / 2,
                .w = rect.w - 28,
                .h = line_width,
            }, palette.text);
        }

        fn drawIcon(
            self: *Self,
            context: backend.Context,
            icon: Icon,
            center_x: f32,
            center_y: f32,
            color: Rgba,
        ) void {
            const texture = self.icon_cache.get(context, icon, color, self.density) orelse return;
            context.drawTexture(texture, .{
                .x = center_x - theme_module.icon_size / 2,
                .y = center_y - theme_module.icon_size / 2,
                .w = theme_module.icon_size,
                .h = theme_module.icon_size,
            }, theme_module.white);
        }

        fn drawText(
            self: *Self,
            context: backend.Context,
            x: f32,
            y: f32,
            text: []const u8,
            size: u8,
            strong: bool,
            color: Rgba,
        ) void {
            if (text.len == 0) return;
            const entry = self.text_cache.get(context, text, size, strong, self.density) orelse {
                return;
            };
            context.drawTexture(
                entry.texture.?,
                .{ .x = x, .y = y, .w = entry.width, .h = entry.height },
                color,
            );
        }

        fn drawCenteredText(
            self: *Self,
            context: backend.Context,
            rect: Rect,
            text: []const u8,
            size: u8,
            color: Rgba,
        ) void {
            if (text.len == 0) return;
            const entry = self.text_cache.get(context, text, size, true, self.density) orelse {
                return;
            };
            context.drawTexture(entry.texture.?, .{
                .x = rect.x + (rect.w - entry.width) / 2,
                .y = rect.centerY() - 10,
                .w = entry.width,
                .h = entry.height,
            }, color);
        }

        /// Shortens a title to the available width using real text metrics
        /// and codepoint boundaries, so multibyte names are never split. The
        /// result is cached until the title or the width changes.
        fn truncatedTitle(
            self: *Self,
            context: backend.Context,
            title: []const u8,
            available_width: f32,
            size: u8,
        ) []const u8 {
            const source = clipToCodepoints(title, maximum_title_length);
            const cache = &self.title_cache;
            const key = text_cache.densityKey(self.density);
            const same_source = std.mem.eql(u8, cache.source[0..cache.source_length], source);
            if (cache.available_width == available_width and cache.size == size and
                cache.density_key == key and same_source)
            {
                return cache.result[0..cache.result_length];
            }

            var buffer: [text_cache.maximum_text_length + 1]u8 = undefined;
            var length = source.len;
            var result: []const u8 = source;
            if (measureInto(context, &buffer, source, "", size) > available_width) {
                result = "";
                while (length > 0) {
                    length = previousCodepointBoundary(source, length);
                    if (length == 0) break;
                    const width = measureInto(context, &buffer, source[0..length], "...", size);
                    if (width <= available_width) {
                        result = buffer[0 .. length + 3];
                        break;
                    }
                }
            }

            cache.available_width = available_width;
            cache.size = size;
            cache.density_key = key;
            cache.source_length = source.len;
            @memcpy(cache.source[0..source.len], source);
            cache.result_length = result.len;
            @memcpy(cache.result[0..result.len], result);
            return cache.result[0..cache.result_length];
        }

        fn measureInto(
            context: backend.Context,
            buffer: *[text_cache.maximum_text_length + 1]u8,
            prefix: []const u8,
            suffix: []const u8,
            size: u8,
        ) f32 {
            @memcpy(buffer[0..prefix.len], prefix);
            @memcpy(buffer[prefix.len .. prefix.len + suffix.len], suffix);
            buffer[prefix.len + suffix.len] = 0;
            return context.measureText(buffer[0 .. prefix.len + suffix.len :0], size, false);
        }
    };
}

pub fn clipToCodepoints(text: []const u8, maximum: usize) []const u8 {
    if (text.len <= maximum) return text;
    return text[0..previousCodepointBoundary(text, maximum + 1)];
}

/// Largest codepoint boundary strictly before `index`.
pub fn previousCodepointBoundary(text: []const u8, index: usize) usize {
    if (index == 0) return 0;
    var boundary = @min(index, text.len) - 1;
    while (boundary > 0 and (text[boundary] & 0b1100_0000) == 0b1000_0000) boundary -= 1;
    return boundary;
}

const mock = @import("../testing/mock_backend.zig");

const TestRenderer = Renderer(mock.Backend);

fn testFrame(options: struct {
    document_open: bool = true,
    tool: annotations.Tool = .off,
    hover: layout_module.Hover = .none,
    page_rect: ?Rect = null,
    dark_mode: bool = false,
    navigation_visible: bool = true,
    save_status: frame_module.SaveStatus = .saved,
    strokes: []const annotations.Stroke = &.{},
    strokes_revision: u64 = 0,
    active_stroke: []const annotations.Point = &.{},
    page_index: usize = 1,
}) Frame {
    return .{
        .dark_mode = options.dark_mode,
        .document_open = options.document_open,
        .document_identity = 1,
        .page_index = options.page_index,
        .page_count = 8,
        .zoom_percent = 100,
        .bookmarked = true,
        .title = "Research Methods.pdf",
        .navigation_visible = options.navigation_visible,
        .thumbnail_scroll = 0,
        .tool = options.tool,
        .color = .blue,
        .pen_size = .medium,
        .save_status = options.save_status,
        .hover = options.hover,
        .page_rect = options.page_rect,
        .strokes = options.strokes,
        .strokes_revision = options.strokes_revision,
        .active_stroke = options.active_stroke,
    };
}

test "the renderer paints every surface and reports missing thumbnails" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    state.page_count = 8;
    const context = mock.Backend.Context{ .state = &state };
    var document = try mock.Backend.Document.open(context, std.testing.allocator, "book.pdf");
    defer document.deinit();
    var page = try document.render(context, 1, 1.0, false);
    defer page.deinit();
    var queue = mock.Backend.RenderQueue{ .state = &state };
    var notebook = annotations.Notebook.init(std.testing.allocator);
    defer notebook.deinit();
    try notebook.open(8);
    notebook.selectPen();
    _ = try notebook.beginStroke(1, .{ .x = 0.1, .y = 0.1 });
    _ = try notebook.appendPoint(.{ .x = 0.6, .y = 0.4 });
    _ = try notebook.finishStroke();
    _ = try notebook.beginStroke(1, .{ .x = 0.2, .y = 0.7 });

    var renderer = TestRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    const layout = Layout.compute(state.window, .{
        .document_open = true,
        .navigation_visible = true,
        .annotations_enabled = true,
    });
    const page_rect = layout.pageRect(.{ .width = 612, .height = 792 }, 1.0);
    const panel = layout.panel.?;
    const frame = testFrame(.{
        .tool = .pen,
        .page_rect = page_rect,
        .hover = layout.hoverAt(.{
            .x = panel.colors[1].centerX(),
            .y = panel.colors[1].centerY(),
        }, true, 0, 8),
        .strokes = notebook.strokesOn(1),
        .strokes_revision = notebook.revision,
        .active_stroke = notebook.activePoints(),
    });

    try renderer.thumbnails.prepare(&queue, document.identity(), 8, false, 1.0);
    const report = renderer.draw(context, frame, layout, page);
    try std.testing.expect(report.missing_thumbnails);
    try std.testing.expect(report.visible_thumbnails.end > 0);
    try std.testing.expect(state.fill_rect_count > 10);
    try std.testing.expect(state.draw_texture_count > 10);
    // Finished strokes, the active stroke, and all swatches are three batches.
    try std.testing.expectEqual(@as(usize, 3), state.triangle_batch_count);

    renderer.thumbnails.requestVisible(&queue, document, 1, report.visible_thumbnails, false, 1.0);
    while (queue.poll(context, 1)) |result| {
        renderer.thumbnails.complete(result.job.id, result.job.page_index, result.texture);
    }
    const settled = renderer.draw(context, frame, layout, page);
    try std.testing.expect(!settled.missing_thumbnails);
    try std.testing.expect(renderer.thumbnails.liveCount() > 0);
    const creates_before = renderer.text_cache.create_count + renderer.icon_cache.create_count;
    _ = renderer.draw(context, frame, layout, page);
    try std.testing.expectEqual(
        creates_before,
        renderer.text_cache.create_count + renderer.icon_cache.create_count,
    );
}

test "stroke geometry is rebuilt only when the page, its strokes, the theme, or the rect change" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    const context = mock.Backend.Context{ .state = &state };
    var notebook = annotations.Notebook.init(std.testing.allocator);
    defer notebook.deinit();
    try notebook.open(3);
    notebook.selectPen();
    _ = try notebook.beginStroke(1, .{ .x = 0.1, .y = 0.1 });
    _ = try notebook.appendPoint(.{ .x = 0.6, .y = 0.4 });
    _ = try notebook.finishStroke();
    var renderer = TestRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    const layout = Layout.compute(state.window, .{
        .document_open = true,
        .navigation_visible = false,
        .annotations_enabled = false,
    });
    const page_rect = layout.pageRect(.{ .width = 612, .height = 792 }, 1.0);
    var frame = testFrame(.{
        .page_rect = page_rect,
        .strokes = notebook.strokesOn(1),
        .strokes_revision = notebook.revision,
    });

    _ = renderer.draw(context, frame, layout, null);
    _ = renderer.draw(context, frame, layout, null);
    try std.testing.expectEqual(@as(usize, 1), renderer.strokes.rebuild_count);
    try std.testing.expectEqual(@as(usize, 2), state.triangle_batch_count);

    _ = try notebook.beginStroke(1, .{ .x = 0.3, .y = 0.3 });
    _ = try notebook.finishStroke();
    frame.strokes = notebook.strokesOn(1);
    frame.strokes_revision = notebook.revision;
    _ = renderer.draw(context, frame, layout, null);
    try std.testing.expectEqual(@as(usize, 2), renderer.strokes.rebuild_count);

    frame.dark_mode = true;
    _ = renderer.draw(context, frame, layout, null);
    try std.testing.expectEqual(@as(usize, 3), renderer.strokes.rebuild_count);

    frame.page_rect = layout.pageRect(.{ .width = 612, .height = 792 }, 1.5);
    _ = renderer.draw(context, frame, layout, null);
    try std.testing.expectEqual(@as(usize, 4), renderer.strokes.rebuild_count);

    // The same strokes of another document must not be mistaken for cached ones.
    frame.document_identity = 2;
    _ = renderer.draw(context, frame, layout, null);
    try std.testing.expectEqual(@as(usize, 5), renderer.strokes.rebuild_count);
    _ = renderer.draw(context, frame, layout, null);
    try std.testing.expectEqual(@as(usize, 5), renderer.strokes.rebuild_count);
}

test "the renderer handles an empty reader, a placeholder page, and a hidden rail" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    const context = mock.Backend.Context{ .state = &state };
    var renderer = TestRenderer.init(std.testing.allocator);
    defer renderer.deinit();

    const closed = Layout.compute(state.window, .{
        .document_open = false,
        .navigation_visible = false,
        .annotations_enabled = false,
    });
    var closed_frame = testFrame(.{
        .document_open = false,
        .navigation_visible = false,
        .dark_mode = true,
    });
    closed_frame.density = 2.0;
    const report = renderer.draw(context, closed_frame, closed, null);
    try std.testing.expect(!report.missing_thumbnails);
    try std.testing.expectEqual(@as(usize, 0), state.triangle_batch_count);
    try std.testing.expect(state.draw_texture_count > 0);

    const hidden = Layout.compute(state.window, .{
        .document_open = true,
        .navigation_visible = false,
        .annotations_enabled = false,
    });
    const fills_before = state.fill_rect_count;
    _ = renderer.draw(context, testFrame(.{
        .navigation_visible = false,
        .save_status = .failed,
        .page_rect = hidden.pageRect(.{ .width = 612, .height = 792 }, 1.0),
    }), hidden, null);
    // A page without a texture is drawn as paper, not left blank.
    try std.testing.expect(state.fill_rect_count > fills_before);
    try std.testing.expectEqual(@as(usize, 0), state.render_count);
}

test "titles are truncated on codepoint boundaries using measured widths" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    const context = mock.Backend.Context{ .state = &state };
    var renderer = TestRenderer.init(std.testing.allocator);
    defer renderer.deinit();

    const short = renderer.truncatedTitle(context, "book.pdf", 1000, 15);
    try std.testing.expectEqualStrings("book.pdf", short);

    const long = "lectura-" ++ "ñ" ** 36 ++ ".pdf";
    const truncated = renderer.truncatedTitle(context, long, 120, 15);
    try std.testing.expect(truncated.len < long.len);
    try std.testing.expect(std.mem.endsWith(u8, truncated, "..."));
    try std.testing.expect(std.unicode.utf8ValidateSlice(truncated));
    const measures = state.measure_count;
    _ = renderer.truncatedTitle(context, long, 120, 15);
    try std.testing.expectEqual(measures, state.measure_count);

    try std.testing.expectEqualStrings("", renderer.truncatedTitle(context, "abcdef", 1, 15));
    try std.testing.expectEqual(@as(usize, 2), clipToCodepoints("ñññ", 3).len);
    try std.testing.expectEqual(@as(usize, 0), previousCodepointBoundary("ñ", 1));
    try std.testing.expectEqual(@as(usize, 3), previousCodepointBoundary("abcd", 4));
}
