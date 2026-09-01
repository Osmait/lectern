//! Public root of Book Read's platform-independent core.

pub const Reader = @import("reader.zig").Reader;
pub const baseName = @import("path_helpers.zig").baseName;
pub const annotations = @import("annotations.zig");
pub const progress = @import("progress.zig");
pub const key_value = @import("key_value.zig");
pub const Preferences = @import("preferences.zig").Preferences;

test {
    _ = @import("reader.zig");
    _ = @import("path_helpers.zig");
    _ = @import("annotations.zig");
    _ = @import("progress.zig");
    _ = @import("key_value.zig");
    _ = @import("preferences.zig");
}
