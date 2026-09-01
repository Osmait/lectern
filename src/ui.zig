//! Desktop interface layer: geometry, theming, input translation, and drawing.
//!
//! Everything here is plain Zig. Only `renderer.zig` and the caches touch a
//! backend, and they do so through the comptime backend type so tests can run
//! them against an in-memory implementation.

pub const layout = @import("ui/layout.zig");
pub const theme = @import("ui/theme.zig");
pub const input = @import("ui/input.zig");
pub const geometry = @import("ui/geometry.zig");
pub const frame = @import("ui/frame.zig");
pub const text_cache = @import("ui/text_cache.zig");
pub const icon_cache = @import("ui/icon_cache.zig");
pub const thumbnails = @import("ui/thumbnails.zig");
pub const renderer = @import("ui/renderer.zig");

pub const Layout = layout.Layout;
pub const Frame = frame.Frame;
pub const Renderer = renderer.Renderer;

test {
    _ = layout;
    _ = theme;
    _ = input;
    _ = geometry;
    _ = frame;
    _ = text_cache;
    _ = icon_cache;
    _ = thumbnails;
    _ = renderer;
}
