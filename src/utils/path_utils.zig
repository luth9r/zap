const std = @import("std");
const testing = std.testing;
const BufferWriter = @import("buffer_writer.zig").BufferWriter;

pub fn writePath(
    writer: anytype,
    cwd: []const u8,
    home: []const u8,
    home_symbol: []const u8,
) !void {
    if (home.len > 0 and std.mem.startsWith(u8, cwd, home)) {
        if (cwd.len == home.len) {
            try writer.writeAll(home_symbol);
            return;
        }
        if (cwd[home.len] == '/') {
            try writer.writeAll(home_symbol);
            try writer.writeAll(cwd[home.len..]);
            return;
        }
    }
    try writer.writeAll(cwd);
}

pub fn formatPathBuf(
    buf: []u8,
    cwd: []const u8,
    home: []const u8,
    home_symbol: []const u8,
) ?[]const u8 {
    var pos: usize = 0;
    const writer = BufferWriter.init(buf, &pos);
    writePath(writer, cwd, home, home_symbol) catch return null;
    return buf[0..pos];
}

test "replaces HOME prefix with default tilde" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = "/home/user";
    const cwd = "/home/user/projects/zap";

    const result = formatPathBuf(&buf, cwd, home, "~").?;
    try testing.expectEqualStrings("~/projects/zap", result);
}

test "replaces HOME prefix with custom configured symbol" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = "/home/user";
    const cwd = "/home/user/projects/zap";

    const result = formatPathBuf(&buf, cwd, home, "?>").?;
    try testing.expectEqualStrings("?>/projects/zap", result);
}

test "handles exact HOME match with custom symbol" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = "/home/user";
    const cwd = "/home/user";

    const result = formatPathBuf(&buf, cwd, home, "?>").?;
    try testing.expectEqualStrings("?>", result);
}
