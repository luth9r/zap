const std = @import("std");
const PromptCharConfig = @import("config.zig").PromptCharConfig;

pub const PromptCharResult = struct {
    symbol: []const u8,
    color: []const u8,
};

pub fn renderPromptChar(status_code: u8, config: PromptCharConfig) PromptCharResult {
    if (status_code == 0) {
        return .{
            .symbol = config.success_symbol,
            .color = config.success_color,
        };
    }

    return .{
        .symbol = config.error_symbol,
        .color = config.error_color,
    };
}

test "status code 0 renders success symbol and color" {
    const config = PromptCharConfig{};
    const res = renderPromptChar(0, config);

    try std.testing.expectEqualStrings(config.success_symbol, res.symbol);
    try std.testing.expectEqualStrings(config.success_color, res.color);
}

test "non-zero status code renders error symbol and color" {
    const config = PromptCharConfig{};
    const res_1 = renderPromptChar(1, config);
    const res_127 = renderPromptChar(127, config);

    try std.testing.expectEqualStrings(config.error_symbol, res_1.symbol);
    try std.testing.expectEqualStrings(config.error_color, res_1.color);

    try std.testing.expectEqualStrings(config.error_symbol, res_127.symbol);
    try std.testing.expectEqualStrings(config.error_color, res_127.color);
}
