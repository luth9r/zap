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

pub const Style = struct {
    fg: ColorType = .none,
    bg: ColorType = .none,
    modifiers: Modifiers = .{},
    is_none: bool = false,

    pub fn parse(raw_style: []const u8) Style {
        var style = Style{};
        const trimmed = std.mem.trim(u8, raw_style, " \t\r\n");
        if (trimmed.len == 0) {
            style.is_none = true;
            return style;
        }

        var it = std.mem.tokenizeAny(u8, trimmed, " \t\r\n");
        while (it.next()) |token| {
            if (std.ascii.eqlIgnoreCase(token, "none")) {
                style.is_none = true;
                continue;
            }

            // Check modifiers
            if (std.ascii.eqlIgnoreCase(token, "bold")) {
                style.modifiers.bold = true;
            } else if (std.ascii.eqlIgnoreCase(token, "dimmed") or std.ascii.eqlIgnoreCase(token, "dim")) {
                style.modifiers.dimmed = true;
            } else if (std.ascii.eqlIgnoreCase(token, "italic")) {
                style.modifiers.italic = true;
            } else if (std.ascii.eqlIgnoreCase(token, "underline") or std.ascii.eqlIgnoreCase(token, "underlined")) {
                style.modifiers.underline = true;
            } else if (std.ascii.eqlIgnoreCase(token, "blink")) {
                style.modifiers.blink = true;
            } else if (std.ascii.eqlIgnoreCase(token, "inverted") or std.ascii.eqlIgnoreCase(token, "invert")) {
                style.modifiers.inverted = true;
            } else if (std.ascii.eqlIgnoreCase(token, "hidden")) {
                style.modifiers.hidden = true;
            } else if (std.ascii.eqlIgnoreCase(token, "strikethrough")) {
                style.modifiers.strikethrough = true;
            } else if (std.ascii.eqlIgnoreCase(token, "reset")) {
                style.modifiers.reset = true;
            } else if (std.mem.startsWith(u8, token, "fg:") or std.mem.startsWith(u8, token, "FG:")) {
                const color_val = token[3..];
                if (parseColorToken(color_val, false)) |col| {
                    style.fg = col;
                }
            } else if (std.mem.startsWith(u8, token, "bg:") or std.mem.startsWith(u8, token, "BG:")) {
                const color_val = token[3..];
                if (std.ascii.eqlIgnoreCase(color_val, "none")) {
                    style.bg = .{ .ansi_16 = 49 };
                } else if (parseColorToken(color_val, true)) |col| {
                    style.bg = col;
                }
            } else {
                // Default without prefix is foreground color
                if (parseColorToken(token, false)) |col| {
                    style.fg = col;
                }
            }
        }

        return style;
    }

    pub fn isValidToken(token: []const u8) bool {
        if (std.ascii.eqlIgnoreCase(token, "none")) return true;
        if (std.ascii.eqlIgnoreCase(token, "bold") or
            std.ascii.eqlIgnoreCase(token, "dimmed") or std.ascii.eqlIgnoreCase(token, "dim") or
            std.ascii.eqlIgnoreCase(token, "italic") or
            std.ascii.eqlIgnoreCase(token, "underline") or std.ascii.eqlIgnoreCase(token, "underlined") or
            std.ascii.eqlIgnoreCase(token, "blink") or
            std.ascii.eqlIgnoreCase(token, "inverted") or std.ascii.eqlIgnoreCase(token, "invert") or
            std.ascii.eqlIgnoreCase(token, "hidden") or
            std.ascii.eqlIgnoreCase(token, "strikethrough") or
            std.ascii.eqlIgnoreCase(token, "reset")) return true;

        if (std.mem.startsWith(u8, token, "fg:") or std.mem.startsWith(u8, token, "FG:")) {
            const color_val = token[3..];
            if (std.ascii.eqlIgnoreCase(color_val, "none")) return true;
            return parseColorToken(color_val, false) != null;
        }
        if (std.mem.startsWith(u8, token, "bg:") or std.mem.startsWith(u8, token, "BG:")) {
            const color_val = token[3..];
            if (std.ascii.eqlIgnoreCase(color_val, "none")) return true;
            return parseColorToken(color_val, true) != null;
        }

        return parseColorToken(token, false) != null;
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

    fn parseNamedColor(name: []const u8, is_bg: bool) ?ColorType {
        if (name.len == 0) return null;
        const first = std.ascii.toLower(name[0]);

        switch (first) {
            'b' => {
                if (std.ascii.eqlIgnoreCase(name, "black")) return .{ .ansi_16 = if (is_bg) 40 else 30 };
                if (std.ascii.eqlIgnoreCase(name, "blue")) return .{ .ansi_16 = if (is_bg) 44 else 34 };
                if (std.ascii.startsWithIgnoreCase(name, "bright-") or std.ascii.startsWithIgnoreCase(name, "bright_")) {
                    const sub = name[7..];
                    if (std.ascii.eqlIgnoreCase(sub, "black")) return .{ .ansi_16 = if (is_bg) 100 else 90 };
                    if (std.ascii.eqlIgnoreCase(sub, "red")) return .{ .ansi_16 = if (is_bg) 101 else 91 };
                    if (std.ascii.eqlIgnoreCase(sub, "green")) return .{ .ansi_16 = if (is_bg) 102 else 92 };
                    if (std.ascii.eqlIgnoreCase(sub, "yellow")) return .{ .ansi_16 = if (is_bg) 103 else 93 };
                    if (std.ascii.eqlIgnoreCase(sub, "blue")) return .{ .ansi_16 = if (is_bg) 104 else 94 };
                    if (std.ascii.eqlIgnoreCase(sub, "magenta") or std.ascii.eqlIgnoreCase(sub, "purple")) return .{ .ansi_16 = if (is_bg) 105 else 95 };
                    if (std.ascii.eqlIgnoreCase(sub, "cyan")) return .{ .ansi_16 = if (is_bg) 106 else 96 };
                    if (std.ascii.eqlIgnoreCase(sub, "white")) return .{ .ansi_16 = if (is_bg) 107 else 97 };
                }
            },
            'r' => {
                if (std.ascii.eqlIgnoreCase(name, "red")) return .{ .ansi_16 = if (is_bg) 41 else 31 };
            },
            'g' => {
                if (std.ascii.eqlIgnoreCase(name, "green")) return .{ .ansi_16 = if (is_bg) 42 else 32 };
                if (std.ascii.eqlIgnoreCase(name, "gray") or std.ascii.eqlIgnoreCase(name, "grey")) return .{ .ansi_16 = if (is_bg) 100 else 90 };
            },
            'y' => {
                if (std.ascii.eqlIgnoreCase(name, "yellow")) return .{ .ansi_16 = if (is_bg) 43 else 33 };
            },
            'm' => {
                if (std.ascii.eqlIgnoreCase(name, "magenta")) return .{ .ansi_16 = if (is_bg) 45 else 35 };
            },
            'p' => {
                if (std.ascii.eqlIgnoreCase(name, "purple")) return .{ .ansi_16 = if (is_bg) 45 else 35 };
            },
            'c' => {
                if (std.ascii.eqlIgnoreCase(name, "cyan")) return .{ .ansi_16 = if (is_bg) 46 else 36 };
            },
            'w' => {
                if (std.ascii.eqlIgnoreCase(name, "white")) return .{ .ansi_16 = if (is_bg) 47 else 37 };
            },
            else => {},
        }

        return null;
    }

    /// Note: used exclusively for unit tests. In runtime, toAnsiBuf is used instead.
    pub fn toAnsi(self: Style, allocator: std.mem.Allocator) ![]const u8 {
        if (self.is_none) return try allocator.dupe(u8, "");

        var buf: [128]u8 = undefined;
        const slice = self.toAnsiBuf(&buf) orelse return try allocator.dupe(u8, "");
        return try allocator.dupe(u8, slice);
    }

    pub fn toAnsiBuf(self: Style, buf: []u8) ?[]const u8 {
        if (self.is_none) return buf[0..0];

        const has_any = self.modifiers.reset or self.modifiers.bold or self.modifiers.dimmed or
            self.modifiers.italic or self.modifiers.underline or self.modifiers.blink or
            self.modifiers.inverted or self.modifiers.hidden or self.modifiers.strikethrough or
            self.fg != .none or self.bg != .none;

        if (!has_any) return buf[0..0];

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

        switch (self.fg) {
            .none => {},
            .ansi_16 => |code| {
                if (has_prev) {
                    if (pos >= buf.len) return null;
                    buf[pos] = ';';
                    pos += 1;
                }
                const formatted = std.fmt.bufPrint(buf[pos..], "{d}", .{code}) catch return null;
                pos += formatted.len;
                has_prev = true;
            },
            .ansi_256 => |code| {
                if (has_prev) {
                    if (pos >= buf.len) return null;
                    buf[pos] = ';';
                    pos += 1;
                }
                const formatted = std.fmt.bufPrint(buf[pos..], "38;5;{d}", .{code}) catch return null;
                pos += formatted.len;
                has_prev = true;
            },
            .rgb => |rgb| {
                if (has_prev) {
                    if (pos >= buf.len) return null;
                    buf[pos] = ';';
                    pos += 1;
                }
                const formatted = std.fmt.bufPrint(buf[pos..], "38;2;{d};{d};{d}", .{ rgb.r, rgb.g, rgb.b }) catch return null;
                pos += formatted.len;
                has_prev = true;
            },
        }

        switch (self.bg) {
            .none => {},
            .ansi_16 => |code| {
                if (has_prev) {
                    if (pos >= buf.len) return null;
                    buf[pos] = ';';
                    pos += 1;
                }
                const formatted = std.fmt.bufPrint(buf[pos..], "{d}", .{code}) catch return null;
                pos += formatted.len;
                has_prev = true;
            },
            .ansi_256 => |code| {
                if (has_prev) {
                    if (pos >= buf.len) return null;
                    buf[pos] = ';';
                    pos += 1;
                }
                const formatted = std.fmt.bufPrint(buf[pos..], "48;5;{d}", .{code}) catch return null;
                pos += formatted.len;
                has_prev = true;
            },
            .rgb => |rgb| {
                if (has_prev) {
                    if (pos >= buf.len) return null;
                    buf[pos] = ';';
                    pos += 1;
                }
                const formatted = std.fmt.bufPrint(buf[pos..], "48;2;{d};{d};{d}", .{ rgb.r, rgb.g, rgb.b }) catch return null;
                pos += formatted.len;
                has_prev = true;
            },
        }

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



