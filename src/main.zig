const std = @import("std");
const desktop = @import("desktop.zig");

/// Native resources are created and released here, in reverse order, and the
/// application only borrows them. The render queue stops before the storage
/// and the window go away, and the storage flushes before it closes. The
/// configuration watcher wakes the window's event loop, so it stops before
/// the window goes away too.
pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    const options = desktop.arguments.parse(arguments) catch |err| {
        std.log.err("usage: lectern [PDF] | lectern --smoke-test PDF", .{});
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
    // A smoke test must look the same on every machine, so it never sees the
    // user's configuration or the desktop palette.
    var config_files = if (options.smoke_test)
        desktop.ConfigFiles.disabled(init.io, init.gpa)
    else
        desktop.ConfigFiles.open(init.io, init.gpa, .{
            .xdg_config_home = init.environ_map.get("XDG_CONFIG_HOME"),
            .xdg_cache_home = init.environ_map.get("XDG_CACHE_HOME"),
            .home = init.environ_map.get("HOME"),
            .wake = desktop.platform.wake,
        });
    defer config_files.deinit();
    var renders = desktop.RenderQueue.init(init.gpa, init.io);
    defer renders.deinit();

    var application = desktop.Application.init(init.gpa, &context, &storage, &renders);
    defer application.deinit();
    if (!options.smoke_test) {
        config_files.watch();
        application.useConfig(&config_files);
    }
    try application.run(options);
}
