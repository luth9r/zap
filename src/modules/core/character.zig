const std = @import("std");
const formatter = @import("../../engine/formatter.zig");
const BufferWriter = @import("../../utils/buffer_writer.zig").BufferWriter;

pub const PromptContext = @import("../../engine/context.zig").PromptContext;

pub const Var = enum { symbol };

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

pub const Config = CharacterConfig;

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
    try formatter.formatTemplateWriter(sym_writer, symbol_template, formatter.EmptyContext{ .shell = ctx.shell });

    const rendered_symbol = symbol_buf[0..symbol_pos];

    try formatter.formatTemplateWriter(writer, config.format, formatter.FormatContext(Var){
        .shell = ctx.shell,
        .vars = &.{
            .{ .name = .symbol, .value = rendered_symbol },
        },
    });
}

pub const Harness = @import("../../tests/harness.zig").Harness;

test "integration: character default success exit code" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    _ = h.setStatus(0);
    try h.setConfig(
        \\format = "$character"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "❯");
}

test "integration: character error exit code with custom symbol" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    _ = h.setStatus(1);
    try h.setConfig(
        \\format = "$character"
        \\add_newline = false
        \\
        \\[character]
        \\error_symbol = "[✗](bold red)"
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "✗");
}

test "integration: character custom success symbol" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    _ = h.setStatus(0);
    try h.setConfig(
        \\format = "$character"
        \\add_newline = false
        \\
        \\[character]
        \\success_symbol = "[➜](bold green)"
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "➜");
}

test "integration: character disabled in config" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    _ = h.setStatus(0);
    try h.setConfig(
        \\format = "$character"
        \\add_newline = false
        \\
        \\[character]
        \\disabled = true
    );

    const out = try h.collect(.generic);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

