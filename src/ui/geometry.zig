//! Converts strokes and circles into colored triangle lists so the renderer
//! can draw many shapes with a single geometry call.

const std = @import("std");
const Vec2 = @import("layout.zig").Vec2;
const Rgba = @import("theme.zig").Rgba;

pub const Mesh = struct {
    vertices: std.ArrayList(Vec2) = .empty,
    /// One color per vertex, so shapes of different colors share a batch.
    colors: std.ArrayList(Rgba) = .empty,
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

    fn pushVertex(self: *Mesh, position: Vec2, color: Rgba) void {
        self.vertices.appendAssumeCapacity(position);
        self.colors.appendAssumeCapacity(color);
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
    const base: u32 = @intCast(mesh.vertices.items.len);
    try mesh.reserve(allocator, segments + 1, segments * 3);
    mesh.pushVertex(center, color);
    for (unit) |direction| {
        mesh.pushVertex(.{
            .x = center.x + direction.x * radius,
            .y = center.y + direction.y * radius,
        }, color);
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

    const base: u32 = @intCast(mesh.vertices.items.len);
    try mesh.reserve(allocator, points.len * 2, (points.len - 1) * 6);

    var previous_normal = Vec2{ .x = 0, .y = radius };
    for (points, 0..) |point, index| {
        const direction = strokeDirection(points, index);
        const normal = if (direction) |d|
            Vec2{ .x = -d.y * radius, .y = d.x * radius }
        else
            previous_normal;
        previous_normal = normal;
        mesh.pushVertex(.{ .x = point.x + normal.x, .y = point.y + normal.y }, color);
        mesh.pushVertex(.{ .x = point.x - normal.x, .y = point.y - normal.y }, color);
    }
    var index: u32 = 0;
    while (index + 1 < points.len) : (index += 1) {
        const left = base + index * 2;
        mesh.indices.appendAssumeCapacity(left);
        mesh.indices.appendAssumeCapacity(left + 1);
        mesh.indices.appendAssumeCapacity(left + 2);
        mesh.indices.appendAssumeCapacity(left + 1);
        mesh.indices.appendAssumeCapacity(left + 3);
        mesh.indices.appendAssumeCapacity(left + 2);
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
        try std.testing.expectEqual(test_color, color);
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
