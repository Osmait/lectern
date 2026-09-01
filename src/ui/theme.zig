//! Color palettes and icon identities.

const annotations = @import("book_read").annotations;

pub const Rgba = annotations.Rgba;

pub const white: Rgba = rgb(255, 255, 255);

pub fn rgb(red: u8, green: u8, blue: u8) Rgba {
    return .{ .red = red, .green = green, .blue = blue, .alpha = 255 };
}

pub const Palette = struct {
    background: Rgba,
    header: Rgba,
    panel: Rgba,
    surface: Rgba,
    hover: Rgba,
    border: Rgba,
    header_text: Rgba,
    text: Rgba,
    muted: Rgba,
    accent: Rgba,
    danger: Rgba,
    success: Rgba,

    pub fn forMode(dark_mode: bool) Palette {
        if (dark_mode) {
            return .{
                .background = rgb(15, 17, 21),
                .header = rgb(23, 23, 23),
                .panel = rgb(25, 27, 32),
                .surface = rgb(32, 35, 42),
                .hover = rgb(43, 47, 55),
                .border = rgb(58, 63, 73),
                .header_text = rgb(242, 242, 239),
                .text = rgb(236, 236, 232),
                .muted = rgb(166, 168, 174),
                .accent = rgb(35, 99, 216),
                .danger = rgb(213, 82, 76),
                .success = rgb(48, 164, 108),
            };
        }
        return .{
            .background = rgb(231, 229, 224),
            .header = rgb(23, 23, 23),
            .panel = rgb(248, 247, 241),
            .surface = rgb(248, 247, 241),
            .hover = rgb(237, 235, 229),
            .border = rgb(222, 219, 213),
            .header_text = rgb(242, 242, 239),
            .text = rgb(42, 42, 42),
            .muted = rgb(80, 80, 82),
            .accent = rgb(35, 99, 216),
            .danger = rgb(202, 51, 46),
            .success = rgb(41, 155, 99),
        };
    }
};

/// Tag values match the native bridge; the platform adapter verifies them.
pub const Icon = enum(u8) {
    open = 0,
    previous = 1,
    next = 2,
    bookmark = 3,
    jump = 4,
    theme = 5,
    minus = 6,
    plus = 7,
    reset = 8,
    pen = 9,
    eraser = 10,
    undo = 11,
    clear = 12,
    done = 13,
    pages = 14,
    close = 15,
    saved = 16,
    alert = 17,
};

pub const icon_size: f32 = 40;

test "palettes differ only where the theme requires" {
    const dark = Palette.forMode(true);
    const light = Palette.forMode(false);
    try @import("std").testing.expectEqual(dark.accent, light.accent);
    try @import("std").testing.expect(dark.background.red < light.background.red);
}
