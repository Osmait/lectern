//! Vocabulary of asynchronous page rasterization shared by every backend.
//!
//! The application submits jobs to the backend's render queue and collects
//! results later. A job carries the document generation it belongs to, so a
//! result that arrives after the document was replaced is dropped unseen.

const std = @import("std");

pub const Purpose = enum { page, thumbnail };

/// Lower values run first: the page on screen beats visible thumbnails,
/// which beat rendering neighbors ahead of time.
pub const Priority = enum(u8) {
    immediate = 0,
    visible = 1,
    prefetch = 2,
};

pub fn Job(comptime Document: type) type {
    return struct {
        /// Assigned by the queue when the job is submitted.
        id: u64 = 0,
        document: Document,
        generation: u64,
        page_index: usize,
        scale: f32,
        dark_mode: bool,
        purpose: Purpose,
        priority: Priority,
    };
}

pub fn Result(comptime Document: type, comptime Texture: type) type {
    return struct {
        job: Job(Document),
        /// Null when rasterization failed.
        texture: ?Texture,
    };
}

/// Index of the job a worker should run next: the most urgent priority, and
/// among equals the earliest submission.
pub fn nextJobIndex(comptime Document: type, jobs: []const Job(Document)) ?usize {
    var best: ?usize = null;
    for (jobs, 0..) |job, index| {
        const current = best orelse {
            best = index;
            continue;
        };
        const rank = @intFromEnum(job.priority);
        const best_rank = @intFromEnum(jobs[current].priority);
        if (rank < best_rank or (rank == best_rank and job.id < jobs[current].id)) best = index;
    }
    return best;
}

const TestDocument = struct { serial: u32 };
const TestJob = Job(TestDocument);

fn testJob(id: u64, priority: Priority) TestJob {
    return .{
        .id = id,
        .document = .{ .serial = 1 },
        .generation = 1,
        .page_index = 0,
        .scale = 1,
        .dark_mode = false,
        .purpose = .page,
        .priority = priority,
    };
}

test "the next job is the most urgent one, then the oldest" {
    try std.testing.expectEqual(@as(?usize, null), nextJobIndex(TestDocument, &.{}));
    const jobs = [_]TestJob{
        testJob(5, .prefetch),
        testJob(6, .visible),
        testJob(7, .visible),
        testJob(8, .prefetch),
    };
    try std.testing.expectEqual(@as(?usize, 1), nextJobIndex(TestDocument, &jobs));
    const urgent = [_]TestJob{ testJob(9, .prefetch), testJob(10, .immediate) };
    try std.testing.expectEqual(@as(?usize, 1), nextJobIndex(TestDocument, &urgent));
    const same = [_]TestJob{ testJob(12, .prefetch), testJob(11, .prefetch) };
    try std.testing.expectEqual(@as(?usize, 1), nextJobIndex(TestDocument, &same));
}
