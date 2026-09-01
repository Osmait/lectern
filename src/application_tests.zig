//! Root of the application test binary: every module that runs on the
//! in-memory backend. Nothing here links SDL, Poppler, or Cairo, so these
//! tests run on any machine with Zig.

test {
    _ = @import("application.zig");
    _ = @import("arguments.zig");
    _ = @import("commands.zig");
    _ = @import("storage.zig");
    _ = @import("rendering.zig");
    _ = @import("page_cache.zig");
    _ = @import("ui.zig");
    _ = @import("testing/mock_backend.zig");
}
