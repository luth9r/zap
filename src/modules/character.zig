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
    config: CharacterConfig,
    ctx: PromptContext,
) !void {
    if (config.disabled) return;

    const is_error = ctx.status_code != 0;
    const symbol_template = if (is_error) config.error_symbol else config.success_symbol;

    var symbol_buf: [256]u8 = undefined;
    var symbol_pos: usize = 0;

    const sym_writer = BufferWriter.init(&symbol_buf, &symbol_pos);
    try formatter.formatTemplateWriter(sym_writer, symbol_template, .{ .shell = ctx.shell });

    const rendered_symbol = symbol_buf[0..symbol_pos];

    try formatter.formatTemplateWriter(writer, config.format, .{
        .shell = ctx.shell,
        .vars = &[_]formatter.Variable{
            .{ .name = "symbol", .value = rendered_symbol },
        },
    });
}

test "render character success exit code" {
    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    const cfg = CharacterConfig{};
    try render(writer, cfg, .{ .cwd = ".", .home = ".", .status_code = 0 });

    const expected = "\x1b[1;32m❯\x1b[0m ";
    try std.testing.expectEqualStrings(expected, buf[0..pos]);
}

test "render character error exit code" {
    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    const cfg = CharacterConfig{};
    try render(writer, cfg, .{ .cwd = ".", .home = ".", .status_code = 1 });

    const expected = "\x1b[1;31m❯\x1b[0m ";
    try std.testing.expectEqualStrings(expected, buf[0..pos]);
}

test "render character disabled" {
    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    var cfg = CharacterConfig{};
    cfg.disabled = true;
    try render(writer, cfg, .{ .cwd = ".", .home = ".", .status_code = 0 });

    try std.testing.expectEqual(@as(usize, 0), pos);
}

test "render character custom symbols" {
    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    var cfg = CharacterConfig{};
    cfg.success_symbol = "[➜](bold green)";
    cfg.error_symbol = "[✗](bold red)";

    try render(writer, cfg, .{ .cwd = ".", .home = ".", .status_code = 0 });
    try std.testing.expectEqualStrings("\x1b[1;32m➜\x1b[0m ", buf[0..pos]);

    pos = 0;
    try render(writer, cfg, .{ .cwd = ".", .home = ".", .status_code = 130 });
    try std.testing.expectEqualStrings("\x1b[1;31m✗\x1b[0m ", buf[0..pos]);
}

test "render character across all shells" {
    const Shell = @import("../init/root.zig").Shell;
    const assertValidShellAnsi = @import("../tests/fixture.zig").Fixture.assertValidShellAnsi;

    var buf: [256]u8 = undefined;
    const cfg = CharacterConfig{};
    const shells = [_]Shell{ .bash, .zsh, .fish, .powershell };

    for (shells) |sh| {
        var pos: usize = 0;
        const writer = BufferWriter.init(&buf, &pos);
        try render(writer, cfg, .{
            .cwd = ".",
            .home = ".",
            .status_code = 1,
            .shell = sh,
        });
        const out = buf[0..pos];
        try assertValidShellAnsi(out, sh);
    }

    // Exact string verification for Bash
    var pos_bash: usize = 0;
    try render(BufferWriter.init(&buf, &pos_bash), cfg, .{ .cwd = ".", .home = ".", .status_code = 0, .shell = .bash });
    try std.testing.expectEqualStrings("\x01\x1b[1;32m\x02❯\x01\x1b[0m\x02 ", buf[0..pos_bash]);

    // Exact string verification for Zsh
    var pos_zsh: usize = 0;
    try render(BufferWriter.init(&buf, &pos_zsh), cfg, .{ .cwd = ".", .home = ".", .status_code = 0, .shell = .zsh });
    try std.testing.expectEqualStrings("%{\x1b[1;32m%}❯%{\x1b[0m%} ", buf[0..pos_zsh]);
}

