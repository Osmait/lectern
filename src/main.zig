const std = @import("std");
const desktop = @import("desktop.zig");

/// Native resources are created and released here, in reverse order, and the
/// application only borrows them. The render queue stops before the storage
/// and the window go away, and the storage flushes before it closes.
pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    const options = desktop.arguments.parse(arguments) catch |err| {
        std.log.err("usage: book-read [PDF] | book-read --smoke-test PDF", .{});
        return err;
    };

    var context = try desktop.Context.init();
    defer context.deinit();
    var storage = if (options.smoke_test)
        desktop.Storage.openTemporary(init.io, init.gpa, .{
            .tmpdir = init.environ_map.get("TMPDIR"),
        })
    else
        desktop.Storage.open(init.io, init.gpa, .{
            .xdg_state_home = init.environ_map.get("XDG_STATE_HOME"),
            .home = init.environ_map.get("HOME"),
        });
    defer storage.deinit();
    var renders = desktop.RenderQueue.init(init.gpa, init.io);
    defer renders.deinit();

    var application = desktop.Application.init(init.gpa, &context, &storage, &renders);
    defer application.deinit();
    try application.run(options);
}
