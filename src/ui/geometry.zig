//! Converts strokes and circles into triangle lists so the renderer can draw
//! them with a single geometry call instead of thousands of lines or points.

const std = @import("std");
const Vec2 = @import("layout.zig").Vec2;

pub const Mesh = struct {
    vertices: std.ArrayList(Vec2) = .empty,
    indices: std.ArrayList(c_int) = .empty,

    pub fn deinit(self: *Mesh, allocator: std.mem.Allocator) void {
        self.vertices.deinit(allocator);
        self.indices.deinit(allocator);
    }

    pub fn clear(self: *Mesh) void {
        self.vertices.clearRetainingCapacity();
        self.indices.clearRetainingCapacity();
    }

    pub fn isEmpty(self: Mesh) bool {
        return self.indices.items.len == 0;
    }

    pub fn triangleCount(self: Mesh) usize {
        return self.indices.items.len / 3;
    }
};

pub const circle_segments: u32 = 24;

/// Appends a filled circle as a triangle fan.
pub fn appendCircle(
    mesh: *Mesh,
    allocator: std.mem.Allocator,
    center: Vec2,
    radius: f32,
    segments: u32,
) !void {
    if (radius <= 0 or segments < 3) return;
    const base: c_int = @intCast(mesh.vertices.items.len);
    try mesh.vertices.ensureUnusedCapacity(allocator, segments + 1);
    try mesh.indices.ensureUnusedCapacity(allocator, segments * 3);
    mesh.vertices.appendAssumeCapacity(center);
    var index: u32 = 0;
    while (index < segments) : (index += 1) {
        const angle = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(segments)) *
            std.math.tau;
        mesh.vertices.appendAssumeCapacity(.{
            .x = center.x + @cos(angle) * radius,
            .y = center.y + @sin(angle) * radius,
        });
    }
    index = 0;
    while (index < segments) : (index += 1) {
        const current: c_int = @intCast(index + 1);
        const following: c_int = @intCast((index + 1) % segments + 1);
        mesh.indices.appendAssumeCapacity(base);
        mesh.indices.appendAssumeCapacity(base + current);
        mesh.indices.appendAssumeCapacity(base + following);
    }
}

/// Appends a polyline as a triangle strip with round joins and caps. Joins are
/// only added when the pen is wide enough for a gap to be visible.
pub fn appendStroke(
    mesh: *Mesh,
    allocator: std.mem.Allocator,
    points: []const Vec2,
    width: f32,
) !void {
    if (points.len == 0 or width <= 0) return;
    const radius = width / 2;
    const join_segments: u32 = if (radius >= 1.5) 10 else 0;
    if (points.len == 1) {
        try appendCircle(mesh, allocator, points[0], radius, @max(join_segments, 8));
        return;
    }

    const base: c_int = @intCast(mesh.vertices.items.len);
    try mesh.vertices.ensureUnusedCapacity(allocator, points.len * 2);
    try mesh.indices.ensureUnusedCapacity(allocator, (points.len - 1) * 6);

    var previous_normal = Vec2{ .x = 0, .y = radius };
    for (points, 0..) |point, index| {
        const direction = strokeDirection(points, index);
        const normal = if (direction) |d|
            Vec2{ .x = -d.y * radius, .y = d.x * radius }
        else
            previous_normal;
        previous_normal = normal;
        mesh.vertices.appendAssumeCapacity(.{ .x = point.x + normal.x, .y = point.y + normal.y });
        mesh.vertices.appendAssumeCapacity(.{ .x = point.x - normal.x, .y = point.y - normal.y });
    }
    var index: usize = 0;
    while (index + 1 < points.len) : (index += 1) {
        const left: c_int = base + @as(c_int, @intCast(index * 2));
        mesh.indices.appendAssumeCapacity(left);
        mesh.indices.appendAssumeCapacity(left + 1);
        mesh.indices.appendAssumeCapacity(left + 2);
        mesh.indices.appendAssumeCapacity(left + 1);
        mesh.indices.appendAssumeCapacity(left + 3);
        mesh.indices.appendAssumeCapacity(left + 2);
    }

    if (join_segments > 0) {
        for (points) |point| try appendCircle(mesh, allocator, point, radius, join_segments);
    }
}

/// Unit direction of the stroke at a point, averaging the neighboring
/// segments so the strip bends smoothly. Null when the neighbors coincide.
fn strokeDirection(points: []const Vec2, index: usize) ?Vec2 {
    const before = if (index > 0) points[index - 1] else points[index];
    const after = if (index + 1 < points.len) points[index + 1] else points[index];
    const delta = Vec2{ .x = after.x - before.x, .y = after.y - before.y };
    const length = @sqrt(delta.x * delta.x + delta.y * delta.y);
    if (length < 0.0001) return null;
    return .{ .x = delta.x / length, .y = delta.y / length };
}

test "a circle becomes a fan of the requested segments" {
    var mesh = Mesh{};
    defer mesh.deinit(std.testing.allocator);
    try appendCircle(&mesh, std.testing.allocator, .{ .x = 10, .y = 10 }, 5, 8);
    try std.testing.expectEqual(@as(usize, 9), mesh.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 8), mesh.triangleCount());
    try std.testing.expectApproxEqAbs(@as(f32, 15), mesh.vertices.items[1].x, 0.001);
    for (mesh.indices.items) |index| {
        try std.testing.expect(index >= 0 and index < 9);
    }
    try appendCircle(&mesh, std.testing.allocator, .{ .x = 10, .y = 10 }, 0, 8);
    try std.testing.expectEqual(@as(usize, 9), mesh.vertices.items.len);
}

test "a stroke becomes a strip with two triangles per segment plus joins" {
    var mesh = Mesh{};
    defer mesh.deinit(std.testing.allocator);
    const points = [_]Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 20, .y = 10 },
    };
    try appendStroke(&mesh, std.testing.allocator, &points, 2);
    try std.testing.expectEqual(@as(usize, 6), mesh.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 4), mesh.triangleCount());
    try std.testing.expectApproxEqAbs(@as(f32, 1), mesh.vertices.items[0].y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -1), mesh.vertices.items[1].y, 0.001);

    mesh.clear();
    try std.testing.expect(mesh.isEmpty());
    try appendStroke(&mesh, std.testing.allocator, &points, 8);
    try std.testing.expectEqual(@as(usize, 6 + 3 * 11), mesh.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 4 + 3 * 10), mesh.triangleCount());
    const vertex_count: c_int = @intCast(mesh.vertices.items.len);
    for (mesh.indices.items) |index| {
        try std.testing.expect(index >= 0 and index < vertex_count);
    }
}

test "degenerate strokes still produce drawable geometry" {
    var mesh = Mesh{};
    defer mesh.deinit(std.testing.allocator);
    try appendStroke(&mesh, std.testing.allocator, &.{.{ .x = 3, .y = 4 }}, 4);
    try std.testing.expect(!mesh.isEmpty());

    mesh.clear();
    const stacked = [_]Vec2{ .{ .x = 3, .y = 4 }, .{ .x = 3, .y = 4 } };
    try appendStroke(&mesh, std.testing.allocator, &stacked, 2);
    try std.testing.expectEqual(@as(usize, 4), mesh.vertices.items.len);
    for (mesh.vertices.items) |vertex| {
        try std.testing.expect(std.math.isFinite(vertex.x) and std.math.isFinite(vertex.y));
    }

    mesh.clear();
    try appendStroke(&mesh, std.testing.allocator, &.{}, 2);
    try std.testing.expect(mesh.isEmpty());
}
