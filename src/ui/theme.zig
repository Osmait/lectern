//! Color palettes, ink colors, pen widths, and icon identities.
//!
//! Everything that turns a persisted annotation identity into something
//! visible lives here, so the core never learns what a color looks like.

const std = @import("std");
const annotations = @import("lectern").annotations;

/// Matches the native color record byte for byte, so vertex colors can be
/// handed to the bridge without conversion. The platform adapter checks this.
pub const Rgba = extern struct {
    red: u8,
    green: u8,
    blue: u8,
    alpha: u8,
};

pub const white: Rgba = rgb(255, 255, 255);

pub fn rgb(red: u8, green: u8, blue: u8) Rgba {
    return .{ .red = red, .green = green, .blue = blue, .alpha = 255 };
}

/// A vertex color as the bridge consumes it: four floats in 0..1 with SDL's
/// layout, so a mesh is handed over without any per-frame conversion.
pub const FColor = extern struct {
    red: f32,
    green: f32,
    blue: f32,
    alpha: f32,
};

pub fn toFloat(color: Rgba) FColor {
    return .{
        .red = @as(f32, @floatFromInt(color.red)) / 255.0,
        .green = @as(f32, @floatFromInt(color.green)) / 255.0,
        .blue = @as(f32, @floatFromInt(color.blue)) / 255.0,
        .alpha = @as(f32, @floatFromInt(color.alpha)) / 255.0,
    };
}

/// A color from `0xrrggbb`.
pub fn hex(value: u24) Rgba {
    return rgb(@truncate(value >> 16), @truncate(value >> 8), @truncate(value));
}

/// `a` moved toward `b` by `amount` in 0..1.
pub fn mix(a: Rgba, b: Rgba, amount: f32) Rgba {
    return .{
        .red = mixChannel(a.red, b.red, amount),
        .green = mixChannel(a.green, b.green, amount),
        .blue = mixChannel(a.blue, b.blue, amount),
        .alpha = 255,
    };
}

fn mixChannel(a: u8, b: u8, amount: f32) u8 {
    const from: f32 = @floatFromInt(a);
    const to: f32 = @floatFromInt(b);
    return @intFromFloat(std.math.clamp(@round(from + (to - from) * amount), 0, 255));
}

/// Perceived brightness in 0..1.
pub fn luminance(color: Rgba) f32 {
    const red: f32 = @floatFromInt(color.red);
    const green: f32 = @floatFromInt(color.green);
    const blue: f32 = @floatFromInt(color.blue);
    return (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255.0;
}

/// Parses `#rrggbb` or `#rgb`; the hash is optional.
pub fn parseColor(text: []const u8) ?Rgba {
    const digits = std.mem.trim(u8, text, " \t\"'#");
    if (digits.len == 6) {
        return hex(std.fmt.parseInt(u24, digits, 16) catch return null);
    }
    if (digits.len == 3) {
        const short = std.fmt.parseInt(u12, digits, 16) catch return null;
        const red: u8 = @truncate((short >> 8) & 0xf);
        const green: u8 = @truncate((short >> 4) & 0xf);
        const blue: u8 = @truncate(short & 0xf);
        return rgb(red * 17, green * 17, blue * 17);
    }
    return null;
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
    /// Stands in for a page whose rasterization has not arrived yet.
    paper: Rgba,

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
                .paper = rgb(36, 38, 43),
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
            .paper = white,
        };
    }

    /// The role a configuration key names, so a file can override any of
    /// them one by one.
    pub fn slot(self: *Palette, name: []const u8) ?*Rgba {
        const roles = [_]struct { name: []const u8, color: *Rgba }{
            .{ .name = "background", .color = &self.background },
            .{ .name = "header", .color = &self.header },
            .{ .name = "panel", .color = &self.panel },
            .{ .name = "surface", .color = &self.surface },
            .{ .name = "hover", .color = &self.hover },
            .{ .name = "border", .color = &self.border },
            .{ .name = "header_text", .color = &self.header_text },
            .{ .name = "text", .color = &self.text },
            .{ .name = "muted", .color = &self.muted },
            .{ .name = "accent", .color = &self.accent },
            .{ .name = "danger", .color = &self.danger },
            .{ .name = "success", .color = &self.success },
            .{ .name = "paper", .color = &self.paper },
        };
        for (roles) |role| {
            if (std.mem.eql(u8, role.name, name)) return role.color;
        }
        return null;
    }
};

/// The colors of the annotation inks. Black ink is unreadable on an inverted
/// page, so dark mode renders it with `black_on_dark`; swatches use the same
/// rule.
pub const Inks = struct {
    blue: Rgba = rgb(47, 111, 219),
    red: Rgba = rgb(217, 79, 74),
    black: Rgba = rgb(25, 28, 32),
    yellow: Rgba = rgb(243, 195, 65),
    green: Rgba = rgb(62, 153, 101),
    purple: Rgba = rgb(132, 91, 173),
    black_on_dark: Rgba = rgb(235, 235, 235),

    pub fn color(self: Inks, ink: annotations.Color, dark_mode: bool) Rgba {
        return switch (ink) {
            .blue => self.blue,
            .red => self.red,
            .black => if (dark_mode) self.black_on_dark else self.black,
            .yellow => self.yellow,
            .green => self.green,
            .purple => self.purple,
        };
    }

    pub fn slot(self: *Inks, name: []const u8) ?*Rgba {
        const inks = [_]struct { name: []const u8, color: *Rgba }{
            .{ .name = "blue", .color = &self.blue },
            .{ .name = "red", .color = &self.red },
            .{ .name = "black", .color = &self.black },
            .{ .name = "yellow", .color = &self.yellow },
            .{ .name = "green", .color = &self.green },
            .{ .name = "purple", .color = &self.purple },
            .{ .name = "black_on_dark", .color = &self.black_on_dark },
        };
        for (inks) |ink| {
            if (std.mem.eql(u8, ink.name, name)) return ink.color;
        }
        return null;
    }
};

/// Stroke widths in logical pixels.
pub const Pens = struct {
    thin: f32 = 2.0,
    medium: f32 = 4.0,
    thick: f32 = 8.0,

    pub const minimum_width: f32 = 0.5;
    pub const maximum_width: f32 = 24;

    pub fn width(self: Pens, size: annotations.PenSize) f32 {
        return switch (size) {
            .thin => self.thin,
            .medium => self.medium,
            .thick => self.thick,
        };
    }

    pub fn slot(self: *Pens, name: []const u8) ?*f32 {
        if (std.mem.eql(u8, name, "thin")) return &self.thin;
        if (std.mem.eql(u8, name, "medium")) return &self.medium;
        if (std.mem.eql(u8, name, "thick")) return &self.thick;
        return null;
    }
};

/// A font family name kept inline and zero terminated, so a look is a plain
/// value that can be copied and compared.
pub const Font = struct {
    pub const capacity = 63;

    bytes: [capacity + 1]u8 = std.mem.zeroes([capacity + 1]u8),
    length: u8 = 0,

    /// Null when the name is empty or does not fit.
    pub fn parse(name: []const u8) ?Font {
        if (name.len == 0 or name.len > capacity) return null;
        if (std.mem.indexOfScalar(u8, name, 0) != null) return null;
        var font = Font{ .length = @intCast(name.len) };
        @memcpy(font.bytes[0..name.len], name);
        return font;
    }

    pub fn of(comptime name: []const u8) Font {
        return comptime parse(name) orelse @compileError("font name does not fit");
    }

    pub fn slice(self: *const Font) [:0]const u8 {
        return self.bytes[0..self.length :0];
    }
};

pub const default_font = "Noto Sans";

/// Shape and type of the chrome, apart from its colors.
pub const Style = struct {
    font: Font = Font.of(default_font),
    /// Corner radius of hovers, selections, and buttons; zero is the square
    /// paper look.
    radius: f32 = 0,

    pub const maximum_radius: f32 = 16;
};

/// Everything that decides how the interface looks. The application resolves
/// one from the configuration and hands it to the renderer with every frame.
pub const Look = struct {
    palette: Palette,
    inks: Inks = .{},
    pens: Pens = .{},
    style: Style = .{},

    /// Lectern's own look: the paper desk, light or dark.
    pub fn classic(dark_mode: bool) Look {
        return .{ .palette = Palette.forMode(dark_mode) };
    }
};

/// Ink color of the default look.
pub fn inkColor(color: annotations.Color, dark_mode: bool) Rgba {
    return (Inks{}).color(color, dark_mode);
}

/// Stroke width of the default look, in logical pixels.
pub fn penWidth(size: annotations.PenSize) f32 {
    return (Pens{}).width(size);
}

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
    try std.testing.expectEqual(dark.accent, light.accent);
    try std.testing.expect(dark.background.red < light.background.red);
    try std.testing.expect(dark.paper.red < light.paper.red);
}

test "ink colors and pen widths stay stable" {
    try std.testing.expectEqual(@as(u8, 47), inkColor(.blue, false).red);
    try std.testing.expectEqual(@as(u8, 153), inkColor(.green, true).green);
    try std.testing.expectEqual(@as(u8, 25), inkColor(.black, false).red);
    try std.testing.expectEqual(@as(u8, 235), inkColor(.black, true).red);
    try std.testing.expectEqual(@as(f32, 2), penWidth(.thin));
    try std.testing.expectEqual(@as(f32, 4), penWidth(.medium));
    try std.testing.expectEqual(@as(f32, 8), penWidth(.thick));
}

test "float colors map every channel onto 0..1" {
    const color = toFloat(.{ .red = 255, .green = 0, .blue = 51, .alpha = 128 });
    try std.testing.expectEqual(@as(f32, 1), color.red);
    try std.testing.expectEqual(@as(f32, 0), color.green);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), color.blue, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.502), color.alpha, 0.001);
}

test "rgb builds opaque colors" {
    const color = rgb(1, 2, 3);
    try std.testing.expectEqual(@as(u8, 1), color.red);
    try std.testing.expectEqual(@as(u8, 2), color.green);
    try std.testing.expectEqual(@as(u8, 3), color.blue);
    try std.testing.expectEqual(@as(u8, 255), color.alpha);
    try std.testing.expectEqual(rgb(255, 255, 255), white);
}

test "colors parse from hex notation and mix channel by channel" {
    try std.testing.expectEqual(rgb(0x1a, 0x2b, 0x3c), parseColor("#1a2b3c").?);
    try std.testing.expectEqual(rgb(0xff, 0xaa, 0x00), parseColor(" fa0 ").?);
    try std.testing.expectEqual(rgb(0xff, 0xaa, 0x00), parseColor("\"#FFAA00\"").?);
    try std.testing.expectEqual(@as(?Rgba, null), parseColor("red"));
    try std.testing.expectEqual(@as(?Rgba, null), parseColor("#12345"));
    try std.testing.expectEqual(@as(?Rgba, null), parseColor("#gggggg"));
    try std.testing.expectEqual(rgb(0x20, 0x19, 0x16), hex(0x201916));

    try std.testing.expectEqual(rgb(0, 0, 0), mix(rgb(0, 0, 0), white, 0));
    try std.testing.expectEqual(white, mix(rgb(0, 0, 0), white, 1));
    try std.testing.expectEqual(rgb(128, 128, 128), mix(rgb(0, 0, 0), white, 0.5));
    try std.testing.expect(luminance(white) > 0.99);
    try std.testing.expect(luminance(rgb(0, 0, 0)) < 0.01);
    try std.testing.expect(luminance(rgb(0, 255, 0)) > luminance(rgb(0, 0, 255)));
}

test "palette, ink, and pen slots are found by their configuration names" {
    var look = Look.classic(false);
    look.palette.slot("accent").?.* = rgb(1, 2, 3);
    try std.testing.expectEqual(rgb(1, 2, 3), look.palette.accent);
    try std.testing.expect(look.palette.slot("header_text").? == &look.palette.header_text);
    try std.testing.expectEqual(@as(?*Rgba, null), look.palette.slot("nonsense"));

    look.inks.slot("yellow").?.* = rgb(9, 9, 9);
    try std.testing.expectEqual(rgb(9, 9, 9), look.inks.color(.yellow, true));
    try std.testing.expectEqual(look.inks.black_on_dark, look.inks.color(.black, true));
    try std.testing.expectEqual(look.inks.black, look.inks.color(.black, false));
    try std.testing.expectEqual(@as(?*Rgba, null), look.inks.slot("pink"));

    look.pens.slot("thick").?.* = 12;
    try std.testing.expectEqual(@as(f32, 12), look.pens.width(.thick));
    try std.testing.expectEqual(@as(?*f32, null), look.pens.slot("huge"));
}

test "font names are kept inline and reject what does not fit" {
    const font = Font.of("JetBrainsMono Nerd Font");
    try std.testing.expectEqualStrings("JetBrainsMono Nerd Font", font.slice());
    try std.testing.expectEqual(@as(u8, 0), font.bytes[font.length]);
    try std.testing.expectEqual(@as(?Font, null), Font.parse(""));
    const long: [Font.capacity + 1]u8 = @splat('a');
    try std.testing.expectEqual(@as(?Font, null), Font.parse(&long));
    try std.testing.expect(Font.parse(long[0..Font.capacity]) != null);
    // Equal names are equal values, which is how a changed look is detected.
    try std.testing.expect(std.meta.eql(Font.parse("Noto Sans").?, Font.of(default_font)));
    try std.testing.expect(std.meta.eql(Look.classic(true), Look.classic(true)));
    try std.testing.expect(!std.meta.eql(Look.classic(true), Look.classic(false)));
}
