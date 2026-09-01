//! Converts strokes and circles into colored triangle lists so the renderer
//! can draw many shapes with a single geometry call.

const std = @import("std");
const Vec2 = @import("layout.zig").Vec2;
const theme = @import("theme.zig");
const Rgba = theme.Rgba;
const FColor = theme.FColor;

pub const Mesh = struct {
    vertices: std.ArrayList(Vec2) = .empty,
    /// One color per vertex, already in the bridge's float layout, so shapes
    /// of different colors share a batch and nothing is converted per frame.
    colors: std.ArrayList(FColor) = .empty,
    indices: std.ArrayList(u32) = .empty,

    pub fn deinit(self: *Mesh, allocator: std.mem.Allocator) void {
        self.vertices.deinit(allocator);
        self.colors.deinit(allocator);
        self.indices.deinit(allocator);
    }

    pub fn clear(self: *Mesh) void {
        self.vertices.clearRetainingCapacity();
        self.colors.clearRetainingCapacity();
        self.indices.clearRetainingCapacity();
    }

    pub fn isEmpty(self: Mesh) bool {
        return self.indices.items.len == 0;
    }

    pub fn triangleCount(self: Mesh) usize {
        return self.indices.items.len / 3;
    }

    fn reserve(
        self: *Mesh,
        allocator: std.mem.Allocator,
        vertex_count: usize,
        index_count: usize,
    ) error{OutOfMemory}!void {
        try self.vertices.ensureUnusedCapacity(allocator, vertex_count);
        try self.colors.ensureUnusedCapacity(allocator, vertex_count);
        try self.indices.ensureUnusedCapacity(allocator, index_count);
    }

    fn pushVertex(self: *Mesh, position: Vec2, color: FColor) void {
        self.vertices.appendAssumeCapacity(position);
        self.colors.appendAssumeCapacity(color);
    }

    /// Drops everything appended after the recorded lengths.
    fn truncate(self: *Mesh, vertex_count: usize, index_count: usize) void {
        self.vertices.shrinkRetainingCapacity(vertex_count);
        self.colors.shrinkRetainingCapacity(vertex_count);
        self.indices.shrinkRetainingCapacity(index_count);
    }
};

/// Segments of the circles drawn as swatches.
pub const circle_segments: u32 = 24;
/// Segments of the caps and joins of a stroke.
pub const join_segments: u32 = 10;
/// A round join is added only where consecutive segments turn more than this
/// angle; the strip itself covers gentler bends without a visible seam.
pub const join_threshold_degrees: f32 = 15;
const join_threshold_cosine: f32 = 0.96592583;
/// Pens thinner than this have no visible caps or joins.
const round_join_minimum_radius: f32 = 1.5;

/// The unit circle is computed at compile time, so runtime circles are only
/// multiplications and additions.
fn unitCircle(comptime segments: u32) [segments]Vec2 {
    var table: [segments]Vec2 = undefined;
    for (&table, 0..) |*point, index| {
        const turn: f32 = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(segments));
        const angle: f32 = turn * std.math.tau;
        point.* = .{ .x = @cos(angle), .y = @sin(angle) };
    }
    return table;
}

/// Appends a filled circle as a triangle fan.
pub fn appendCircle(
    mesh: *Mesh,
    allocator: std.mem.Allocator,
    center: Vec2,
    radius: f32,
    color: Rgba,
    comptime segments: u32,
) error{OutOfMemory}!void {
    comptime std.debug.assert(segments >= 3);
    if (radius <= 0) return;
    const unit = comptime unitCircle(segments);
    const fill = theme.toFloat(color);
    const base: u32 = @intCast(mesh.vertices.items.len);
    try mesh.reserve(allocator, segments + 1, segments * 3);
    mesh.pushVertex(center, fill);
    for (unit) |direction| {
        mesh.pushVertex(.{
            .x = center.x + direction.x * radius,
            .y = center.y + direction.y * radius,
        }, fill);
    }
    var index: u32 = 0;
    while (index < segments) : (index += 1) {
        const current = index + 1;
        const following = (index + 1) % segments + 1;
        mesh.indices.appendAssumeCapacity(base);
        mesh.indices.appendAssumeCapacity(base + current);
        mesh.indices.appendAssumeCapacity(base + following);
    }
}

/// Appends a polyline as a triangle strip. Wide pens get round caps and a
/// round join wherever the line turns sharply enough for the strip to thin.
pub fn appendStroke(
    mesh: *Mesh,
    allocator: std.mem.Allocator,
    points: []const Vec2,
    width: f32,
    color: Rgba,
) error{OutOfMemory}!void {
    if (points.len == 0 or width <= 0) return;
    const radius = width / 2;
    const round = radius >= round_join_minimum_radius;
    if (points.len == 1) {
        try appendCircle(mesh, allocator, points[0], radius, color, join_segments);
        return;
    }

    const fill = theme.toFloat(color);
    const base: u32 = @intCast(mesh.vertices.items.len);
    try mesh.reserve(allocator, points.len * 2, (points.len - 1) * 6);

    var previous_normal = Vec2{ .x = 0, .y = radius };
    for (points, 0..) |point, index| {
        const normal = strokeNormal(points, index, radius) orelse previous_normal;
        previous_normal = normal;
        pushPair(mesh, point, normal, fill);
    }
    var index: u32 = 0;
    while (index + 1 < points.len) : (index += 1) {
        pushSegment(mesh, base + index * 2);
    }

    if (!round) return;
    try appendCircle(mesh, allocator, points[0], radius, color, join_segments);
    try appendCircle(mesh, allocator, points[points.len - 1], radius, color, join_segments);
    var corner: usize = 1;
    while (corner + 1 < points.len) : (corner += 1) {
        if (!turnsSharply(points[corner - 1], points[corner], points[corner + 1])) continue;
        try appendCircle(mesh, allocator, points[corner], radius, color, join_segments);
    }
}

/// The two strip vertices of one point, offset along its normal.
fn pushPair(mesh: *Mesh, point: Vec2, normal: Vec2, fill: FColor) void {
    mesh.pushVertex(.{ .x = point.x + normal.x, .y = point.y + normal.y }, fill);
    mesh.pushVertex(.{ .x = point.x - normal.x, .y = point.y - normal.y }, fill);
}

/// The two triangles between the pair at `left` and the following pair.
fn pushSegment(mesh: *Mesh, left: u32) void {
    mesh.indices.appendAssumeCapacity(left);
    mesh.indices.appendAssumeCapacity(left + 1);
    mesh.indices.appendAssumeCapacity(left + 2);
    mesh.indices.appendAssumeCapacity(left + 1);
    mesh.indices.appendAssumeCapacity(left + 3);
    mesh.indices.appendAssumeCapacity(left + 2);
}

fn strokeNormal(points: []const Vec2, index: usize, radius: f32) ?Vec2 {
    const direction = strokeDirection(points, index) orelse return null;
    return .{ .x = -direction.y * radius, .y = direction.x * radius };
}

/// Builds the mesh of a stroke that is still being drawn, one point at a
/// time. Every point except the last has final geometry once its successor
/// is known, so a frame only appends the points that arrived and rebuilds
/// the tail: the last point's strip vertices, its segment, and the end cap.
/// The strip and the round caps and joins are separate meshes, so strip
/// vertex pairs keep the same positions the one-shot tessellation gives them.
pub const StrokeBuilder = struct {
    strip: Mesh = .{},
    rounds: Mesh = .{},
    points: std.ArrayList(Vec2) = .empty,
    width: f32 = 0,
    fill: FColor = .{ .red = 0, .green = 0, .blue = 0, .alpha = 0 },
    /// Points whose geometry is final, and the mesh sizes that hold it.
    stable_count: usize = 0,
    stable_strip_vertices: usize = 0,
    stable_strip_indices: usize = 0,
    stable_round_vertices: usize = 0,
    stable_round_indices: usize = 0,

    pub fn deinit(self: *StrokeBuilder, allocator: std.mem.Allocator) void {
        self.strip.deinit(allocator);
        self.rounds.deinit(allocator);
        self.points.deinit(allocator);
        self.* = undefined;
    }

    /// Forgets the current stroke and adopts a pen for the next one.
    pub fn reset(self: *StrokeBuilder, width: f32, color: Rgba) void {
        self.strip.clear();
        self.rounds.clear();
        self.points.clearRetainingCapacity();
        self.width = width;
        self.fill = theme.toFloat(color);
        self.stable_count = 0;
        self.stable_strip_vertices = 0;
        self.stable_strip_indices = 0;
        self.stable_round_vertices = 0;
        self.stable_round_indices = 0;
    }

    pub fn pointCount(self: StrokeBuilder) usize {
        return self.points.items.len;
    }

    pub fn isEmpty(self: StrokeBuilder) bool {
        return self.strip.isEmpty() and self.rounds.isEmpty();
    }

    /// Adds the points drawn since the last frame and refreshes the tail.
    pub fn extend(
        self: *StrokeBuilder,
        allocator: std.mem.Allocator,
        new_points: []const Vec2,
    ) error{OutOfMemory}!void {
        try self.points.appendSlice(allocator, new_points);
        const points = self.points.items;
        const radius = self.width / 2;
        const round = radius >= round_join_minimum_radius;
        self.strip.truncate(self.stable_strip_vertices, self.stable_strip_indices);
        self.rounds.truncate(self.stable_round_vertices, self.stable_round_indices);
        if (points.len == 0 or self.width <= 0) return;
        if (points.len == 1) {
            try self.appendCircle(allocator, points[0], radius, join_segments);
            return;
        }

        // Every point before the last one gains final geometry.
        while (self.stable_count + 1 < points.len) : (self.stable_count += 1) {
            const index = self.stable_count;
            try self.strip.reserve(allocator, 2, 6);
            const normal = strokeNormal(points, index, radius) orelse self.previousNormal(radius);
            pushPair(&self.strip, points[index], normal, self.fill);
            if (index >= 1) pushSegment(&self.strip, @intCast((index - 1) * 2));
            if (!round) continue;
            if (index == 0) try self.appendCircle(allocator, points[0], radius, join_segments);
            if (index >= 1 and turnsSharply(points[index - 1], points[index], points[index + 1])) {
                try self.appendCircle(allocator, points[index], radius, join_segments);
            }
        }
        self.stable_strip_vertices = self.strip.vertices.items.len;
        self.stable_strip_indices = self.strip.indices.items.len;
        self.stable_round_vertices = self.rounds.vertices.items.len;
        self.stable_round_indices = self.rounds.indices.items.len;

        // The tail moves with every new point and is rebuilt each time.
        const last = points.len - 1;
        try self.strip.reserve(allocator, 2, 6);
        const normal = strokeNormal(points, last, radius) orelse self.previousNormal(radius);
        pushPair(&self.strip, points[last], normal, self.fill);
        pushSegment(&self.strip, @intCast((last - 1) * 2));
        if (round) try self.appendCircle(allocator, points[last], radius, join_segments);
    }

    /// The normal of the previous pair, for a point that coincides with its
    /// neighbors; the one-shot tessellation falls back the same way.
    fn previousNormal(self: StrokeBuilder, radius: f32) Vec2 {
        const vertices = self.strip.vertices.items;
        if (vertices.len < 2) return .{ .x = 0, .y = radius };
        const upper = vertices[vertices.len - 2];
        const lower = vertices[vertices.len - 1];
        return .{ .x = (upper.x - lower.x) / 2, .y = (upper.y - lower.y) / 2 };
    }

    fn appendCircle(
        self: *StrokeBuilder,
        allocator: std.mem.Allocator,
        center: Vec2,
        radius: f32,
        comptime segments: u32,
    ) error{OutOfMemory}!void {
        comptime std.debug.assert(segments >= 3);
        if (radius <= 0) return;
        const unit = comptime unitCircle(segments);
        const base: u32 = @intCast(self.rounds.vertices.items.len);
        try self.rounds.reserve(allocator, segments + 1, segments * 3);
        self.rounds.pushVertex(center, self.fill);
        for (unit) |direction| {
            self.rounds.pushVertex(.{
                .x = center.x + direction.x * radius,
                .y = center.y + direction.y * radius,
            }, self.fill);
        }
        var index: u32 = 0;
        while (index < segments) : (index += 1) {
            self.rounds.indices.appendAssumeCapacity(base);
            self.rounds.indices.appendAssumeCapacity(base + index + 1);
            self.rounds.indices.appendAssumeCapacity(base + (index + 1) % segments + 1);
        }
    }
};

fn turnsSharply(before: Vec2, corner: Vec2, after: Vec2) bool {
    const incoming = unitVector(.{ .x = corner.x - before.x, .y = corner.y - before.y });
    const outgoing = unitVector(.{ .x = after.x - corner.x, .y = after.y - corner.y });
    const in_direction = incoming orelse return false;
    const out_direction = outgoing orelse return false;
    const cosine = in_direction.x * out_direction.x + in_direction.y * out_direction.y;
    return cosine < join_threshold_cosine;
}

fn unitVector(delta: Vec2) ?Vec2 {
    const length = @sqrt(delta.x * delta.x + delta.y * delta.y);
    if (length < 0.0001) return null;
    return .{ .x = delta.x / length, .y = delta.y / length };
}

/// Unit direction of the stroke at a point, averaging the neighboring
/// segments so the strip bends smoothly. Null when the neighbors coincide.
fn strokeDirection(points: []const Vec2, index: usize) ?Vec2 {
    const before = if (index > 0) points[index - 1] else points[index];
    const after = if (index + 1 < points.len) points[index + 1] else points[index];
    return unitVector(.{ .x = after.x - before.x, .y = after.y - before.y });
}

const test_color = Rgba{ .red = 1, .green = 2, .blue = 3, .alpha = 255 };

test "the join threshold constant matches its documented angle" {
    const radians = join_threshold_degrees * std.math.pi / 180.0;
    try std.testing.expectApproxEqAbs(@cos(radians), join_threshold_cosine, 0.0001);
}

test "a circle becomes a fan of the requested segments" {
    var mesh = Mesh{};
    defer mesh.deinit(std.testing.allocator);
    try appendCircle(&mesh, std.testing.allocator, .{ .x = 10, .y = 10 }, 5, test_color, 8);
    try std.testing.expectEqual(@as(usize, 9), mesh.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 9), mesh.colors.items.len);
    try std.testing.expectEqual(@as(usize, 8), mesh.triangleCount());
    try std.testing.expectApproxEqAbs(@as(f32, 15), mesh.vertices.items[1].x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 10), mesh.vertices.items[3].x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 15), mesh.vertices.items[3].y, 0.001);
    for (mesh.indices.items) |index| {
        try std.testing.expect(index < 9);
    }
    try appendCircle(&mesh, std.testing.allocator, .{ .x = 10, .y = 10 }, 0, test_color, 8);
    try std.testing.expectEqual(@as(usize, 9), mesh.vertices.items.len);
}

test "a stroke becomes a strip with two triangles per segment plus caps and joins" {
    var mesh = Mesh{};
    defer mesh.deinit(std.testing.allocator);
    const points = [_]Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 20, .y = 10 },
    };
    try appendStroke(&mesh, std.testing.allocator, &points, 2, test_color);
    try std.testing.expectEqual(@as(usize, 6), mesh.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 4), mesh.triangleCount());
    try std.testing.expectApproxEqAbs(@as(f32, 1), mesh.vertices.items[0].y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -1), mesh.vertices.items[1].y, 0.001);

    // A wide pen adds two caps and one join at the forty-five degree corner.
    mesh.clear();
    try std.testing.expect(mesh.isEmpty());
    try appendStroke(&mesh, std.testing.allocator, &points, 8, test_color);
    try std.testing.expectEqual(@as(usize, 6 + 3 * 11), mesh.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 4 + 3 * 10), mesh.triangleCount());
    const vertex_count: u32 = @intCast(mesh.vertices.items.len);
    for (mesh.indices.items) |index| {
        try std.testing.expect(index < vertex_count);
    }
    for (mesh.colors.items) |color| {
        try std.testing.expectEqual(theme.toFloat(test_color), color);
    }
}

test "gentle bends get caps only, so long strokes stay cheap" {
    var mesh = Mesh{};
    defer mesh.deinit(std.testing.allocator);
    var points: [50]Vec2 = undefined;
    for (&points, 0..) |*point, index| {
        const x: f32 = @floatFromInt(index * 4);
        point.* = .{ .x = x, .y = @sin(x / 40) * 6 };
    }
    try appendStroke(&mesh, std.testing.allocator, &points, 8, test_color);
    try std.testing.expectEqual(@as(usize, 100 + 2 * 11), mesh.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 49 * 2 + 2 * 10), mesh.triangleCount());
}

test "degenerate strokes still produce drawable geometry" {
    var mesh = Mesh{};
    defer mesh.deinit(std.testing.allocator);
    try appendStroke(&mesh, std.testing.allocator, &.{.{ .x = 3, .y = 4 }}, 4, test_color);
    try std.testing.expect(!mesh.isEmpty());

    mesh.clear();
    const stacked = [_]Vec2{ .{ .x = 3, .y = 4 }, .{ .x = 3, .y = 4 } };
    try appendStroke(&mesh, std.testing.allocator, &stacked, 2, test_color);
    try std.testing.expectEqual(@as(usize, 4), mesh.vertices.items.len);
    for (mesh.vertices.items) |vertex| {
        try std.testing.expect(std.math.isFinite(vertex.x) and std.math.isFinite(vertex.y));
    }

    mesh.clear();
    try appendStroke(&mesh, std.testing.allocator, &.{}, 2, test_color);
    try std.testing.expect(mesh.isEmpty());
}

fn lessThanVec2(_: void, left: Vec2, right: Vec2) bool {
    if (left.x != right.x) return left.x < right.x;
    return left.y < right.y;
}

/// Sorted copy of a mesh's vertices, so meshes built in different orders
/// can be compared.
fn sortedVertices(allocator: std.mem.Allocator, meshes: []const *const Mesh) ![]Vec2 {
    var total: usize = 0;
    for (meshes) |mesh| total += mesh.vertices.items.len;
    const sorted = try allocator.alloc(Vec2, total);
    var offset: usize = 0;
    for (meshes) |mesh| {
        @memcpy(sorted[offset .. offset + mesh.vertices.items.len], mesh.vertices.items);
        offset += mesh.vertices.items.len;
    }
    std.mem.sort(Vec2, sorted, {}, lessThanVec2);
    return sorted;
}

test "the incremental builder matches the one-shot tessellation at every length" {
    var points: [40]Vec2 = undefined;
    for (&points, 0..) |*point, index| {
        const t: f32 = @floatFromInt(index);
        // A path with gentle bends, sharp corners, and one repeated point.
        point.* = .{ .x = t * 5, .y = if (index % 7 == 0) t * 3 else @sin(t / 3) * 8 };
    }
    points[12] = points[11];

    for ([_]f32{ 2, 8 }) |width| {
        var builder = StrokeBuilder{};
        defer builder.deinit(std.testing.allocator);
        builder.reset(width, test_color);
        var length: usize = 1;
        while (length <= points.len) : (length += 1) {
            // Points arrive one or three at a time.
            const step: usize = if (length % 4 == 0) 3 else 1;
            const next_length = @min(length + step - 1, points.len);
            try builder.extend(std.testing.allocator, points[length - 1 .. next_length]);
            length = next_length;

            var reference = Mesh{};
            defer reference.deinit(std.testing.allocator);
            try appendStroke(
                &reference,
                std.testing.allocator,
                points[0..length],
                width,
                test_color,
            );
            try std.testing.expectEqual(
                reference.triangleCount(),
                builder.strip.triangleCount() + builder.rounds.triangleCount(),
            );
            const expected = try sortedVertices(std.testing.allocator, &.{&reference});
            defer std.testing.allocator.free(expected);
            const actual = try sortedVertices(std.testing.allocator, &.{
                &builder.strip,
                &builder.rounds,
            });
            defer std.testing.allocator.free(actual);
            try std.testing.expectEqual(expected.len, actual.len);
            for (expected, actual) |left, right| {
                try std.testing.expectApproxEqAbs(left.x, right.x, 0.001);
                try std.testing.expectApproxEqAbs(left.y, right.y, 0.001);
            }
            try std.testing.expectEqual(length, builder.pointCount());
        }
        // Only the tail was rebuilt: the stable region holds all but one point.
        try std.testing.expectEqual(points.len - 1, builder.stable_count);
    }
}

test "the builder starts over on reset and handles an empty stroke" {
    var builder = StrokeBuilder{};
    defer builder.deinit(std.testing.allocator);
    builder.reset(4, test_color);
    try builder.extend(std.testing.allocator, &.{});
    try std.testing.expect(builder.isEmpty());
    try builder.extend(std.testing.allocator, &.{.{ .x = 1, .y = 1 }});
    try std.testing.expect(!builder.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), builder.strip.triangleCount());
    builder.reset(2, test_color);
    try std.testing.expect(builder.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), builder.pointCount());
    try builder.extend(std.testing.allocator, &.{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 } });
    try std.testing.expectEqual(@as(usize, 2), builder.strip.triangleCount());
    try std.testing.expect(builder.rounds.isEmpty());
}
