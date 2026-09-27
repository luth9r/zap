const std = @import("std");
const Config = @import("../config/config.zig").Config;
const formatter = @import("../engine/formatter.zig");
const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;

pub const PromptContext = @import("../engine/context.zig").PromptContext;

pub const CharacterConfig = struct {
    // Format string used to render the character module.
    format: []const u8 = "$symbol ",
    // Symbol rendered on exit code 0 (can contain styled blocks like [➜](bold green)).
    success_symbol: []const u8 = "[❯](bold green)",
    // Symbol rendered on non-zero exit code.
    error_symbol: []const u8 = "[❯](bold red)",
    // Whether the character module is disabled.
    disabled: bool = false,
};

/// Renders the prompt character module based on exit status code.
pub fn render(
    writer: anytype,
    config: Config,
    ctx: PromptContext,
) !void {
    if (config.character.disabled) return;

    const is_error = ctx.status_code != 0;
    const symbol_template = if (is_error) config.character.error_symbol else config.character.success_symbol;

    var symbol_buf: [256]u8 = undefined;
    var symbol_pos: usize = 0;

    const sym_writer = BufferWriter.init(&symbol_buf, &symbol_pos);
    try formatter.formatTemplateWriter(sym_writer, symbol_template, .{});

    const rendered_symbol = symbol_buf[0..symbol_pos];

    try formatter.formatTemplateWriter(writer, config.character.format, .{
        .vars = &[_]formatter.Variable{
            .{ .name = "symbol", .value = rendered_symbol },
        },
    });
}

test "render character success exit code" {
    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    const cfg = Config{};
    try render(writer, cfg, .{ .cwd = ".", .home = ".", .status_code = 0 });

    const expected = "\x1b[1;32m❯\x1b[0m ";
    try std.testing.expectEqualStrings(expected, buf[0..pos]);
}

test "render character error exit code" {
    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    const cfg = Config{};
    try render(writer, cfg, .{ .cwd = ".", .home = ".", .status_code = 1 });

    const expected = "\x1b[1;31m❯\x1b[0m ";
    try std.testing.expectEqualStrings(expected, buf[0..pos]);
}

test "render character disabled" {
    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    var cfg = Config{};
    cfg.character.disabled = true;
    try render(writer, cfg, .{ .cwd = ".", .home = ".", .status_code = 0 });

    try std.testing.expectEqual(@as(usize, 0), pos);
}

test "render character custom symbols" {
    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    var cfg = Config{};
    cfg.character.success_symbol = "[➜](bold green)";
    cfg.character.error_symbol = "[✗](bold red)";

    try render(writer, cfg, .{ .cwd = ".", .home = ".", .status_code = 0 });
    try std.testing.expectEqualStrings("\x1b[1;32m➜\x1b[0m ", buf[0..pos]);

    pos = 0;
    try render(writer, cfg, .{ .cwd = ".", .home = ".", .status_code = 130 });
    try std.testing.expectEqualStrings("\x1b[1;31m✗\x1b[0m ", buf[0..pos]);
}
