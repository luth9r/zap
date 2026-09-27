const std = @import("std");
const Config = @import("../config/config.zig").Config;
const formatter = @import("../engine/formatter.zig");
const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;

/// Renders the prompt character module based on exit status code.
pub fn render(
    writer: anytype,
    config: Config,
    status_code: u8,
) !void {
    if (config.character.disabled) return;

    const is_error = status_code != 0;
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
