const std = @import("std");
const Config = @import("../config/config.zig").Config;
const formatter = @import("../engine/formatter.zig");
const path_utils = @import("../utils/path_utils.zig");

/// Renders the directory module according to the directory configuration.
pub fn render(
    writer: anytype,
    config: Config,
    cwd: []const u8,
    home: []const u8,
) !void {
    if (config.directory.disabled) return;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_str = path_utils.formatPathBuf(&path_buf, cwd, home, config.directory.home_symbol) orelse cwd;

    try formatter.formatTemplateWriter(writer, config.directory.format, .{
        .style = config.directory.style,
        .vars = &[_]formatter.Variable{
            .{ .name = "path", .value = path_str },
            .{ .name = "read_only", .value = "" },
            .{ .name = "read_only_style", .value = config.directory.read_only_style },
        },
    });
}
