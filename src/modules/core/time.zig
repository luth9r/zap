const std = @import("std");
const formatter = @import("../../engine/formatter.zig");
const platform = @import("../../utils/platform.zig");

pub const PromptContext = @import("../../engine/context.zig").PromptContext;
pub const DebugContext = @import("../../engine/context.zig").DebugContext;

pub const Var = enum { time };

pub const TimeConfig = struct {
    format: []const u8 = "at [$time]($style) ",
    style: []const u8 = "bold yellow",
    // Time format string (supports %T, %R, %H, %I, %M, %S, %p, %%).
    time_format: []const u8 = "%T",
    // Whether to use 12-hour clock when expanding %T or %R.
    use_12hr: bool = false,
    disabled: bool = false,
};

pub const Config = TimeConfig;

fn writeTwoDigits(buf: []u8, pos: *usize, val: u8) bool {
    if (pos.* + 2 > buf.len) return false;
    buf[pos.*] = '0' + (val / 10);
    buf[pos.* + 1] = '0' + (val % 10);
    pos.* += 2;
    return true;
}

fn writeSlice(buf: []u8, pos: *usize, s: []const u8) bool {
    if (pos.* + s.len > buf.len) return false;
    @memcpy(buf[pos.* .. pos.* + s.len], s);
    pos.* += s.len;
    return true;
}

/// Formats a LocalTime according to `time_format` into `buf`.
pub fn formatTimeBuf(
    buf: []u8,
    lt: platform.LocalTime,
    time_format: []const u8,
    use_12hr: bool,
) ?[]const u8 {
    var pos: usize = 0;
    const h12: u8 = blk: {
        const mod = lt.hour % 12;
        break :blk if (mod == 0) 12 else mod;
    };
    const ampm: []const u8 = if (lt.hour < 12) "AM" else "PM";

    var i: usize = 0;
    while (i < time_format.len) : (i += 1) {
        if (time_format[i] == '%' and i + 1 < time_format.len) {
            i += 1;
            switch (time_format[i]) {
                'H' => if (!writeTwoDigits(buf, &pos, lt.hour)) return null,
                'I' => if (!writeTwoDigits(buf, &pos, h12)) return null,
                'M' => if (!writeTwoDigits(buf, &pos, lt.minute)) return null,
                'S' => if (!writeTwoDigits(buf, &pos, lt.second)) return null,
                'p' => if (!writeSlice(buf, &pos, ampm)) return null,
                'T' => {
                    const h = if (use_12hr) h12 else lt.hour;
                    if (!writeTwoDigits(buf, &pos, h)) return null;
                    if (!writeSlice(buf, &pos, ":")) return null;
                    if (!writeTwoDigits(buf, &pos, lt.minute)) return null;
                    if (!writeSlice(buf, &pos, ":")) return null;
                    if (!writeTwoDigits(buf, &pos, lt.second)) return null;
                    if (use_12hr) {
                        if (!writeSlice(buf, &pos, " ")) return null;
                        if (!writeSlice(buf, &pos, ampm)) return null;
                    }
                },
                'R' => {
                    const h = if (use_12hr) h12 else lt.hour;
                    if (!writeTwoDigits(buf, &pos, h)) return null;
                    if (!writeSlice(buf, &pos, ":")) return null;
                    if (!writeTwoDigits(buf, &pos, lt.minute)) return null;
                    if (use_12hr) {
                        if (!writeSlice(buf, &pos, " ")) return null;
                        if (!writeSlice(buf, &pos, ampm)) return null;
                    }
                },
                '%' => if (!writeSlice(buf, &pos, "%")) return null,
                else => |c| {
                    if (!writeSlice(buf, &pos, &.{ '%', c })) return null;
                },
            }
        } else {
            if (!writeSlice(buf, &pos, &.{time_format[i]})) return null;
        }
    }
    return buf[0..pos];
}

/// Renders the time module according to configuration.
pub fn render(
    writer: anytype,
    config: TimeConfig,
    ctx: PromptContext,
) !void {
    if (config.disabled) return;

    const lt = if (ctx.io) |io|
        platform.getLocalTime(io)
    else
        platform.LocalTime{ .hour = 0, .minute = 0, .second = 0 };

    var time_buf: [64]u8 = undefined;
    const time_str = formatTimeBuf(&time_buf, lt, config.time_format, config.use_12hr) orelse return;

    try formatter.formatTemplateWriter(writer, config.format, formatter.FormatContext(Var){
        .style = config.style,
        .shell = ctx.shell,
        .vars = &.{
            .{ .name = .time, .value = time_str },
        },
    });
}

pub fn debug(writer: anytype, dctx: DebugContext) !void {
    const lt = if (dctx.prompt.io) |io|
        platform.getLocalTime(io)
    else
        platform.LocalTime{ .hour = 0, .minute = 0, .second = 0 };

    var buf: [64]u8 = undefined;
    const formatted = formatTimeBuf(&buf, lt, "%T", false) orelse "00:00:00";

    if (dctx.json) {
        try writer.print(
            \\{{ "module": "time", "hour": {d}, "minute": {d}, "second": {d}, "formatted": "{s}" }}
            \\
        , .{ lt.hour, lt.minute, lt.second, formatted });
    } else {
        try writer.print(
            \\⚡ Module: time
            \\  Local Time: {s}
            \\
        , .{formatted});
    }
}

const testing = std.testing;
const BufferWriter = @import("../../utils/buffer_writer.zig").BufferWriter;
const Harness = @import("../../tests/harness.zig").Harness;

test "unit: formatTimeBuf 24hr and 12hr formats" {
    var buf: [64]u8 = undefined;
    const morning: platform.LocalTime = .{ .hour = 9, .minute = 5, .second = 3 };
    const midnight: platform.LocalTime = .{ .hour = 0, .minute = 0, .second = 0 };
    const afternoon: platform.LocalTime = .{ .hour = 15, .minute = 30, .second = 45 };

    try testing.expectEqualStrings("09:05:03", formatTimeBuf(&buf, morning, "%T", false).?);
    try testing.expectEqualStrings("09:05", formatTimeBuf(&buf, morning, "%R", false).?);
    try testing.expectEqualStrings("09:05:03 AM", formatTimeBuf(&buf, morning, "%T", true).?);
    try testing.expectEqualStrings("12:00:00 AM", formatTimeBuf(&buf, midnight, "%T", true).?);
    try testing.expectEqualStrings("03:30:45 PM", formatTimeBuf(&buf, afternoon, "%T", true).?);
    try testing.expectEqualStrings("15:30 [PM] %", formatTimeBuf(&buf, afternoon, "%H:%M [%p] %%", false).?);
}

test "unit: time render respects disabled flag" {
    var buf: [128]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    try render(writer, .{ .disabled = true }, .{ .cwd = "", .home = "" });
    try testing.expectEqual(@as(usize, 0), pos);

    try render(writer, .{ .format = "[$time]", .time_format = "%H:%M" }, .{ .cwd = "", .home = "", .shell = .generic });
    try testing.expectEqualStrings("[00:00]", buf[0..pos]);
}

test "integration: time module renders in prompt and right_format" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.setConfig(
        \\format = "$time"
        \\add_newline = false
        \\
        \\[time]
        \\format = "[$time]($style)"
        \\time_format = "%H:%M"
    );

    const out = try h.collect(.generic);
    try Harness.expectNotEmpty(out);
    try Harness.expectContains(out, ":");
}
