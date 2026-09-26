const std = @import("std");
const testing = std.testing;
const PathConfig = @import("config.zig").PathConfig;

pub fn formatPath(allocator: std.mem.Allocator, cwd: []const u8, home: []const u8, config: PathConfig) ![]const u8 {
    if (home.len == 0 or !std.mem.startsWith(u8, cwd, home)) {
        return try allocator.dupe(u8, cwd);
    }

    if (cwd.len == home.len) {
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ config.home_color, config.home_symbol });
    }

    if (cwd[home.len] == '/') {
        return try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ config.home_color, config.home_symbol, cwd[home.len..] });
    }

    return try allocator.dupe(u8, cwd);
}

test "replaces HOME prefix with default tilde and color" {
    const allocator = testing.allocator;
    const home = "/home/user";
    const cwd = "/home/user/projects/zap";

    const result = try formatPath(allocator, cwd, home, .{});
    defer allocator.free(result);

    try testing.expectEqualStrings("\x1b[36m~/projects/zap", result);
}

test "replaces HOME prefix with custom configured symbol and color" {
    const allocator = testing.allocator;
    const home = "/home/user";
    const cwd = "/home/user/projects/zap";

    const custom_config = PathConfig{ .home_symbol = "?>", .home_color = "\x1b[32m" };
    const result = try formatPath(allocator, cwd, home, custom_config);
    defer allocator.free(result);

    try testing.expectEqualStrings("\x1b[32m?>/projects/zap", result);
}

test "handles exact HOME match with custom symbol and color" {
    const allocator = testing.allocator;
    const home = "/home/user";
    const cwd = "/home/user";

    const custom_config = PathConfig{ .home_symbol = "?>", .home_color = "\x1b[32m" };
    const result = try formatPath(allocator, cwd, home, custom_config);
    defer allocator.free(result);

    try testing.expectEqualStrings("\x1b[32m?>", result);
}
