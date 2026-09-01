//! Draws a frame through the backend's primitives.
//!
//! The renderer owns every texture cache and scratch buffer. It reads only the
//! `Frame`, the layout, and the annotation strokes it is given, so the same
//! code paints the real window and the in-memory test backend.

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
            pending_thumbnails: bool = false,
        };

        allocator: std.mem.Allocator,
        text_cache: TextCache = .{},
        icon_cache: IconCache = .{},
        thumbnails: Thumbnails,
        mesh: geometry.Mesh = .{},
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
            self.mesh.deinit(self.allocator);
            self.window_points.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn draw(
            self: *Self,
            context: backend.Context,
            frame: Frame,
            layout: Layout,
            page_texture: ?backend.Texture,
            notebook: *const annotations.Notebook,
            document: ?backend.Document,
            density: f32,
        ) Report {
            self.density = density;
            self.palette = Palette.forMode(frame.dark_mode);
            var report = Report{};

            self.drawHeader(context, frame, layout);
            self.drawPage(context, frame, layout, page_texture, notebook);
            if (frame.navigation_visible and frame.document_open) {
                if (document) |open_document| {
                    report.pending_thumbnails =
                        self.drawRail(context, frame, layout, open_document);
                }
            }
            if (layout.panel) |panel| self.drawPanel(context, frame, layout, panel);
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
            self.drawText(context, 28, 20, "BOOK READ", 15, true, palette.header_text);

            const hovered: ?layout_module.ToolbarButton = if (frame.mouse) |mouse|
                layout.toolbarHit(mouse, frame.document_open)
            else
                null;
            const toolbar = layout.toolbar;
            if (frame.document_open) {
                self.drawButton(
                    context,
                    toolbar.pages,
                    .pages,
                    frame.navigation_visible,
                    hovered == .pages,
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

            if (hovered == .open) context.fillRect(toolbar.open, palette.hover);
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

            self.drawButton(context, toolbar.previous, .previous, false, hovered == .previous);
            self.drawButton(context, toolbar.next, .next, false, hovered == .next);
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
                hovered == .bookmark,
            );
            self.drawButton(context, toolbar.jump, .jump, false, hovered == .jump);
            self.drawButton(context, toolbar.theme, .theme, frame.dark_mode, hovered == .theme);
            self.drawButton(context, toolbar.zoom_out, .minus, false, hovered == .zoom_out);
            self.drawButton(context, toolbar.zoom_in, .plus, false, hovered == .zoom_in);
            if (hovered == .zoom_reset) context.fillRect(toolbar.zoom_reset, palette.hover);
            var zoom_label: [16]u8 = undefined;
            const zoom_text = std.fmt.bufPrint(&zoom_label, "{d}%", .{frame.zoom_percent}) catch "";
            self.drawCenteredText(context, toolbar.zoom_reset, zoom_text, 14, palette.header_text);
            self.drawButton(
                context,
                toolbar.annotations,
                .pen,
                frame.annotationsEnabled(),
                hovered == .annotations,
            );
        }

        fn drawPage(
            self: *Self,
            context: backend.Context,
            frame: Frame,
            layout: Layout,
            page_texture: ?backend.Texture,
            notebook: *const annotations.Notebook,
        ) void {
            const page_rect = frame.page_rect orelse return self.drawEmptyState(context, layout);
            const texture = page_texture orelse return self.drawEmptyState(context, layout);
            context.drawTexture(texture, page_rect, theme_module.white);

            for (notebook.strokesOn(frame.page_index)) |stroke| {
                self.drawStroke(
                    context,
                    page_rect,
                    stroke.points,
                    stroke.color.rgba(frame.dark_mode),
                    stroke.pen_size.pixels(),
                );
            }
            if (notebook.hasActiveStroke() and notebook.active_page_index == frame.page_index) {
                self.drawStroke(
                    context,
                    page_rect,
                    notebook.activePoints(),
                    notebook.color.rgba(frame.dark_mode),
                    notebook.pen_size.pixels(),
                );
            }
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

        fn drawStroke(
            self: *Self,
            context: backend.Context,
            page_rect: Rect,
            points: []const annotations.Point,
            color: Rgba,
            width: f32,
        ) void {
            if (points.len == 0) return;
            self.window_points.clearRetainingCapacity();
            self.window_points.ensureTotalCapacity(self.allocator, points.len) catch return;
            for (points) |point| {
                self.window_points.appendAssumeCapacity(.{
                    .x = page_rect.x + point.x * page_rect.w,
                    .y = page_rect.y + point.y * page_rect.h,
                });
            }
            self.mesh.clear();
            geometry.appendStroke(
                &self.mesh,
                self.allocator,
                self.window_points.items,
                width,
            ) catch return;
            self.drawMesh(context, color);
        }

        fn drawMesh(self: *Self, context: backend.Context, color: Rgba) void {
            if (self.mesh.isEmpty()) return;
            context.drawTriangles(self.mesh.vertices.items, self.mesh.indices.items, color);
        }

        fn drawRail(
            self: *Self,
            context: backend.Context,
            frame: Frame,
            layout: Layout,
            document: backend.Document,
        ) bool {
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

            self.thumbnails.beginFrame(
                document,
                frame.page_count,
                frame.dark_mode,
                self.density,
            ) catch return false;
            context.setClip(.{
                .x = 0,
                .y = layout_module.thumbnail_list_top,
                .w = navigation_width - 1,
                .h = height - layout_module.thumbnail_list_top,
            });
            const visible = layout.visibleThumbnails(frame.thumbnail_scroll, frame.page_count);
            const hovered_page: ?usize = if (frame.mouse) |mouse|
                layout.thumbnailAt(mouse, frame.thumbnail_scroll, frame.page_count)
            else
                null;
            var pending = false;
            var index = visible.first;
            while (index < visible.end) : (index += 1) {
                const slot = layout.thumbnailSlot(index, frame.thumbnail_scroll);
                if (hovered_page == index) context.fillRect(slot, palette.hover);

                const lookup = self.thumbnails.get(
                    context,
                    document,
                    index,
                    frame.dark_mode,
                    self.density,
                );
                if (lookup.pending) pending = true;
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
                    .y = slot.y + 136,
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
            return pending;
        }

        fn drawPanel(
            self: *Self,
            context: backend.Context,
            frame: Frame,
            layout: Layout,
            panel: layout_module.Panel,
        ) void {
            const palette = self.palette;
            const hovered: ?layout_module.PanelControl = if (frame.mouse) |mouse|
                layout.panelHit(mouse)
            else
                null;
            context.fillRect(panel.bounds, palette.panel);
            context.fillRect(.{
                .x = panel.bounds.x,
                .y = panel.bounds.y,
                .w = 1,
                .h = panel.bounds.h,
            }, palette.border);

            self.drawText(
                context,
                panel.bounds.x + 24,
                panel.title_y - 3,
                "ANNOTATION MARGIN",
                13,
                true,
                palette.text,
            );
            if (panelHovered(hovered, .close)) context.fillRect(panel.close, palette.hover);
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
                .hovered = panelHovered(hovered, .pen),
                .icon_shift_x = 15,
                .text_shift_x = 25,
                .content_shift_y = -8,
            });
            self.drawPanelTab(context, .{
                .rect = panel.eraser,
                .icon = .eraser,
                .label = "Eraser",
                .selected = frame.tool == .eraser,
                .hovered = panelHovered(hovered, .eraser),
                .icon_shift_x = -10,
                .text_shift_x = -5,
                .content_shift_y = -8,
            });
            context.fillRect(.{
                .x = panel.pen.x,
                .y = panel.pen.y + panel.pen.h - 1,
                .w = panel.pen.w + panel.eraser.w + 8,
                .h = 1,
            }, palette.border);

            const label_x = panel.bounds.x + 24;
            self.drawText(context, label_x, panel.ink_label_y, "Ink", 14, true, palette.muted);
            for (panel.colors, annotations.Color.swatches) |rect, color| {
                const swatch_hovered = if (hovered) |control| switch (control) {
                    .color => |hovered_color| hovered_color == color,
                    else => false,
                } else false;
                self.drawSwatch(
                    context,
                    rect.centerX(),
                    rect.centerY(),
                    color.rgba(frame.dark_mode),
                    frame.color == color,
                    swatch_hovered,
                );
            }

            self.drawText(context, label_x, panel.width_label_y, "Width", 14, true, palette.muted);
            const preview_widths = [_]f32{ 1, 3, 7 };
            for (panel.sizes, annotations.PenSize.all, preview_widths) |rect, size, line_width| {
                const size_hovered = if (hovered) |control| switch (control) {
                    .size => |hovered_size| hovered_size == size,
                    else => false,
                } else false;
                self.drawSizeButton(
                    context,
                    rect,
                    line_width,
                    frame.pen_size == size,
                    size_hovered,
                );
            }

            context.fillRect(.{
                .x = panel.bounds.x + 24,
                .y = panel.edit_divider_y,
                .w = panel.bounds.w - 40,
                .h = 1,
            }, palette.border);
            self.drawActionRow(context, .{
                .rect = panel.undo,
                .icon = .undo,
                .label = "Undo",
                .foreground = palette.text,
                .hovered = panelHovered(hovered, .undo),
            });
            self.drawActionRow(context, .{
                .rect = panel.clear,
                .icon = .clear,
                .label = "Clear page",
                .foreground = palette.danger,
                .hovered = panelHovered(hovered, .clear),
            });
            context.fillRect(.{
                .x = panel.bounds.x + 24,
                .y = panel.completion_divider_y,
                .w = panel.bounds.w - 40,
                .h = 1,
            }, palette.border);
            self.drawActionRow(context, .{
                .rect = panel.done,
                .icon = .done,
                .label = "Done",
                .foreground = palette.accent,
                .hovered = panelHovered(hovered, .done),
            });

            const status_icon: Icon = if (frame.save_status == .failed) .alert else .saved;
            const status_color = switch (frame.save_status) {
                .saved => palette.success,
                .pending => palette.muted,
                .failed => palette.danger,
            };
            self.drawIcon(
                context,
                status_icon,
                panel.bounds.x + 32,
                panel.save_status_y + 5,
                status_color,
            );
            self.drawText(
                context,
                panel.bounds.x + 56,
                panel.save_status_y - 4,
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

        fn drawSwatch(
            self: *Self,
            context: backend.Context,
            center_x: f32,
            center_y: f32,
            color: Rgba,
            selected: bool,
            hovered: bool,
        ) void {
            const palette = self.palette;
            const center = Vec2{ .x = center_x, .y = center_y };
            if (selected) {
                self.drawCircle(context, center, 22, palette.accent);
                self.drawCircle(context, center, 19, palette.panel);
                self.drawCircle(context, center, 17, color);
            } else if (hovered) {
                self.drawCircle(context, center, 20, palette.text);
                self.drawCircle(context, center, 18, palette.panel);
                self.drawCircle(context, center, 17, color);
            } else {
                self.drawCircle(context, center, 19, color);
            }
        }

        fn drawCircle(
            self: *Self,
            context: backend.Context,
            center: Vec2,
            radius: f32,
            color: Rgba,
        ) void {
            self.mesh.clear();
            geometry.appendCircle(
                &self.mesh,
                self.allocator,
                center,
                radius,
                geometry.circle_segments,
            ) catch return;
            self.drawMesh(context, color);
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

fn panelHovered(
    hovered: ?layout_module.PanelControl,
    tag: std.meta.Tag(layout_module.PanelControl),
) bool {
    const control = hovered orelse return false;
    return std.meta.activeTag(control) == tag;
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

fn testFrame(options: struct {
    document_open: bool = true,
    tool: annotations.Tool = .off,
    mouse: ?Vec2 = null,
    page_rect: ?Rect = null,
    dark_mode: bool = false,
    navigation_visible: bool = true,
    save_status: frame_module.SaveStatus = .saved,
}) Frame {
    return .{
        .dark_mode = options.dark_mode,
        .document_open = options.document_open,
        .page_index = 1,
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
        .mouse = options.mouse,
        .page_rect = options.page_rect,
    };
}

test "the renderer paints every surface and reports pending thumbnails" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    state.page_count = 8;
    const context = mock.Backend.Context{ .state = &state };
    var document = try mock.Backend.Document.open(context, std.testing.allocator, "book.pdf");
    defer document.deinit();
    var page = try document.render(context, 1, 1.0, false);
    defer page.deinit();
    var notebook = annotations.Notebook.init(std.testing.allocator);
    defer notebook.deinit();
    try notebook.open(8);
    notebook.selectPen();
    _ = try notebook.beginStroke(1, .{ .x = 0.1, .y = 0.1 });
    _ = try notebook.appendPoint(.{ .x = 0.6, .y = 0.4 });
    _ = try notebook.finishStroke();
    _ = try notebook.beginStroke(1, .{ .x = 0.2, .y = 0.7 });

    var renderer = Renderer(mock.Backend).init(std.testing.allocator);
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
        .mouse = .{ .x = panel.colors[1].centerX(), .y = panel.colors[1].centerY() },
    });

    const report = renderer.draw(context, frame, layout, page, &notebook, document, 1.0);
    try std.testing.expect(report.pending_thumbnails);
    try std.testing.expect(state.fill_rect_count > 10);
    try std.testing.expect(state.draw_texture_count > 10);
    // Two strokes plus swatches: one hovered and one selected with three
    // circles each, and three plain swatches.
    try std.testing.expectEqual(@as(usize, 2 + 3 + 3 + 3), state.triangle_batch_count);

    var frame_index: usize = 0;
    while (frame_index < 8) : (frame_index += 1) {
        _ = renderer.draw(context, frame, layout, page, &notebook, document, 1.0);
    }
    const settled = renderer.draw(context, frame, layout, page, &notebook, document, 1.0);
    try std.testing.expect(!settled.pending_thumbnails);
    const creates_before = renderer.text_cache.create_count + renderer.icon_cache.create_count;
    _ = renderer.draw(context, frame, layout, page, &notebook, document, 1.0);
    try std.testing.expectEqual(
        creates_before,
        renderer.text_cache.create_count + renderer.icon_cache.create_count,
    );
}

test "the renderer handles an empty reader and a hidden rail" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    const context = mock.Backend.Context{ .state = &state };
    var notebook = annotations.Notebook.init(std.testing.allocator);
    defer notebook.deinit();
    var renderer = Renderer(mock.Backend).init(std.testing.allocator);
    defer renderer.deinit();

    const closed = Layout.compute(state.window, .{
        .document_open = false,
        .navigation_visible = false,
        .annotations_enabled = false,
    });
    const report = renderer.draw(
        context,
        testFrame(.{ .document_open = false, .navigation_visible = false, .dark_mode = true }),
        closed,
        null,
        &notebook,
        null,
        2.0,
    );
    try std.testing.expect(!report.pending_thumbnails);
    try std.testing.expectEqual(@as(usize, 0), state.triangle_batch_count);
    try std.testing.expect(state.draw_texture_count > 0);

    var document = try mock.Backend.Document.open(context, std.testing.allocator, "book.pdf");
    defer document.deinit();
    const hidden = Layout.compute(state.window, .{
        .document_open = true,
        .navigation_visible = false,
        .annotations_enabled = false,
    });
    const renders_before = state.render_count;
    _ = renderer.draw(
        context,
        testFrame(.{ .navigation_visible = false, .save_status = .failed }),
        hidden,
        null,
        &notebook,
        document,
        1.0,
    );
    try std.testing.expectEqual(renders_before, state.render_count);
}

test "titles are truncated on codepoint boundaries using measured widths" {
    var state = mock.State.init(std.testing.allocator);
    defer state.deinit();
    const context = mock.Backend.Context{ .state = &state };
    var renderer = Renderer(mock.Backend).init(std.testing.allocator);
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
