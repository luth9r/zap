const std = @import("std");

pub const Color = enum {
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    purple,
    cyan,
    white,

    bright_black,
    gray,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,

    pub fn toAnsi(self: Color, is_bold: bool) []const u8 {
        if (is_bold) {
            return switch (self) {
                .black => "\x1b[1;30m",
                .red => "\x1b[1;31m",
                .green => "\x1b[1;32m",
                .yellow => "\x1b[1;33m",
                .blue => "\x1b[1;34m",
                .magenta, .purple => "\x1b[1;35m",
                .cyan => "\x1b[1;36m",
                .white => "\x1b[1;37m",

                .bright_black, .gray => "\x1b[1;90m",
                .bright_red => "\x1b[1;91m",
                .bright_green => "\x1b[1;92m",
                .bright_yellow => "\x1b[1;93m",
                .bright_blue => "\x1b[1;94m",
                .bright_magenta => "\x1b[1;95m",
                .bright_cyan => "\x1b[1;96m",
                .bright_white => "\x1b[1;97m",
            };
        }

        return switch (self) {
            .black => "\x1b[30m",
            .red => "\x1b[31m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .blue => "\x1b[34m",
            .magenta, .purple => "\x1b[35m",
            .cyan => "\x1b[36m",
            .white => "\x1b[37m",

            .bright_black, .gray => "\x1b[90m",
            .bright_red => "\x1b[91m",
            .bright_green => "\x1b[92m",
            .bright_yellow => "\x1b[93m",
            .bright_blue => "\x1b[94m",
            .bright_magenta => "\x1b[95m",
            .bright_cyan => "\x1b[96m",
            .bright_white => "\x1b[97m",
        };
    }
};

pub fn parseColor(raw_name: []const u8, fallback: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw_name, " \t");

    var is_bold = false;
    var name = trimmed;

    if (std.mem.startsWith(u8, trimmed, "bold ")) {
        is_bold = true;
        name = std.mem.trim(u8, trimmed[5..], " \t");
    }

    if (std.meta.stringToEnum(Color, name)) |c| {
        return c.toAnsi(is_bold);
    }

    return fallback;
}

test "parse standard and bold colors correctly" {
    try std.testing.expectEqualStrings("\x1b[32m", parseColor("green", ""));
    try std.testing.expectEqualStrings("\x1b[31m", parseColor("red", ""));
    try std.testing.expectEqualStrings("\x1b[36m", parseColor("cyan", ""));
    try std.testing.expectEqualStrings("\x1b[90m", parseColor("gray", ""));

    try std.testing.expectEqualStrings("\x1b[1;32m", parseColor("bold green", ""));
    try std.testing.expectEqualStrings("\x1b[1;31m", parseColor("bold red", ""));
    try std.testing.expectEqualStrings("\x1b[1;36m", parseColor("bold cyan", ""));
    try std.testing.expectEqualStrings("\x1b[1;90m", parseColor("bold gray", ""));

    try std.testing.expectEqualStrings("default", parseColor("unknown", "default"));
}
