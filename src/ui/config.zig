//! Turns the configuration file, a theme file, and the desktop palette into
//! the look of the interface.
//!
//! Everything here works on text that somebody else read, so it runs in unit
//! tests without a file system. A look is built in layers, each one only
//! changing what it names:
//!
//!   1. the theme: Lectern's own, the desktop's, a built-in one, or a file
//!   2. the `[style]`, `[colors]`, `[ink]`, and `[pen]` sections of that file
//!   3. the same sections of the configuration file, which always wins
//!
//! Values that cannot be read keep what the layer below gave and are
//! reported as warnings, so a typo never costs more than the line it is on.

const std = @import("std");
const lectern = @import("lectern");
const ini = lectern.ini;
const theme = @import("theme.zig");

const Rgba = theme.Rgba;
const Palette = theme.Palette;
const Look = theme.Look;

const log = std.log.scoped(.config);

/// Follows the desktop palette, and Lectern's own look without one.
pub const auto_theme = "auto";
/// Lectern's own look, the paper desk.
pub const classic_theme = "lectern";

/// The font and corner radius of the desktop's design system, which the
/// desktop theme brings along with its colors.
pub const desktop_font = "JetBrainsMono Nerd Font";
pub const desktop_radius: f32 = 6;

/// A theme name kept inline; long enough for a file name without extension.
pub const ThemeName = struct {
    pub const capacity = 48;

    bytes: [capacity]u8 = std.mem.zeroes([capacity]u8),
    length: u8 = 0,

    /// Null when the name is empty, too long, or could leave the themes
    /// folder when used as a file name.
    pub fn parse(text: []const u8) ?ThemeName {
        if (text.len == 0 or text.len > capacity) return null;
        if (text[0] == '.') return null;
        for (text) |character| {
            if (character == '/' or character == '\\' or character == 0) return null;
        }
        var name = ThemeName{ .length = @intCast(text.len) };
        @memcpy(name.bytes[0..text.len], text);
        return name;
    }

    pub fn of(comptime text: []const u8) ThemeName {
        return comptime parse(text) orelse @compileError("theme name does not fit");
    }

    pub fn slice(self: *const ThemeName) []const u8 {
        return self.bytes[0..self.length];
    }

    pub fn eql(self: *const ThemeName, text: []const u8) bool {
        return std.mem.eql(u8, self.slice(), text);
    }
};

/// The files a look is read from. Where they live is the backend's business.
pub const File = union(enum) {
    /// `config.ini`.
    config,
    /// `themes/NAME.ini`; the payload is the name.
    theme: []const u8,
    /// The palette the desktop publishes for its own panels.
    desktop_palette,
};

/// What the configuration file says apart from the look itself.
pub const Settings = struct {
    theme: ThemeName = ThemeName.of(auto_theme),
    /// Whether the page rail is open when a document opens.
    rail_open: bool = true,

    pub fn parse(data: []const u8) Settings {
        var settings = Settings{};
        var entries = ini.entries(data);
        while (entries.next()) |entry| {
            if (entry.in("general") and entry.is("theme")) {
                if (ThemeName.parse(entry.value)) |name| {
                    settings.theme = name;
                } else invalid(entry);
            } else if (entry.in("view") and entry.is("rail")) {
                if (ini.parseBool(entry.value)) |open| {
                    settings.rail_open = open;
                } else invalid(entry);
            }
        }
        return settings;
    }

    /// Whether the theme lives in a file of the themes folder.
    pub fn themeIsFile(self: *const Settings) bool {
        const name = self.theme.slice();
        return !std.mem.eql(u8, name, auto_theme) and !std.mem.eql(u8, name, classic_theme) and
            findBuiltin(name) == null;
    }
};

/// The few colors a theme is made of. Everything a palette needs beyond
/// them is worked out, unless the theme says otherwise.
pub const Seeds = struct {
    /// Panels: the rail, the annotation margin, and by default the header.
    bg: Rgba,
    fg: Rgba,
    accent: Rgba,
    dark: ?bool = null,
    /// What raised surfaces, hovers, and rules are tinted with: white on a
    /// dark theme. They are this color at 5.5 %, 12 %, and 11 % over `bg`.
    far: ?Rgba = null,
    muted: ?Rgba = null,
    /// Behind the page.
    canvas: ?Rgba = null,
    header: ?Rgba = null,
    header_text: ?Rgba = null,
    surface: ?Rgba = null,
    hover: ?Rgba = null,
    border: ?Rgba = null,
    danger: ?Rgba = null,
    success: ?Rgba = null,

    const raised_veil: f32 = 0.055;
    const active_veil: f32 = 0.12;
    const line_veil: f32 = 0.11;

    pub fn isDark(self: Seeds) bool {
        return self.dark orelse (theme.luminance(self.bg) < 0.5);
    }

    pub fn palette(self: Seeds) Palette {
        const dark = self.isDark();
        const far = self.far orelse if (dark) theme.white else theme.rgb(0, 0, 0);
        const black = theme.rgb(0, 0, 0);
        return .{
            .background = self.canvas orelse theme.mix(self.bg, black, if (dark) 0.28 else 0.06),
            .header = self.header orelse self.bg,
            .panel = self.bg,
            .surface = self.surface orelse theme.mix(self.bg, far, raised_veil),
            .hover = self.hover orelse theme.mix(self.bg, far, active_veil),
            .border = self.border orelse theme.mix(self.bg, far, line_veil),
            .header_text = self.header_text orelse self.fg,
            .text = self.fg,
            .muted = self.muted orelse theme.mix(self.fg, self.bg, 0.4),
            .accent = self.accent,
            .danger = self.danger orelse if (dark) theme.hex(0xf0707f) else theme.hex(0xc0392b),
            .success = self.success orelse if (dark) theme.hex(0x82cdbb) else theme.hex(0x299b63),
            .paper = theme.white,
        };
    }

    fn optional(self: *Seeds, name: []const u8) ?*?Rgba {
        const slots = [_]struct { name: []const u8, color: *?Rgba }{
            .{ .name = "far", .color = &self.far },
            .{ .name = "muted", .color = &self.muted },
            .{ .name = "canvas", .color = &self.canvas },
            .{ .name = "header", .color = &self.header },
            .{ .name = "header_text", .color = &self.header_text },
            .{ .name = "surface", .color = &self.surface },
            .{ .name = "hover", .color = &self.hover },
            .{ .name = "border", .color = &self.border },
            .{ .name = "danger", .color = &self.danger },
            .{ .name = "success", .color = &self.success },
        };
        for (slots) |slot| {
            if (std.mem.eql(u8, slot.name, name)) return slot.color;
        }
        return null;
    }
};

pub const Builtin = struct {
    id: []const u8,
    seeds: Seeds,
};

fn builtin(id: []const u8, bg: u24, fg: u24, accent: u24) Builtin {
    return .{ .id = id, .seeds = .{
        .bg = theme.hex(bg),
        .fg = theme.hex(fg),
        .accent = theme.hex(accent),
    } };
}

pub const builtins = [_]Builtin{
    builtin("catppuccin-mocha", 0x1e1e2e, 0xcdd6f4, 0xcba6f7),
    builtin("catppuccin-latte", 0xeff1f5, 0x4c4f69, 0x8839ef),
    builtin("dracula", 0x282a36, 0xf8f8f2, 0xbd93f9),
    builtin("nord", 0x2e3440, 0xeceff4, 0x88c0d0),
    builtin("gruvbox-dark", 0x282828, 0xebdbb2, 0xfe8019),
    builtin("gruvbox-light", 0xfbf1c7, 0x3c3836, 0xaf3a03),
    builtin("tokyo-night", 0x1a1b26, 0xc0caf5, 0x7aa2f7),
    builtin("rose-pine", 0x191724, 0xe0def4, 0xebbcba),
    builtin("one-dark", 0x282c34, 0xabb2bf, 0x61afef),
    builtin("solarized-dark", 0x002b36, 0x93a1a1, 0x268bd2),
    builtin("solarized-light", 0xfdf6e3, 0x586e75, 0x268bd2),
    builtin("black", 0x0a0a0a, 0xe8e8e8, 0xffffff),
};

pub fn findBuiltin(id: []const u8) ?Seeds {
    for (builtins) |candidate| {
        if (std.mem.eql(u8, candidate.id, id)) return candidate.seeds;
    }
    return null;
}

/// Seeds from rice-palette's JSON, the palette the desktop's panels read: a
/// flat object of `"key": "#rrggbb"`. Null when it lacks the three colors a
/// theme needs.
pub fn desktopSeeds(json: []const u8) ?Seeds {
    const accent = jsonColor(json, "accent") orelse return null;
    var seeds = Seeds{
        .bg = jsonColor(json, "sysBg") orelse jsonColor(json, "bg") orelse return null,
        .fg = jsonColor(json, "sysFg") orelse jsonColor(json, "fg") orelse return null,
        .accent = accent,
    };
    if (jsonString(json, "mode")) |mode| {
        seeds.dark = !std.mem.eql(u8, mode, "light");
    }
    seeds.far = jsonColor(json, "far");
    seeds.muted = jsonColor(json, "sysMuted");
    seeds.canvas = jsonColor(json, "ground");
    seeds.surface = jsonColor(json, "sysRaised");
    seeds.hover = jsonColor(json, "sysActive");
    seeds.border = jsonColor(json, "sysLine");
    seeds.danger = jsonColor(json, "critical");
    seeds.success = jsonColor(json, "success");
    return seeds;
}

/// The string value of a top-level key, without unescaping: the palette
/// only holds names and colors.
fn jsonString(json: []const u8, key: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, json, at, key)) |found| {
        at = found + key.len;
        if (found == 0 or json[found - 1] != '"') continue;
        if (at >= json.len or json[at] != '"') continue;
        var rest = std.mem.trim(u8, json[at + 1 ..], " \t\r\n");
        if (rest.len == 0 or rest[0] != ':') continue;
        rest = std.mem.trim(u8, rest[1..], " \t\r\n");
        if (rest.len == 0 or rest[0] != '"') return null;
        const end = std.mem.indexOfScalar(u8, rest[1..], '"') orelse return null;
        return rest[1 .. 1 + end];
    }
    return null;
}

fn jsonColor(json: []const u8, key: []const u8) ?Rgba {
    return theme.parseColor(jsonString(json, key) orelse return null);
}

/// Seeds from the `[theme]` section of a theme file. Null, with a warning,
/// when `bg`, `fg`, or `accent` is missing.
pub fn fileSeeds(data: []const u8) ?Seeds {
    var bg: ?Rgba = null;
    var fg: ?Rgba = null;
    var accent: ?Rgba = null;
    var seeds = Seeds{ .bg = theme.white, .fg = theme.white, .accent = theme.white };
    var entries = ini.entries(data);
    while (entries.next()) |entry| {
        if (!entry.in("theme") or entry.is("name")) continue;
        if (entry.is("dark")) {
            if (ini.parseBool(entry.value)) |dark| seeds.dark = dark else invalid(entry);
            continue;
        }
        const color = theme.parseColor(entry.value) orelse {
            invalid(entry);
            continue;
        };
        if (entry.is("bg")) {
            bg = color;
        } else if (entry.is("fg")) {
            fg = color;
        } else if (entry.is("accent")) {
            accent = color;
        } else if (seeds.optional(entry.key)) |slot| {
            slot.* = color;
        } else unknown(entry);
    }
    seeds.bg = bg orelse return missing("bg");
    seeds.fg = fg orelse return missing("fg");
    seeds.accent = accent orelse return missing("accent");
    return seeds;
}

fn missing(key: []const u8) ?Seeds {
    log.warn("the theme file needs {s} in [theme]", .{key});
    return null;
}

fn invalid(entry: ini.Entry) void {
    log.warn("[{s}] {s} = {s} is not valid, keeping the default", .{
        entry.section, entry.key, entry.value,
    });
}

fn unknown(entry: ini.Entry) void {
    log.warn("[{s}] has no setting named {s}", .{ entry.section, entry.key });
}

/// Applies the `[style]`, `[colors]`, `[ink]`, and `[pen]` sections of a
/// configuration or theme file on top of a look.
pub fn applyOverrides(look: *Look, data: []const u8) void {
    var entries = ini.entries(data);
    while (entries.next()) |entry| {
        if (entry.in("style")) {
            if (entry.is("font")) {
                if (theme.Font.parse(entry.value)) |font| {
                    look.style.font = font;
                } else invalid(entry);
            } else if (entry.is("radius")) {
                if (parseNumber(entry.value, 0, theme.Style.maximum_radius)) |radius| {
                    look.style.radius = radius;
                } else invalid(entry);
            } else unknown(entry);
        } else if (entry.in("colors")) {
            setColor(look.palette.slot(entry.key), entry);
        } else if (entry.in("ink")) {
            setColor(look.inks.slot(entry.key), entry);
        } else if (entry.in("pen")) {
            const slot = look.pens.slot(entry.key) orelse {
                unknown(entry);
                continue;
            };
            const minimum = theme.Pens.minimum_width;
            if (parseNumber(entry.value, minimum, theme.Pens.maximum_width)) |width| {
                slot.* = width;
            } else invalid(entry);
        }
    }
}

fn setColor(slot: ?*Rgba, entry: ini.Entry) void {
    const target = slot orelse return unknown(entry);
    target.* = theme.parseColor(entry.value) orelse return invalid(entry);
}

/// A finite number, clamped to the range.
fn parseNumber(text: []const u8, minimum: f32, maximum: f32) ?f32 {
    const value = std.fmt.parseFloat(f32, text) catch return null;
    if (!std.math.isFinite(value)) return null;
    return std.math.clamp(value, minimum, maximum);
}

/// The text a look is resolved from. A missing file is null.
pub const Sources = struct {
    config: ?[]const u8 = null,
    /// The file of the theme the configuration names, when the theme is
    /// neither built in nor `auto`.
    theme_file: ?[]const u8 = null,
    /// rice-palette's JSON, read only for the `auto` theme.
    desktop_palette: ?[]const u8 = null,
};

pub const Origin = enum {
    /// Lectern's own look, which has a light and a dark side.
    classic,
    desktop,
    builtin,
    file,
};

pub const Resolved = struct {
    look: Look,
    settings: Settings,
    origin: Origin,
};

/// Builds the look. `dark_mode` is the reading mode the user toggles: it
/// picks the side of Lectern's own look, and under every other theme only
/// the paper a page waits on, since the theme itself decides the chrome.
pub fn resolve(sources: Sources, dark_mode: bool) Resolved {
    const settings = Settings.parse(sources.config orelse "");
    const name = settings.theme.slice();
    var look = Look.classic(dark_mode);
    var origin = Origin.classic;

    if (std.mem.eql(u8, name, auto_theme)) {
        if (sources.desktop_palette) |json| {
            if (desktopSeeds(json)) |seeds| {
                look = .{ .palette = seeds.palette() };
                look.style.font = theme.Font.of(desktop_font);
                look.style.radius = desktop_radius;
                origin = .desktop;
            } else log.warn("the desktop palette has no bg, fg, and accent; using {s}", .{
                classic_theme,
            });
        }
    } else if (std.mem.eql(u8, name, classic_theme)) {
        // Already there.
    } else if (findBuiltin(name)) |seeds| {
        look = .{ .palette = seeds.palette() };
        origin = .builtin;
    } else if (sources.theme_file) |data| {
        if (fileSeeds(data)) |seeds| {
            look = .{ .palette = seeds.palette() };
            origin = .file;
        }
    } else log.warn("no theme named {s}; using {s}", .{ name, classic_theme });

    if (origin != .classic and dark_mode) look.palette.paper = look.palette.surface;
    if (origin == .file) applyOverrides(&look, sources.theme_file.?);
    if (sources.config) |data| applyOverrides(&look, data);
    return .{ .look = look, .settings = settings, .origin = origin };
}

/// Written as `config.ini` the first time Lectern starts, so the settings
/// document themselves where they are edited.
pub const template =
    \\# Lectern settings. Every line is optional: remove one (or leave it
    \\# commented) to get the default. Lectern reloads this file when it changes.
    \\
    \\[general]
    \\# auto follows the desktop palette (~/.cache/rice/palette.json) and falls
    \\# back to lectern, the paper desk, without one. Built in: lectern,
    \\# catppuccin-mocha, catppuccin-latte, dracula, nord, gruvbox-dark,
    \\# gruvbox-light, tokyo-night, rose-pine, one-dark, solarized-dark,
    \\# solarized-light, black. Your own go in themes/NAME.ini beside this file;
    \\# themes/example.ini is one to copy from.
    \\#theme = auto
    \\
    \\[view]
    \\# Open the page rail with every document
    \\#rail = true
    \\
    \\[style]
    \\# The interface font (the PDF keeps its own) and the corner radius of
    \\# hovers, selections, and buttons; 0 is square.
    \\#font = Noto Sans
    \\#radius = 0
    \\
    \\[colors]
    \\# Any color of the active theme, one by one: background header panel
    \\# surface hover border header_text text muted accent danger success paper
    \\#accent = #2363d8
    \\
    \\[ink]
    \\# The annotation inks: blue red black yellow green purple, and
    \\# black_on_dark, what black ink becomes on a dark page.
    \\#yellow = #f3c341
    \\
    \\[pen]
    \\# Stroke widths in pixels
    \\#thin = 2
    \\#medium = 4
    \\#thick = 8
    \\
;

/// A starting point for a theme of your own.
pub const theme_template =
    \\# A Lectern theme. Three colors are enough; the rest are worked out from
    \\# them unless you set them. Lectern reloads this file as you save it.
    \\
    \\[theme]
    \\bg = #1e1e2e
    \\fg = #cdd6f4
    \\accent = #cba6f7
    \\
    \\# Optional: far (what hovers and rules are tinted with), muted, canvas
    \\# (behind the page), header, header_text, surface, hover, border, danger,
    \\# success, and dark = true | false.
    \\
    \\# A theme can also carry the [style], [colors], [ink], and [pen] sections
    \\# of config.ini; config.ini still wins.
    \\#[style]
    \\#font = JetBrainsMono Nerd Font
    \\#radius = 6
    \\
;

const frieren =
    \\{ "theme": "Frieren", "mode": "dark", "bg": "#19100d", "fg": "#ffffff",
    \\ "far": "#ffffff", "accent": "#da9967", "ground": "#160e0b",
    \\ "sysBg": "#201916", "sysRaised": "#27201d", "sysActive": "#342d2b",
    \\ "sysLine": "#403937", "sysFg": "#dad8d8", "sysMuted": "#a29f9d",
    \\ "critical": "#f0707f", "success": "#82cdbb" }
;

test "settings read the theme and the rail and ignore the rest" {
    const defaults = Settings.parse("");
    try std.testing.expect(defaults.theme.eql(auto_theme));
    try std.testing.expect(defaults.rail_open);
    try std.testing.expect(!defaults.themeIsFile());

    const settings = Settings.parse(
        \\[general]
        \\theme = midnight
        \\[view]
        \\rail = off
        \\[colors]
        \\theme = #ffffff
    );
    try std.testing.expect(settings.theme.eql("midnight"));
    try std.testing.expect(!settings.rail_open);
    try std.testing.expect(settings.themeIsFile());

    try std.testing.expect(!Settings.parse("[general]\ntheme = nord\n").themeIsFile());
    try std.testing.expect(!Settings.parse("[general]\ntheme = lectern\n").themeIsFile());
    // A name that could leave the themes folder keeps the default.
    try std.testing.expect(Settings.parse("[general]\ntheme = ../secret\n").theme.eql(auto_theme));
    try std.testing.expect(Settings.parse("[general]\ntheme = .hidden\n").theme.eql(auto_theme));
    try std.testing.expect(Settings.parse("[view]\nrail = perhaps\n").rail_open);
}

test "seeds derive every role and keep the ones a theme gives" {
    const dark = (Seeds{
        .bg = theme.hex(0x202020),
        .fg = theme.hex(0xe0e0e0),
        .accent = theme.hex(0xff8800),
    }).palette();
    try std.testing.expectEqual(theme.hex(0x202020), dark.panel);
    try std.testing.expectEqual(theme.hex(0x202020), dark.header);
    try std.testing.expectEqual(theme.hex(0xe0e0e0), dark.text);
    try std.testing.expectEqual(theme.hex(0xe0e0e0), dark.header_text);
    try std.testing.expectEqual(theme.hex(0xff8800), dark.accent);
    // On a dark theme the surfaces rise toward white and the desk sinks.
    try std.testing.expect(dark.surface.red > dark.panel.red);
    try std.testing.expect(dark.hover.red > dark.surface.red);
    try std.testing.expect(dark.background.red < dark.panel.red);
    try std.testing.expect(dark.muted.red < dark.text.red);

    const light = (Seeds{
        .bg = theme.hex(0xf0f0f0),
        .fg = theme.hex(0x202020),
        .accent = theme.hex(0x0055ff),
        .header = theme.hex(0x111111),
        .header_text = theme.hex(0xeeeeee),
        .border = theme.hex(0x123456),
    }).palette();
    try std.testing.expect(light.surface.red < light.panel.red);
    try std.testing.expectEqual(theme.hex(0x111111), light.header);
    try std.testing.expectEqual(theme.hex(0xeeeeee), light.header_text);
    try std.testing.expectEqual(theme.hex(0x123456), light.border);
    try std.testing.expect(!std.meta.eql(light.danger, dark.danger));
}

test "the desktop palette becomes a look with the desktop's font and corners" {
    const resolved = resolve(.{ .desktop_palette = frieren }, false);
    try std.testing.expectEqual(Origin.desktop, resolved.origin);
    const palette = resolved.look.palette;
    try std.testing.expectEqual(theme.hex(0x201916), palette.panel);
    try std.testing.expectEqual(theme.hex(0x201916), palette.header);
    try std.testing.expectEqual(theme.hex(0x160e0b), palette.background);
    try std.testing.expectEqual(theme.hex(0x27201d), palette.surface);
    try std.testing.expectEqual(theme.hex(0x342d2b), palette.hover);
    try std.testing.expectEqual(theme.hex(0x403937), palette.border);
    try std.testing.expectEqual(theme.hex(0xdad8d8), palette.text);
    try std.testing.expectEqual(theme.hex(0xa29f9d), palette.muted);
    try std.testing.expectEqual(theme.hex(0xda9967), palette.accent);
    try std.testing.expectEqual(theme.hex(0xf0707f), palette.danger);
    try std.testing.expectEqual(theme.hex(0x82cdbb), palette.success);
    try std.testing.expectEqual(theme.white, palette.paper);
    try std.testing.expectEqualStrings(desktop_font, resolved.look.style.font.slice());
    try std.testing.expectEqual(desktop_radius, resolved.look.style.radius);

    // The reading mode only changes the paper a page waits on.
    const night = resolve(.{ .desktop_palette = frieren }, true);
    try std.testing.expectEqual(palette.panel, night.look.palette.panel);
    try std.testing.expectEqual(palette.surface, night.look.palette.paper);
}

test "a palette with only the base colors still makes a theme, and a broken one does not" {
    const seeds = desktopSeeds(
        \\{"bg":"#101010","fg" : "#f0f0f0", "accent":"#ff0000","mode":"light"}
    ).?;
    try std.testing.expectEqual(theme.hex(0x101010), seeds.bg);
    try std.testing.expectEqual(@as(?bool, false), seeds.dark);
    try std.testing.expectEqual(@as(?Rgba, null), seeds.surface);

    try std.testing.expectEqual(@as(?Seeds, null), desktopSeeds("{}"));
    try std.testing.expectEqual(@as(?Seeds, null), desktopSeeds(""));
    try std.testing.expectEqual(@as(?Seeds, null), desktopSeeds("{\"bg\":\"#101010\"}"));
    // A key that is only the tail of another one, or holds no string, is
    // not mistaken for it.
    try std.testing.expectEqual(
        @as(?Seeds, null),
        desktopSeeds("{\"sysBg\":\"#101010\",\"sysFg\":\"#ffffff\",\"myaccent\":\"#ff0000\"}"),
    );
    try std.testing.expectEqual(
        @as(?Seeds, null),
        desktopSeeds("{\"bg\":\"#101010\",\"fg\":\"#ffffff\",\"accent\":12}"),
    );
}

test "without a desktop palette the automatic theme is Lectern's own" {
    for ([_]bool{ false, true }) |dark_mode| {
        const resolved = resolve(.{}, dark_mode);
        try std.testing.expectEqual(Origin.classic, resolved.origin);
        try std.testing.expect(std.meta.eql(Look.classic(dark_mode), resolved.look));
    }
    const broken = resolve(.{ .desktop_palette = "not json" }, true);
    try std.testing.expectEqual(Origin.classic, broken.origin);
    try std.testing.expect(std.meta.eql(Look.classic(true), broken.look));
}

test "the configuration picks the theme and overrides it piece by piece" {
    const config =
        \\[general]
        \\theme = nord
        \\[style]
        \\font = Inter
        \\radius = 40
        \\[colors]
        \\accent = #ff0000
        \\nonsense = #ffffff
        \\border = not-a-color
        \\[ink]
        \\yellow = #fff000
        \\[pen]
        \\thin = 1.5
        \\thick = 900
        \\medium = wide
    ;
    const resolved = resolve(.{ .config = config, .desktop_palette = frieren }, false);
    try std.testing.expectEqual(Origin.builtin, resolved.origin);
    const look = resolved.look;
    try std.testing.expectEqual(theme.hex(0x2e3440), look.palette.panel);
    try std.testing.expectEqual(theme.hex(0xff0000), look.palette.accent);
    const untouched = findBuiltin("nord").?.palette();
    try std.testing.expectEqual(untouched.border, look.palette.border);
    try std.testing.expectEqualStrings("Inter", look.style.font.slice());
    try std.testing.expectEqual(theme.Style.maximum_radius, look.style.radius);
    try std.testing.expectEqual(theme.hex(0xfff000), look.inks.yellow);
    try std.testing.expectEqual(@as(f32, 1.5), look.pens.thin);
    try std.testing.expectEqual(theme.Pens.maximum_width, look.pens.thick);
    try std.testing.expectEqual(@as(f32, 4), look.pens.medium);

    // Lectern's own look can be asked for by name even on a themed desktop,
    // and still takes overrides.
    const classic = resolve(.{
        .config = "[general]\ntheme = lectern\n[colors]\naccent = #00ff00\n",
        .desktop_palette = frieren,
    }, true);
    try std.testing.expectEqual(Origin.classic, classic.origin);
    try std.testing.expectEqual(Palette.forMode(true).panel, classic.look.palette.panel);
    try std.testing.expectEqual(theme.hex(0x00ff00), classic.look.palette.accent);
}

test "a theme file gives the colors and may carry its own style" {
    const file =
        \\[theme]
        \\name = Midnight
        \\bg = #0f1117
        \\fg = #e6e6e6
        \\accent = #7c9cff
        \\header = #000000
        \\dark = yes
        \\shadow = #000000
        \\[style]
        \\radius = 8
        \\font = Iosevka
        \\[ink]
        \\blue = #0000ff
    ;
    const config = "[general]\ntheme = midnight\n[style]\nradius = 2\n";
    const resolved = resolve(.{ .config = config, .theme_file = file }, false);
    try std.testing.expectEqual(Origin.file, resolved.origin);
    try std.testing.expectEqual(theme.hex(0x0f1117), resolved.look.palette.panel);
    try std.testing.expectEqual(theme.hex(0x000000), resolved.look.palette.header);
    try std.testing.expectEqual(theme.hex(0x7c9cff), resolved.look.palette.accent);
    try std.testing.expectEqual(theme.hex(0x0000ff), resolved.look.inks.blue);
    try std.testing.expectEqualStrings("Iosevka", resolved.look.style.font.slice());
    // The configuration file wins over the theme's own style.
    try std.testing.expectEqual(@as(f32, 2), resolved.look.style.radius);

    // A theme file without its three colors, or a theme with no file, falls
    // back to Lectern's own look.
    const incomplete = resolve(.{ .config = config, .theme_file = "[theme]\nbg = #000\n" }, false);
    try std.testing.expectEqual(Origin.classic, incomplete.origin);
    const absent = resolve(.{ .config = config }, false);
    try std.testing.expectEqual(Origin.classic, absent.origin);
    try std.testing.expectEqual(Palette.forMode(false).panel, absent.look.palette.panel);
}

test "the templates are valid and change nothing" {
    const resolved = resolve(.{ .config = template }, false);
    try std.testing.expect(std.meta.eql(Look.classic(false), resolved.look));
    try std.testing.expect(resolved.settings.theme.eql(auto_theme));
    try std.testing.expect(fileSeeds(theme_template) != null);
    for (builtins) |candidate| {
        try std.testing.expect(ThemeName.parse(candidate.id) != null);
        try std.testing.expect(std.mem.indexOf(u8, template, candidate.id) != null);
    }
}
