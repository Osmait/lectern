//! The production desktop backend: SDL, Poppler, and Cairo through the native
//! bridge plus file storage through `std.Io`.
//!
//! `Application` is instantiated with this file as its backend. Tests use the
//! in-memory backend in `testing/mock_backend.zig` instead.

pub const platform = @import("platform.zig");
pub const storage = @import("storage.zig");
pub const rendering = @import("rendering.zig");
pub const arguments = @import("arguments.zig");
pub const ui = @import("ui.zig");
pub const commands = @import("commands.zig");
pub const application = @import("application.zig");

pub const Context = platform.Context;
pub const Document = platform.Document;
pub const Texture = platform.Texture;
pub const TextImage = platform.TextImage;
pub const RenderQueue = platform.RenderQueue;
pub const Storage = storage.Storage;

pub const Application = application.ApplicationType(@This());
