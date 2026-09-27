const std = @import("std");
const Config = @import("../config/config.zig").Config;
const formatter = @import("../engine/formatter.zig");

pub const PromptContext = @import("../engine/context.zig").PromptContext;

pub const CmdDurationConfig = struct {
    // Minimum execution duration in milliseconds to trigger rendering.
    min_time: u64 = 2000,
    // Format template for the cmd_duration module.
    format: []const u8 = "took [$duration]($style) ",
    // Style string for the duration text.
    style: []const u8 = "bold yellow",
    // Whether to display milliseconds when duration is under one minute.
    show_milliseconds: bool = false,
    // Whether the cmd_duration module is disabled.
    disabled: bool = false,
};

/// Formats duration in milliseconds into a compact human-readable string buffer.
pub fn formatDurationBuf(buf: []u8, duration_ms: u64, show_milliseconds: bool) ?[]const u8 {
    const ms_per_s: u64 = 1000;
    const ms_per_m: u64 = 60 * ms_per_s;

    const d = duration_ms / (24 * 60 * 60 * 1000);
    var rem = duration_ms % (24 * 60 * 60 * 1000);

    const h = rem / (60 * 60 * 1000);
    rem = rem % (60 * 60 * 1000);

    const m = rem / ms_per_m;
    rem = rem % ms_per_m;

    const s = rem / ms_per_s;
    const ms = rem % ms_per_s;

    if (d > 0) {
        if (s > 0) {
            return std.fmt.bufPrint(buf, "{d}d {d}h {d}m {d}s", .{ d, h, m, s }) catch null;
        } else {
            return std.fmt.bufPrint(buf, "{d}d {d}h {d}m", .{ d, h, m }) catch null;
        }
    } else if (h > 0) {
        if (s > 0) {
            return std.fmt.bufPrint(buf, "{d}h {d}m {d}s", .{ h, m, s }) catch null;
        } else {
            return std.fmt.bufPrint(buf, "{d}h {d}m", .{ h, m }) catch null;
        }
    } else if (m > 0) {
        if (s > 0) {
            return std.fmt.bufPrint(buf, "{d}m {d}s", .{ m, s }) catch null;
        } else {
            return std.fmt.bufPrint(buf, "{d}m", .{ m }) catch null;
        }
    } else if (s > 0) {
        if (show_milliseconds and ms > 0) {
            return std.fmt.bufPrint(buf, "{d}s {d}ms", .{ s, ms }) catch null;
        } else {
            return std.fmt.bufPrint(buf, "{d}s", .{s}) catch null;
        }
    } else {
        return std.fmt.bufPrint(buf, "{d}ms", .{ms}) catch null;
    }
}

/// Renders the cmd_duration module according to configuration.
pub fn render(
    writer: anytype,
    config: Config,
    ctx: PromptContext,
) !void {
    if (config.cmd_duration.disabled) return;
    if (ctx.cmd_duration < config.cmd_duration.min_time) return;

    var dur_buf: [64]u8 = undefined;
    const dur_str = formatDurationBuf(&dur_buf, ctx.cmd_duration, config.cmd_duration.show_milliseconds) orelse return;

    try formatter.formatTemplateWriter(writer, config.cmd_duration.format, .{
        .style = config.cmd_duration.style,
        .vars = &[_]formatter.Variable{
            .{ .name = "duration", .value = dur_str },
        },
    });
}

test "formatDurationBuf various ranges" {
    var buf: [64]u8 = undefined;

    // Subsecond
    try std.testing.expectEqualStrings("500ms", formatDurationBuf(&buf, 500, false).?);
    try std.testing.expectEqualStrings("500ms", formatDurationBuf(&buf, 500, true).?);

    // Exact seconds
    try std.testing.expectEqualStrings("2s", formatDurationBuf(&buf, 2000, false).?);
    try std.testing.expectEqualStrings("2s 450ms", formatDurationBuf(&buf, 2450, true).?);

    // Minutes and seconds
    try std.testing.expectEqualStrings("1m 5s", formatDurationBuf(&buf, 65000, false).?);
    try std.testing.expectEqualStrings("2m", formatDurationBuf(&buf, 120000, false).?);

    // Hours, minutes, seconds
    try std.testing.expectEqualStrings("1h 1m 5s", formatDurationBuf(&buf, 3665000, false).?);
    try std.testing.expectEqualStrings("2h 30m", formatDurationBuf(&buf, 9000000, false).?);

    // Days
    try std.testing.expectEqualStrings("1d 2h 3m 4s", formatDurationBuf(&buf, 93784000, false).?);
}

test "render duration respect min_time" {
    const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;

    var cfg = Config{};
    cfg.cmd_duration.min_time = 2000;

    var buf: [128]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    // Below min_time -> no output
    try render(writer, cfg, .{ .cwd = ".", .home = ".", .cmd_duration = 1999 });
    try std.testing.expectEqual(@as(usize, 0), pos);

    // At min_time -> rendered
    try render(writer, cfg, .{ .cwd = ".", .home = ".", .cmd_duration = 2000 });
    try std.testing.expectEqualStrings("took \x1b[1;33m2s\x1b[0m ", buf[0..pos]);
}

test "render duration disabled" {
    const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;

    var cfg = Config{};
    cfg.cmd_duration.min_time = 1000;
    cfg.cmd_duration.disabled = true;

    var buf: [128]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    try render(writer, cfg, .{ .cwd = ".", .home = ".", .cmd_duration = 5000 });
    try std.testing.expectEqual(@as(usize, 0), pos);
}
