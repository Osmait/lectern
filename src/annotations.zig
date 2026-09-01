//! Platform-independent freehand annotations and their versioned file format.
//!
//! Strokes are stored per page so drawing and erasing only touch the current
//! page. Every stroke keeps a bounding box so eraser hit tests reject most
//! strokes before walking their segments. The notebook counts a revision on
//! every change to finished strokes, so a renderer can cache their geometry
//! and rebuild it only when the revision moves.
//!
//! Colors, pen widths, and labels are interface decisions and live in the
//! interface layer; this module only knows the identities that are persisted.

const std = @import("std");

const file_magic = "BRNOTES\x01";
const maximum_stroke_count = 100_000;
const maximum_point_count = 1_000_000;
const stroke_header_size = 12;
const point_record_size = 8;

pub const Point = extern struct {
    x: f32,
    y: f32,
};

/// Tag values are written to the annotation file. Never renumber or reorder
/// them; append new colors with new explicit values instead.
pub const Color = enum(u8) {
    blue = 0,
    red = 1,
    black = 2,
    yellow = 3,
    green = 4,
    purple = 5,

    /// Swatch order shown in the annotation margin. Black is reachable with
    /// the keyboard cycle only.
    pub const swatches = [_]Color{ .blue, .red, .green, .purple, .yellow };

    pub fn next(self: Color) Color {
        return switch (self) {
            .blue => .red,
            .red => .green,
            .green => .purple,
            .purple => .black,
            .black => .yellow,
            .yellow => .blue,
        };
    }
};

/// Tag values are written to the annotation file. Never renumber them.
pub const PenSize = enum(u8) {
    thin = 0,
    medium = 1,
    thick = 2,

    pub const all = [_]PenSize{ .thin, .medium, .thick };

    pub fn next(self: PenSize) PenSize {
        return switch (self) {
            .thin => .medium,
            .medium => .thick,
            .thick => .thin,
        };
    }
};

pub const Tool = enum {
    off,
    pen,
    eraser,
};

pub const Bounds = struct {
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,

    pub fn ofPoints(points: []const Point) Bounds {
        std.debug.assert(points.len > 0);
        var bounds = Bounds{
            .min_x = points[0].x,
            .min_y = points[0].y,
            .max_x = points[0].x,
            .max_y = points[0].y,
        };
        for (points[1..]) |point| {
            bounds.min_x = @min(bounds.min_x, point.x);
            bounds.min_y = @min(bounds.min_y, point.y);
            bounds.max_x = @max(bounds.max_x, point.x);
            bounds.max_y = @max(bounds.max_y, point.y);
        }
        return bounds;
    }

    pub fn containsWithin(self: Bounds, point: Point, radius: f32) bool {
        return point.x >= self.min_x - radius and point.x <= self.max_x + radius and
            point.y >= self.min_y - radius and point.y <= self.max_y + radius;
    }
};

pub const Stroke = struct {
    color: Color,
    pen_size: PenSize,
    points: []Point,
    bounds: Bounds,
};

/// Errors of the editing operations. They are explicit so callers can switch
/// on them exhaustively.
pub const EditError = error{ InvalidPoint, TooManyPoints, OutOfMemory };
pub const SerializeError = error{ TooManyPoints, TooManyStrokes, InvalidPage, OutOfMemory };
pub const RestoreError = error{
    InvalidMagic,
    TooManyStrokes,
    InvalidColor,
    InvalidPenSize,
    InvalidPointCount,
    TruncatedData,
    TrailingData,
    InvalidPoint,
    OutOfMemory,
};

/// Outcome of a successful restore. Strokes that pointed at pages beyond the
/// open document were skipped, which happens when the PDF was replaced by a
/// shorter revision.
pub const Restored = struct {
    restored: usize = 0,
    skipped: usize = 0,
};

const StrokeList = std.ArrayList(Stroke);

pub const Notebook = struct {
    pub const erase_radius: f32 = 0.025;

    allocator: std.mem.Allocator,
    pages: []StrokeList = &.{},
    active_points: std.ArrayList(Point) = .empty,
    active_page_index: usize = 0,
    tool: Tool = .off,
    color: Color = .blue,
    pen_size: PenSize = .medium,
    /// Moves whenever the finished strokes of any page change. Tool, color,
    /// and size selections do not count because they do not alter what is
    /// already on a page.
    revision: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Notebook {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Notebook) void {
        freePages(self.allocator, self.pages);
        self.active_points.deinit(self.allocator);
        self.* = .{ .allocator = self.allocator };
    }

    /// Prepares empty per-page storage for a document. Tool settings survive
    /// because they belong to the user, not to the document.
    pub fn open(self: *Notebook, page_count: usize) error{OutOfMemory}!void {
        const next_pages = try self.allocator.alloc(StrokeList, page_count);
        for (next_pages) |*page| page.* = .empty;
        self.cancelStroke();
        freePages(self.allocator, self.pages);
        self.pages = next_pages;
        self.touch();
    }

    pub fn close(self: *Notebook) void {
        self.cancelStroke();
        freePages(self.allocator, self.pages);
        self.pages = &.{};
        self.touch();
    }

    pub fn isOpen(self: Notebook) bool {
        return self.pages.len > 0;
    }

    pub fn pageCount(self: Notebook) usize {
        return self.pages.len;
    }

    pub fn strokesOn(self: Notebook, page_index: usize) []const Stroke {
        if (page_index >= self.pages.len) return &.{};
        return self.pages[page_index].items;
    }

    pub fn strokeCount(self: Notebook) usize {
        var total: usize = 0;
        for (self.pages) |page| total += page.items.len;
        return total;
    }

    pub fn selectPen(self: *Notebook) void {
        self.cancelStroke();
        self.tool = if (self.tool == .pen) .off else .pen;
    }

    pub fn selectEraser(self: *Notebook) void {
        self.cancelStroke();
        self.tool = if (self.tool == .eraser) .off else .eraser;
    }

    pub fn disableTool(self: *Notebook) void {
        self.cancelStroke();
        self.tool = .off;
    }

    pub fn cycleColor(self: *Notebook) void {
        self.color = self.color.next();
    }

    pub fn selectColor(self: *Notebook, color: Color) void {
        self.color = color;
    }

    pub fn cyclePenSize(self: *Notebook) void {
        self.pen_size = self.pen_size.next();
    }

    pub fn selectPenSize(self: *Notebook, pen_size: PenSize) void {
        self.pen_size = pen_size;
    }

    pub fn hasActiveStroke(self: Notebook) bool {
        return self.active_points.items.len > 0;
    }

    pub fn activePoints(self: Notebook) []const Point {
        return self.active_points.items;
    }

    pub fn beginStroke(self: *Notebook, page_index: usize, point: Point) EditError!bool {
        if (self.tool != .pen or page_index >= self.pages.len) return false;
        try validatePoint(point);
        self.cancelStroke();
        self.active_page_index = page_index;
        try self.active_points.append(self.allocator, point);
        return true;
    }

    pub fn appendPoint(self: *Notebook, point: Point) EditError!bool {
        if (self.tool != .pen or self.active_points.items.len == 0) return false;
        try validatePoint(point);
        if (self.active_points.items.len >= maximum_point_count) {
            return error.TooManyPoints;
        }

        const previous = self.active_points.items[self.active_points.items.len - 1];
        if (distanceSquared(previous, point) < 0.000001) return false;
        try self.active_points.append(self.allocator, point);
        return true;
    }

    pub fn finishStroke(self: *Notebook) EditError!bool {
        if (self.active_points.items.len == 0) return false;
        if (self.active_page_index >= self.pages.len) {
            self.cancelStroke();
            return false;
        }
        const points = try self.active_points.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(points);
        try self.pages[self.active_page_index].append(self.allocator, .{
            .color = self.color,
            .pen_size = self.pen_size,
            .points = points,
            .bounds = Bounds.ofPoints(points),
        });
        self.touch();
        return true;
    }

    pub fn cancelStroke(self: *Notebook) void {
        self.active_points.clearRetainingCapacity();
    }

    pub fn eraseAt(self: *Notebook, page_index: usize, point: Point) bool {
        validatePoint(point) catch return false;
        if (page_index >= self.pages.len) return false;
        const radius_squared = erase_radius * erase_radius;
        const page = &self.pages[page_index];

        var stroke_index = page.items.len;
        while (stroke_index > 0) {
            stroke_index -= 1;
            const stroke = page.items[stroke_index];
            if (!stroke.bounds.containsWithin(point, erase_radius)) continue;
            if (!strokeContainsPoint(stroke, point, radius_squared)) continue;

            const removed = page.orderedRemove(stroke_index);
            self.allocator.free(removed.points);
            self.touch();
            return true;
        }
        return false;
    }

    pub fn undoPage(self: *Notebook, page_index: usize) bool {
        if (page_index >= self.pages.len) return false;
        const removed = self.pages[page_index].pop() orelse return false;
        self.allocator.free(removed.points);
        self.touch();
        return true;
    }

    pub fn clearPage(self: *Notebook, page_index: usize) bool {
        if (page_index >= self.pages.len) return false;
        const page = &self.pages[page_index];
        if (page.items.len == 0) return false;
        for (page.items) |stroke| self.allocator.free(stroke.points);
        page.clearRetainingCapacity();
        self.touch();
        return true;
    }

    pub fn serialize(self: Notebook, allocator: std.mem.Allocator) SerializeError![]u8 {
        var stroke_total: usize = 0;
        var point_total: usize = 0;
        for (self.pages) |page| {
            stroke_total += page.items.len;
            for (page.items) |stroke| {
                if (stroke.points.len > maximum_point_count) return error.TooManyPoints;
                point_total += stroke.points.len;
            }
        }
        if (stroke_total > maximum_stroke_count) return error.TooManyStrokes;
        if (self.pages.len > std.math.maxInt(u32)) return error.InvalidPage;

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        try output.ensureTotalCapacityPrecise(
            allocator,
            file_magic.len + 4 + stroke_total * stroke_header_size +
                point_total * point_record_size,
        );
        output.appendSliceAssumeCapacity(file_magic);
        appendU32(&output, @intCast(stroke_total));

        for (self.pages, 0..) |page, page_index| {
            for (page.items) |stroke| {
                appendU32(&output, @intCast(page_index));
                output.appendAssumeCapacity(@intFromEnum(stroke.color));
                output.appendAssumeCapacity(@intFromEnum(stroke.pen_size));
                output.appendSliceAssumeCapacity(&.{ 0, 0 });
                appendU32(&output, @intCast(stroke.points.len));
                for (stroke.points) |point| {
                    appendU32(&output, @bitCast(point.x));
                    appendU32(&output, @bitCast(point.y));
                }
            }
        }
        return output.toOwnedSlice(allocator);
    }

    /// Replaces every stroke with the serialized contents. The notebook must
    /// already be open for the same document, because page indices are checked
    /// against the page count. Strokes on pages beyond the document are
    /// skipped and counted, like progress entries for missing pages; every
    /// other defect rejects the file and keeps the current strokes.
    pub fn restore(self: *Notebook, data: []const u8) RestoreError!Restored {
        const next_pages = try self.allocator.alloc(StrokeList, self.pages.len);
        for (next_pages) |*page| page.* = .empty;
        errdefer freePages(self.allocator, next_pages);

        var result = Restored{};
        var cursor = Cursor{ .data = data };
        const magic = try cursor.readBytes(file_magic.len);
        if (!std.mem.eql(u8, magic, file_magic)) return error.InvalidMagic;

        const stroke_count = try cursor.readU32();
        if (stroke_count > maximum_stroke_count) return error.TooManyStrokes;
        var stroke_index: u32 = 0;
        while (stroke_index < stroke_count) : (stroke_index += 1) {
            const page_index = try cursor.readU32();
            const color = std.enums.fromInt(Color, try cursor.readByte()) orelse {
                return error.InvalidColor;
            };
            const pen_size = std.enums.fromInt(PenSize, try cursor.readByte()) orelse {
                return error.InvalidPenSize;
            };
            _ = try cursor.readBytes(2);
            const point_count = try cursor.readU32();
            if (point_count == 0 or point_count > maximum_point_count) {
                return error.InvalidPointCount;
            }
            if (cursor.remaining() / point_record_size < point_count) {
                return error.TruncatedData;
            }
            if (page_index >= next_pages.len) {
                var skipped: u32 = 0;
                while (skipped < point_count) : (skipped += 1) {
                    try validatePoint(try readPoint(&cursor));
                }
                result.skipped += 1;
                continue;
            }

            const points = try self.allocator.alloc(Point, point_count);
            errdefer self.allocator.free(points);
            for (points) |*point| {
                point.* = try readPoint(&cursor);
                try validatePoint(point.*);
            }
            try next_pages[page_index].append(self.allocator, .{
                .color = color,
                .pen_size = pen_size,
                .points = points,
                .bounds = Bounds.ofPoints(points),
            });
            result.restored += 1;
        }
        if (!cursor.finished()) return error.TrailingData;

        self.cancelStroke();
        freePages(self.allocator, self.pages);
        self.pages = next_pages;
        self.touch();
        return result;
    }

    fn touch(self: *Notebook) void {
        self.revision +%= 1;
    }
};

fn freePages(allocator: std.mem.Allocator, pages: []StrokeList) void {
    for (pages) |*page| {
        for (page.items) |stroke| allocator.free(stroke.points);
        page.deinit(allocator);
    }
    allocator.free(pages);
}

const Cursor = struct {
    data: []const u8,
    index: usize = 0,

    fn readByte(self: *Cursor) error{TruncatedData}!u8 {
        const bytes = try self.readBytes(1);
        return bytes[0];
    }

    fn readU32(self: *Cursor) error{TruncatedData}!u32 {
        const bytes = try self.readBytes(4);
        return std.mem.readInt(u32, bytes[0..4], .little);
    }

    fn readBytes(self: *Cursor, byte_count: usize) error{TruncatedData}![]const u8 {
        if (self.remaining() < byte_count) return error.TruncatedData;
        const end_index = self.index + byte_count;
        defer self.index = end_index;
        return self.data[self.index..end_index];
    }

    fn remaining(self: Cursor) usize {
        return self.data.len - self.index;
    }

    fn finished(self: Cursor) bool {
        return self.index == self.data.len;
    }
};

fn readPoint(cursor: *Cursor) error{TruncatedData}!Point {
    return .{
        .x = @bitCast(try cursor.readU32()),
        .y = @bitCast(try cursor.readU32()),
    };
}

fn appendU32(output: *std.ArrayList(u8), value: u32) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    output.appendSliceAssumeCapacity(&bytes);
}

fn validatePoint(point: Point) error{InvalidPoint}!void {
    if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y)) {
        return error.InvalidPoint;
    }
    if (point.x < 0 or point.x > 1 or point.y < 0 or point.y > 1) {
        return error.InvalidPoint;
    }
}

fn strokeContainsPoint(stroke: Stroke, point: Point, radius_squared: f32) bool {
    if (stroke.points.len == 1) {
        return distanceSquared(stroke.points[0], point) <= radius_squared;
    }
    for (stroke.points[1..], 0..) |segment_end, index| {
        const segment_start = stroke.points[index];
        if (distanceSquaredToSegment(point, segment_start, segment_end) <= radius_squared) {
            return true;
        }
    }
    return false;
}

fn distanceSquaredToSegment(point: Point, start: Point, end: Point) f32 {
    const delta_x = end.x - start.x;
    const delta_y = end.y - start.y;
    const length_squared = delta_x * delta_x + delta_y * delta_y;
    if (length_squared == 0) return distanceSquared(point, start);

    const projection = ((point.x - start.x) * delta_x +
        (point.y - start.y) * delta_y) / length_squared;
    const clamped_projection = std.math.clamp(projection, 0, 1);
    const nearest = Point{
        .x = start.x + clamped_projection * delta_x,
        .y = start.y + clamped_projection * delta_y,
    };
    return distanceSquared(point, nearest);
}

fn distanceSquared(left: Point, right: Point) f32 {
    const delta_x = left.x - right.x;
    const delta_y = left.y - right.y;
    return delta_x * delta_x + delta_y * delta_y;
}

test "a pen stroke can be recorded and finalized on its page" {
    var notebook = Notebook.init(std.testing.allocator);
    defer notebook.deinit();
    try notebook.open(3);
    notebook.selectPen();

    try std.testing.expect(try notebook.beginStroke(2, .{ .x = 0.1, .y = 0.2 }));
    try std.testing.expect(notebook.hasActiveStroke());
    try std.testing.expect(try notebook.appendPoint(.{ .x = 0.4, .y = 0.5 }));
    try std.testing.expect(try notebook.finishStroke());
    try std.testing.expect(!notebook.hasActiveStroke());

    try std.testing.expectEqual(@as(usize, 1), notebook.strokeCount());
    try std.testing.expectEqual(@as(usize, 0), notebook.strokesOn(0).len);
    const strokes = notebook.strokesOn(2);
    try std.testing.expectEqual(@as(usize, 1), strokes.len);
    try std.testing.expectEqual(@as(usize, 2), strokes[0].points.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), strokes[0].bounds.min_x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), strokes[0].bounds.max_y, 0.0001);
}

test "the revision moves only when finished strokes change" {
    var notebook = Notebook.init(std.testing.allocator);
    defer notebook.deinit();
    try notebook.open(2);
    const opened = notebook.revision;

    notebook.selectPen();
    notebook.cycleColor();
    notebook.selectPenSize(.thick);
    _ = try notebook.beginStroke(0, .{ .x = 0.1, .y = 0.1 });
    _ = try notebook.appendPoint(.{ .x = 0.2, .y = 0.2 });
    try std.testing.expectEqual(opened, notebook.revision);

    _ = try notebook.finishStroke();
    const finished = notebook.revision;
    try std.testing.expect(finished != opened);
    try std.testing.expect(!notebook.undoPage(1));
    try std.testing.expect(!notebook.eraseAt(0, .{ .x = 0.9, .y = 0.9 }));
    try std.testing.expectEqual(finished, notebook.revision);

    try std.testing.expect(notebook.undoPage(0));
    try std.testing.expect(notebook.revision != finished);
    const undone = notebook.revision;
    _ = try notebook.beginStroke(0, .{ .x = 0.1, .y = 0.1 });
    _ = try notebook.finishStroke();
    try std.testing.expect(notebook.clearPage(0));
    try std.testing.expect(notebook.revision != undone);
}

test "strokes cannot target pages outside the document" {
    var notebook = Notebook.init(std.testing.allocator);
    defer notebook.deinit();
    notebook.selectPen();
    try std.testing.expect(!(try notebook.beginStroke(0, .{ .x = 0.5, .y = 0.5 })));

    try notebook.open(1);
    try std.testing.expect(!(try notebook.beginStroke(1, .{ .x = 0.5, .y = 0.5 })));
    try std.testing.expect(try notebook.beginStroke(0, .{ .x = 0.5, .y = 0.5 }));
    try std.testing.expectEqual(@as(usize, 0), notebook.strokesOn(5).len);
}

test "undo and clear only affect the requested page" {
    var notebook = Notebook.init(std.testing.allocator);
    defer notebook.deinit();
    try notebook.open(2);
    notebook.selectPen();

    for ([_]usize{ 0, 1, 1 }) |page_index| {
        _ = try notebook.beginStroke(page_index, .{ .x = 0.2, .y = 0.2 });
        _ = try notebook.finishStroke();
    }
    try std.testing.expect(notebook.undoPage(1));
    try std.testing.expectEqual(@as(usize, 2), notebook.strokeCount());
    try std.testing.expect(notebook.clearPage(1));
    try std.testing.expect(!notebook.clearPage(1));
    try std.testing.expectEqual(@as(usize, 1), notebook.strokeCount());
    try std.testing.expectEqual(@as(usize, 1), notebook.strokesOn(0).len);
    try std.testing.expect(!notebook.undoPage(7));
}

test "eraser detects a point near a stroke segment and skips other strokes" {
    var notebook = Notebook.init(std.testing.allocator);
    defer notebook.deinit();
    try notebook.open(1);
    notebook.selectPen();
    _ = try notebook.beginStroke(0, .{ .x = 0.1, .y = 0.1 });
    _ = try notebook.appendPoint(.{ .x = 0.9, .y = 0.9 });
    _ = try notebook.finishStroke();
    _ = try notebook.beginStroke(0, .{ .x = 0.1, .y = 0.9 });
    _ = try notebook.appendPoint(.{ .x = 0.2, .y = 0.9 });
    _ = try notebook.finishStroke();

    try std.testing.expect(!notebook.eraseAt(0, .{ .x = 0.9, .y = 0.1 }));
    try std.testing.expect(notebook.eraseAt(0, .{ .x = 0.5, .y = 0.5 }));
    try std.testing.expectEqual(@as(usize, 1), notebook.strokeCount());
    try std.testing.expect(notebook.eraseAt(0, .{ .x = 0.15, .y = 0.91 }));
    try std.testing.expectEqual(@as(usize, 0), notebook.strokeCount());
}

test "serialized annotations round trip without losing style or points" {
    var source = Notebook.init(std.testing.allocator);
    defer source.deinit();
    try source.open(2);
    source.selectPen();
    source.color = .red;
    source.pen_size = .thick;
    _ = try source.beginStroke(1, .{ .x = 0.15, .y = 0.25 });
    _ = try source.appendPoint(.{ .x = 0.75, .y = 0.85 });
    _ = try source.finishStroke();

    const serialized = try source.serialize(std.testing.allocator);
    defer std.testing.allocator.free(serialized);
    try std.testing.expectEqual(
        file_magic.len + 4 + stroke_header_size + 2 * point_record_size,
        serialized.len,
    );

    var restored = Notebook.init(std.testing.allocator);
    defer restored.deinit();
    try restored.open(2);
    const result = try restored.restore(serialized);
    try std.testing.expectEqual(@as(usize, 1), result.restored);
    try std.testing.expectEqual(@as(usize, 0), result.skipped);

    try std.testing.expectEqual(@as(usize, 1), restored.strokeCount());
    const stroke = restored.strokesOn(1)[0];
    try std.testing.expectEqual(Color.red, stroke.color);
    try std.testing.expectEqual(PenSize.thick, stroke.pen_size);
    try std.testing.expectEqual(@as(usize, 2), stroke.points.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), stroke.points[1].x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.85), stroke.bounds.max_y, 0.0001);
}

test "every ink color survives annotation persistence with stable tags" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Color.blue));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(Color.black));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(Color.purple));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(PenSize.thick));

    var source = Notebook.init(std.testing.allocator);
    defer source.deinit();
    try source.open(1);
    source.selectPen();
    const colors = [_]Color{ .blue, .red, .green, .purple, .black, .yellow };
    for (colors, 0..) |color, index| {
        source.selectColor(color);
        const offset: f32 = @floatFromInt(index);
        _ = try source.beginStroke(0, .{
            .x = 0.1 + offset * 0.1,
            .y = 0.2,
        });
        _ = try source.finishStroke();
    }

    const serialized = try source.serialize(std.testing.allocator);
    defer std.testing.allocator.free(serialized);
    var restored = Notebook.init(std.testing.allocator);
    defer restored.deinit();
    try restored.open(1);
    _ = try restored.restore(serialized);

    try std.testing.expectEqual(colors.len, restored.strokeCount());
    for (colors, restored.strokesOn(0)) |expected, stroke| {
        try std.testing.expectEqual(expected, stroke.color);
    }
}

test "strokes on pages beyond a shorter document are skipped, not fatal" {
    var source = Notebook.init(std.testing.allocator);
    defer source.deinit();
    try source.open(3);
    source.selectPen();
    for ([_]usize{ 0, 2, 2 }) |page_index| {
        _ = try source.beginStroke(page_index, .{ .x = 0.3, .y = 0.3 });
        _ = try source.appendPoint(.{ .x = 0.4, .y = 0.4 });
        _ = try source.finishStroke();
    }
    const serialized = try source.serialize(std.testing.allocator);
    defer std.testing.allocator.free(serialized);

    var shorter = Notebook.init(std.testing.allocator);
    defer shorter.deinit();
    try shorter.open(1);
    const result = try shorter.restore(serialized);
    try std.testing.expectEqual(@as(usize, 1), result.restored);
    try std.testing.expectEqual(@as(usize, 2), result.skipped);
    try std.testing.expectEqual(@as(usize, 1), shorter.strokeCount());

    // Points of skipped strokes are still validated so corruption is caught.
    const corrupt = try std.testing.allocator.dupe(u8, serialized);
    defer std.testing.allocator.free(corrupt);
    const second_stroke_first_point = file_magic.len + 4 + stroke_header_size +
        2 * point_record_size + stroke_header_size;
    writeTestU32(corrupt, second_stroke_first_point, @bitCast(@as(f32, -2.0)));
    try std.testing.expectError(error.InvalidPoint, shorter.restore(corrupt));
    try std.testing.expectEqual(@as(usize, 1), shorter.strokeCount());
}

test "invalid annotation data is rejected transactionally" {
    var notebook = Notebook.init(std.testing.allocator);
    defer notebook.deinit();
    try notebook.open(1);
    notebook.selectPen();
    _ = try notebook.beginStroke(0, .{ .x = 0.2, .y = 0.2 });
    _ = try notebook.finishStroke();

    try std.testing.expectError(error.TruncatedData, notebook.restore(file_magic));
    try std.testing.expectEqual(@as(usize, 1), notebook.strokeCount());
}

test "tool, color, and size selections cycle predictably and survive reopening" {
    var notebook = Notebook.init(std.testing.allocator);
    defer notebook.deinit();
    try notebook.open(1);

    notebook.selectPen();
    try std.testing.expectEqual(Tool.pen, notebook.tool);
    _ = try notebook.beginStroke(0, .{ .x = 0.2, .y = 0.2 });
    notebook.selectPen();
    try std.testing.expectEqual(Tool.off, notebook.tool);
    try std.testing.expect(!notebook.hasActiveStroke());

    notebook.selectEraser();
    try std.testing.expectEqual(Tool.eraser, notebook.tool);
    notebook.selectEraser();
    try std.testing.expectEqual(Tool.off, notebook.tool);

    inline for (.{
        Color.red,
        Color.green,
        Color.purple,
        Color.black,
        Color.yellow,
        Color.blue,
    }) |expected| {
        notebook.cycleColor();
        try std.testing.expectEqual(expected, notebook.color);
    }
    inline for (.{ PenSize.thick, PenSize.thin, PenSize.medium }) |expected| {
        notebook.cyclePenSize();
        try std.testing.expectEqual(expected, notebook.pen_size);
    }
    notebook.selectColor(.yellow);
    notebook.selectPenSize(.thin);
    notebook.selectPen();
    try notebook.open(4);
    try std.testing.expectEqual(Color.yellow, notebook.color);
    try std.testing.expectEqual(PenSize.thin, notebook.pen_size);
    try std.testing.expectEqual(Tool.pen, notebook.tool);
    try std.testing.expectEqual(@as(usize, 4), notebook.pageCount());
    try std.testing.expectEqual(@as(usize, 5), Color.swatches.len);
    try std.testing.expectEqual(@as(usize, 3), PenSize.all.len);
}

test "invalid and duplicate points do not corrupt an active stroke" {
    var notebook = Notebook.init(std.testing.allocator);
    defer notebook.deinit();
    try notebook.open(1);
    notebook.selectPen();

    try std.testing.expectError(
        error.InvalidPoint,
        notebook.beginStroke(0, .{ .x = -0.01, .y = 0.5 }),
    );
    try std.testing.expectError(
        error.InvalidPoint,
        notebook.beginStroke(0, .{ .x = std.math.nan(f32), .y = 0.5 }),
    );
    try std.testing.expect(!notebook.hasActiveStroke());

    _ = try notebook.beginStroke(0, .{ .x = 0.5, .y = 0.5 });
    try std.testing.expect(!(try notebook.appendPoint(.{ .x = 0.5, .y = 0.5 })));
    try std.testing.expectError(
        error.InvalidPoint,
        notebook.appendPoint(.{ .x = 0.5, .y = std.math.inf(f32) }),
    );
    try std.testing.expectEqual(@as(usize, 1), notebook.activePoints().len);
}

test "editing operations are safe no-ops when nothing matches" {
    var notebook = Notebook.init(std.testing.allocator);
    defer notebook.deinit();

    try std.testing.expect(!(try notebook.beginStroke(0, .{ .x = 0.5, .y = 0.5 })));
    try std.testing.expect(!(try notebook.appendPoint(.{ .x = 0.5, .y = 0.5 })));
    try std.testing.expect(!(try notebook.finishStroke()));
    try std.testing.expect(!notebook.undoPage(0));
    try std.testing.expect(!notebook.clearPage(0));
    try std.testing.expect(!notebook.eraseAt(0, .{ .x = 0.5, .y = 0.5 }));
    try std.testing.expect(!notebook.isOpen());

    try notebook.open(2);
    notebook.selectPen();
    _ = try notebook.beginStroke(1, .{ .x = 0.1, .y = 0.1 });
    _ = try notebook.appendPoint(.{ .x = 0.2, .y = 0.2 });
    _ = try notebook.finishStroke();
    try std.testing.expect(!notebook.eraseAt(0, .{ .x = 0.15, .y = 0.15 }));
    try std.testing.expect(!notebook.eraseAt(1, .{ .x = 0.9, .y = 0.9 }));
    try std.testing.expect(!notebook.eraseAt(9, .{ .x = 0.15, .y = 0.15 }));
    try std.testing.expectEqual(@as(usize, 1), notebook.strokeCount());
    notebook.close();
    try std.testing.expectEqual(@as(usize, 0), notebook.strokeCount());
}

test "serialized annotations reject corrupt fields and trailing bytes" {
    var source = Notebook.init(std.testing.allocator);
    defer source.deinit();
    try source.open(1);
    source.selectPen();
    _ = try source.beginStroke(0, .{ .x = 0.25, .y = 0.75 });
    _ = try source.finishStroke();
    const valid = try source.serialize(std.testing.allocator);
    defer std.testing.allocator.free(valid);

    var target = Notebook.init(std.testing.allocator);
    defer target.deinit();
    try target.open(1);

    const invalid_magic = try std.testing.allocator.dupe(u8, valid);
    defer std.testing.allocator.free(invalid_magic);
    invalid_magic[0] ^= 0xff;
    try std.testing.expectError(error.InvalidMagic, target.restore(invalid_magic));

    const invalid_color = try std.testing.allocator.dupe(u8, valid);
    defer std.testing.allocator.free(invalid_color);
    invalid_color[16] = 0xff;
    try std.testing.expectError(error.InvalidColor, target.restore(invalid_color));

    const invalid_pen_size = try std.testing.allocator.dupe(u8, valid);
    defer std.testing.allocator.free(invalid_pen_size);
    invalid_pen_size[17] = 0xff;
    try std.testing.expectError(error.InvalidPenSize, target.restore(invalid_pen_size));

    const zero_points = try std.testing.allocator.dupe(u8, valid);
    defer std.testing.allocator.free(zero_points);
    writeTestU32(zero_points, 20, 0);
    try std.testing.expectError(error.InvalidPointCount, target.restore(zero_points));

    const invalid_point = try std.testing.allocator.dupe(u8, valid);
    defer std.testing.allocator.free(invalid_point);
    writeTestU32(invalid_point, 24, @bitCast(@as(f32, 1.5)));
    try std.testing.expectError(error.InvalidPoint, target.restore(invalid_point));

    const trailing = try std.testing.allocator.alloc(u8, valid.len + 1);
    defer std.testing.allocator.free(trailing);
    @memcpy(trailing[0..valid.len], valid);
    trailing[valid.len] = 0;
    try std.testing.expectError(error.TrailingData, target.restore(trailing));

    const too_many_strokes = try std.testing.allocator.dupe(u8, valid);
    defer std.testing.allocator.free(too_many_strokes);
    writeTestU32(too_many_strokes, 8, maximum_stroke_count + 1);
    try std.testing.expectError(error.TooManyStrokes, target.restore(too_many_strokes));

    const too_many_points = try std.testing.allocator.dupe(u8, valid);
    defer std.testing.allocator.free(too_many_points);
    writeTestU32(too_many_points, 20, maximum_point_count + 1);
    try std.testing.expectError(error.InvalidPointCount, target.restore(too_many_points));

    // A header that promises more points than the file holds must fail before
    // any point storage is allocated.
    const short_points = try std.testing.allocator.dupe(u8, valid);
    defer std.testing.allocator.free(short_points);
    writeTestU32(short_points, 20, 1000);
    // Index 0 is the page table of `open` and index 1 is the replacement page
    // table of `restore`; index 2 would be the point storage.
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 2,
    });
    var guarded = Notebook.init(counting.allocator());
    defer guarded.deinit();
    try guarded.open(1);
    try std.testing.expectError(error.TruncatedData, guarded.restore(short_points));
}

test "empty notebooks serialize and restore as valid state" {
    var source = Notebook.init(std.testing.allocator);
    defer source.deinit();
    const serialized = try source.serialize(std.testing.allocator);
    defer std.testing.allocator.free(serialized);

    var restored = Notebook.init(std.testing.allocator);
    defer restored.deinit();
    try restored.open(5);
    const result = try restored.restore(serialized);
    try std.testing.expectEqual(@as(usize, 0), result.restored);
    try std.testing.expectEqual(@as(usize, 0), restored.strokeCount());
}

fn writeTestU32(data: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, data[offset..][0..4], value, .little);
}

fn exerciseAnnotationAllocations(allocator: std.mem.Allocator) !void {
    var source = Notebook.init(allocator);
    defer source.deinit();
    try source.open(2);
    source.selectPen();
    _ = try source.beginStroke(1, .{ .x = 0.1, .y = 0.2 });
    _ = try source.appendPoint(.{ .x = 0.8, .y = 0.9 });
    _ = try source.finishStroke();

    const serialized = try source.serialize(allocator);
    defer allocator.free(serialized);
    var restored = Notebook.init(allocator);
    defer restored.deinit();
    try restored.open(2);
    _ = try restored.restore(serialized);
}

test "allocation failures do not leak partially built annotations" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAnnotationAllocations,
        .{},
    );
}
