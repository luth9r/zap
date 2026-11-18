const std = @import("std");
const testing = std.testing;

pub const ColorType = union(enum) {
    none,
    ansi_16: u8,
    ansi_256: u8,
    rgb: struct { r: u8, g: u8, b: u8 },
};

pub const Modifiers = struct {
    bold: bool = false,
    dimmed: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    inverted: bool = false,
    hidden: bool = false,
    strikethrough: bool = false,
    reset: bool = false,
};

pub const ModifierKind = enum {
    bold,
    dimmed,
    italic,
    underline,
    blink,
    inverted,
    hidden,
    strikethrough,
    reset,
};

const modifier_map = std.StaticStringMapWithEql(ModifierKind, std.static_string_map.eqlAsciiIgnoreCase).initComptime(.{
    .{ "bold", .bold },
    .{ "dimmed", .dimmed },
    .{ "dim", .dimmed },
    .{ "italic", .italic },
    .{ "underline", .underline },
    .{ "underlined", .underline },
    .{ "blink", .blink },
    .{ "inverted", .inverted },
    .{ "invert", .inverted },
    .{ "hidden", .hidden },
    .{ "strikethrough", .strikethrough },
    .{ "reset", .reset },
});

pub fn parseModifierToken(token: []const u8) ?ModifierKind {
    return modifier_map.get(token);
}

pub const Style = struct {
    fg: ColorType = .none,
    bg: ColorType = .none,
    modifiers: Modifiers = .{},
    is_none: bool = false,

    pub fn applyToken(self: *Style, token: []const u8) bool {
        if (std.ascii.eqlIgnoreCase(token, "none")) {
            self.is_none = true;
            return true;
        }

        if (parseModifierToken(token)) |mod| {
            switch (mod) {
                .bold => self.modifiers.bold = true,
                .dimmed => self.modifiers.dimmed = true,
                .italic => self.modifiers.italic = true,
                .underline => self.modifiers.underline = true,
                .blink => self.modifiers.blink = true,
                .inverted => self.modifiers.inverted = true,
                .hidden => self.modifiers.hidden = true,
                .strikethrough => self.modifiers.strikethrough = true,
                .reset => self.modifiers.reset = true,
            }
            return true;
        }

        if (std.ascii.startsWithIgnoreCase(token, "fg:")) {
            const color_val = token[3..];
            if (std.ascii.eqlIgnoreCase(color_val, "none")) {
                self.fg = .{ .ansi_16 = 39 };
                return true;
            }
            if (parseColorToken(color_val, false)) |col| {
                self.fg = col;
                return true;
            }
            return false;
        }

        if (std.ascii.startsWithIgnoreCase(token, "bg:")) {
            const color_val = token[3..];
            if (std.ascii.eqlIgnoreCase(color_val, "none")) {
                self.bg = .{ .ansi_16 = 49 };
                return true;
            }
            if (parseColorToken(color_val, true)) |col| {
                self.bg = col;
                return true;
            }
            return false;
        }

        if (parseColorToken(token, false)) |col| {
            self.fg = col;
            return true;
        }

        return false;
    }

    pub fn parse(raw_style: []const u8) Style {
        var style = Style{};
        const trimmed = std.mem.trim(u8, raw_style, " \t\r\n");
        if (trimmed.len == 0) {
            style.is_none = true;
            return style;
        }

        var it = std.mem.tokenizeAny(u8, trimmed, " \t\r\n");
        while (it.next()) |token| {
            _ = style.applyToken(token);
        }

        return style;
    }

    pub fn isValidToken(token: []const u8) bool {
        var dummy = Style{};
        return dummy.applyToken(token);
    }

    pub fn validate(raw_style: []const u8) ?[]const u8 {
        const trimmed = std.mem.trim(u8, raw_style, " \t\r\n");
        if (trimmed.len == 0) return null;

        var it = std.mem.tokenizeAny(u8, trimmed, " \t\r\n");
        while (it.next()) |token| {
            if (!isValidToken(token)) {
                return token;
            }
        }
        return null;
    }

    fn parseColorToken(token: []const u8, is_bg: bool) ?ColorType {
        const trimmed = std.mem.trim(u8, token, " \t");
        if (trimmed.len == 0) return null;

        // Check if hex color: #RGB or #RRGGBB
        if (trimmed[0] == '#') {
            const hex = trimmed[1..];
            if (hex.len == 6) {
                const r = std.fmt.parseInt(u8, hex[0..2], 16) catch return null;
                const g = std.fmt.parseInt(u8, hex[2..4], 16) catch return null;
                const b = std.fmt.parseInt(u8, hex[4..6], 16) catch return null;
                return .{ .rgb = .{ .r = r, .g = g, .b = b } };
            } else if (hex.len == 3) {
                const r_nib = std.fmt.parseInt(u8, hex[0..1], 16) catch return null;
                const g_nib = std.fmt.parseInt(u8, hex[1..2], 16) catch return null;
                const b_nib = std.fmt.parseInt(u8, hex[2..3], 16) catch return null;
                return .{ .rgb = .{ .r = r_nib * 17, .g = g_nib * 17, .b = b_nib * 17 } };
            }
            return null;
        }

        // Check if integer (0-255) 8-bit ANSI color
        if (std.fmt.parseInt(u8, trimmed, 10)) |ansi_num| {
            return .{ .ansi_256 = ansi_num };
        } else |_| {}

        // Check named colors
        return parseNamedColor(trimmed, is_bg);
    }

    const named_fg_color_map = std.StaticStringMapWithEql(u8, std.static_string_map.eqlAsciiIgnoreCase).initComptime(.{
        .{ "black", 30 },
        .{ "red", 31 },
        .{ "green", 32 },
        .{ "yellow", 33 },
        .{ "blue", 34 },
        .{ "magenta", 35 },
        .{ "purple", 35 },
        .{ "cyan", 36 },
        .{ "white", 37 },
        .{ "gray", 90 },
        .{ "grey", 90 },
        .{ "bright-black", 90 },
        .{ "bright_black", 90 },
        .{ "bright-red", 91 },
        .{ "bright_red", 91 },
        .{ "bright-green", 92 },
        .{ "bright_green", 92 },
        .{ "bright-yellow", 93 },
        .{ "bright_yellow", 93 },
        .{ "bright-blue", 94 },
        .{ "bright_blue", 94 },
        .{ "bright-magenta", 95 },
        .{ "bright_magenta", 95 },
        .{ "bright-purple", 95 },
        .{ "bright_purple", 95 },
        .{ "bright-cyan", 96 },
        .{ "bright_cyan", 96 },
        .{ "bright-white", 97 },
        .{ "bright_white", 97 },
    });

    fn parseNamedColor(name: []const u8, is_bg: bool) ?ColorType {
        const fg_code = named_fg_color_map.get(name) orelse return null;
        return .{ .ansi_16 = if (is_bg) fg_code + 10 else fg_code };
    }

    /// Note: used exclusively for unit tests. In runtime, toAnsiBuf is used instead.
    pub fn toAnsi(self: Style, allocator: std.mem.Allocator) ![]const u8 {
        if (self.is_none) return try allocator.dupe(u8, "");

        var buf: [128]u8 = undefined;
        const slice = self.toAnsiBuf(&buf) orelse return try allocator.dupe(u8, "");
        return try allocator.dupe(u8, slice);
    }

    fn writeColorCode(buf: []u8, pos: *usize, color: ColorType, is_bg: bool, has_prev: *bool) ?void {
        if (color == .none) return;
        if (has_prev.*) {
            if (pos.* >= buf.len) return null;
            buf[pos.*] = ';';
            pos.* += 1;
        }
        const prefix: u8 = if (is_bg) 48 else 38;
        const formatted = switch (color) {
            .none => unreachable,
            .ansi_16 => |code| std.fmt.bufPrint(buf[pos.*..], "{d}", .{code}) catch return null,
            .ansi_256 => |code| std.fmt.bufPrint(buf[pos.*..], "{d};5;{d}", .{ prefix, code }) catch return null,
            .rgb => |rgb| std.fmt.bufPrint(buf[pos.*..], "{d};2;{d};{d};{d}", .{ prefix, rgb.r, rgb.g, rgb.b }) catch return null,
        };
        pos.* += formatted.len;
        has_prev.* = true;
    }

    pub fn toAnsiBuf(self: Style, buf: []u8) ?[]const u8 {
        if (self.is_none) return buf[0..0];

        var pos: usize = 0;
        const prefix = "\x1b[";
        if (pos + prefix.len > buf.len) return null;
        @memcpy(buf[pos .. pos + prefix.len], prefix);
        pos += prefix.len;

        var has_prev = false;

        const mod_entries = [_]struct { enabled: bool, code: []const u8 }{
            .{ .enabled = self.modifiers.reset, .code = "0" },
            .{ .enabled = self.modifiers.bold, .code = "1" },
            .{ .enabled = self.modifiers.dimmed, .code = "2" },
            .{ .enabled = self.modifiers.italic, .code = "3" },
            .{ .enabled = self.modifiers.underline, .code = "4" },
            .{ .enabled = self.modifiers.blink, .code = "5" },
            .{ .enabled = self.modifiers.inverted, .code = "7" },
            .{ .enabled = self.modifiers.hidden, .code = "8" },
            .{ .enabled = self.modifiers.strikethrough, .code = "9" },
        };

        inline for (mod_entries) |entry| {
            if (entry.enabled) {
                if (has_prev) {
                    if (pos >= buf.len) return null;
                    buf[pos] = ';';
                    pos += 1;
                }
                if (pos + entry.code.len > buf.len) return null;
                @memcpy(buf[pos .. pos + entry.code.len], entry.code);
                pos += entry.code.len;
                has_prev = true;
            }
        }

        writeColorCode(buf, &pos, self.fg, false, &has_prev) orelse return null;
        writeColorCode(buf, &pos, self.bg, true, &has_prev) orelse return null;

        if (!has_prev) return buf[0..0];

        if (pos >= buf.len) return null;
        buf[pos] = 'm';
        pos += 1;
        return buf[0..pos];
    }
};

/// Note: used exclusively for unit tests. In runtime, renderStyleBuf is used instead (zero heap allocations).
pub fn renderStyle(allocator: std.mem.Allocator, style_str: []const u8) ![]const u8 {
    const style = Style.parse(style_str);
    return try style.toAnsi(allocator);
}

pub fn renderStyleBuf(buf: []u8, style_str: []const u8) ?[]const u8 {
    const style = Style.parse(style_str);
    return style.toAnsiBuf(buf);
}

test "unit: empty string or none produces empty ansi" {
    const a = testing.allocator;

    const res_empty = try renderStyle(a, "");
    defer a.free(res_empty);
    try testing.expectEqualStrings("", res_empty);

    const res_none = try renderStyle(a, "none");
    defer a.free(res_none);
    try testing.expectEqualStrings("", res_none);

    const res_spaces = try renderStyle(a, "   ");
    defer a.free(res_spaces);
    try testing.expectEqualStrings("", res_spaces);
}

test "unit: named foreground and background colors" {
    const a = testing.allocator;

    const res_green = try renderStyle(a, "green");
    defer a.free(res_green);
    try testing.expectEqualStrings("\x1b[32m", res_green);

    const res_fg_red = try renderStyle(a, "fg:red");
    defer a.free(res_fg_red);
    try testing.expectEqualStrings("\x1b[31m", res_fg_red);

    const res_bg_blue = try renderStyle(a, "bg:blue");
    defer a.free(res_bg_blue);
    try testing.expectEqualStrings("\x1b[44m", res_bg_blue);

    const res_fg_bg = try renderStyle(a, "fg:green bg:blue");
    defer a.free(res_fg_bg);
    try testing.expectEqualStrings("\x1b[32;44m", res_fg_bg);
}

test "unit: bright colors and aliases" {
    const a = testing.allocator;

    const res_gray = try renderStyle(a, "gray");
    defer a.free(res_gray);
    try testing.expectEqualStrings("\x1b[90m", res_gray);

    const res_bright_green = try renderStyle(a, "bright-green");
    defer a.free(res_bright_green);
    try testing.expectEqualStrings("\x1b[92m", res_bright_green);

    const res_bg_bright_green = try renderStyle(a, "bg:bright-green");
    defer a.free(res_bg_bright_green);
    try testing.expectEqualStrings("\x1b[102m", res_bg_bright_green);

    const res_purple = try renderStyle(a, "purple");
    defer a.free(res_purple);
    try testing.expectEqualStrings("\x1b[35m", res_purple);
}

test "unit: modifiers: bold, italic, underline, dimmed, inverted, strikethrough" {
    const a = testing.allocator;

    const res_bold = try renderStyle(a, "bold");
    defer a.free(res_bold);
    try testing.expectEqualStrings("\x1b[1m", res_bold);

    const res_bold_green = try renderStyle(a, "bold green");
    defer a.free(res_bold_green);
    try testing.expectEqualStrings("\x1b[1;32m", res_bold_green);

    const res_bold_italic_purple = try renderStyle(a, "bold italic fg:purple");
    defer a.free(res_bold_italic_purple);
    try testing.expectEqualStrings("\x1b[1;3;35m", res_bold_italic_purple);

    const res_underline = try renderStyle(a, "underline");
    defer a.free(res_underline);
    try testing.expectEqualStrings("\x1b[4m", res_underline);
}

test "unit: 8-bit ANSI 256 colors" {
    const a = testing.allocator;

    const res_27 = try renderStyle(a, "27");
    defer a.free(res_27);
    try testing.expectEqualStrings("\x1b[38;5;27m", res_27);

    const res_fg_27 = try renderStyle(a, "fg:27");
    defer a.free(res_fg_27);
    try testing.expectEqualStrings("\x1b[38;5;27m", res_fg_27);

    const res_bold_fg_27 = try renderStyle(a, "bold fg:27");
    defer a.free(res_bold_fg_27);
    try testing.expectEqualStrings("\x1b[1;38;5;27m", res_bold_fg_27);

    const res_bg_200 = try renderStyle(a, "bg:200");
    defer a.free(res_bg_200);
    try testing.expectEqualStrings("\x1b[48;5;200m", res_bg_200);
}

test "unit: 24-bit TrueColor Hex colors" {
    const a = testing.allocator;

    const res_hex = try renderStyle(a, "#bf5700");
    defer a.free(res_hex);
    try testing.expectEqualStrings("\x1b[38;2;191;87;0m", res_hex);

    const res_underline_bg_hex = try renderStyle(a, "underline bg:#bf5700");
    defer a.free(res_underline_bg_hex);
    try testing.expectEqualStrings("\x1b[4;48;2;191;87;0m", res_underline_bg_hex);

    const res_short_hex = try renderStyle(a, "fg:#fff");
    defer a.free(res_short_hex);
    try testing.expectEqualStrings("\x1b[38;2;255;255;255m", res_short_hex);
}

test "unit: examples from documentation" {
    const a = testing.allocator;

    // 'fg:green bg:blue' sets green text on a blue background
    const ex1 = try renderStyle(a, "fg:green bg:blue");
    defer a.free(ex1);
    try testing.expectEqualStrings("\x1b[32;44m", ex1);

    // 'bg:blue fg:bright-green' sets bright green text on a blue background
    const ex2 = try renderStyle(a, "bg:blue fg:bright-green");
    defer a.free(ex2);
    try testing.expectEqualStrings("\x1b[92;44m", ex2);

    // 'bold fg:27' sets bold text with ANSI color 27
    const ex3 = try renderStyle(a, "bold fg:27");
    defer a.free(ex3);
    try testing.expectEqualStrings("\x1b[1;38;5;27m", ex3);

    // 'underline bg:#bf5700' sets underlined text on a burnt orange background
    const ex4 = try renderStyle(a, "underline bg:#bf5700");
    defer a.free(ex4);
    try testing.expectEqualStrings("\x1b[4;48;2;191;87;0m", ex4);

    // 'bold italic fg:purple' sets bold italic purple text
    const ex5 = try renderStyle(a, "bold italic fg:purple");
    defer a.free(ex5);
    try testing.expectEqualStrings("\x1b[1;3;35m", ex5);

    // '' explicitly disables all styling
    const ex6 = try renderStyle(a, "");
    defer a.free(ex6);
    try testing.expectEqualStrings("", ex6);

    var buf: [64]u8 = undefined;
    const buf_res = renderStyleBuf(&buf, "bold green").?;
    try testing.expectEqualStrings("\x1b[1;32m", buf_res);
}

test "unit: validate style strings" {
    try testing.expect(Style.validate("bold green") == null);
    try testing.expect(Style.validate("fg:red bg:blue underline") == null);
    try testing.expect(Style.validate("bg:#bf5700 fg:255") == null);
    try testing.expect(Style.validate("none") == null);
    try testing.expect(Style.validate("") == null);

    // Invalid tokens
    try testing.expectEqualStrings("invalidcolor", Style.validate("bold invalidcolor").?);
    try testing.expectEqualStrings("fg:unknowncolor", Style.validate("fg:unknowncolor").?);
    try testing.expectEqualStrings("fg:299", Style.validate("fg:299").?); // out of range 256
    try testing.expectEqualStrings("#12345", Style.validate("#12345").?); // bad hex length
}
