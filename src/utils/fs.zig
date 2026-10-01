const std = @import("std");

/// Checks if a file exists at the given absolute path.
pub fn fileExists(io: std.Io, path: []const u8) bool {
    if (std.Io.Dir.openFileAbsolute(io, path, .{})) |f| {
        var file = f;
        file.close(io);
        return true;
    } else |_| return false;
}

/// Checks if any of the given relative subpaths exist within base_dir.
pub fn anySubpathExists(io: std.Io, base_dir: []const u8, comptime subpaths: []const []const u8) bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    inline for (subpaths) |sub| {
        if (std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ base_dir, sub })) |p| {
            if (fileExists(io, p)) return true;
        } else |_| {}
    }
    return false;
}

/// Reads a small text file into a buffer, trimming whitespace.
pub fn readSmallFile(io: std.Io, path: []const u8, buf: []u8) ?[]const u8 {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    var stream_buf: [256]u8 = undefined;
    var reader = file.reader(io, &stream_buf);
    const n = reader.interface.readSliceShort(buf) catch return null;
    if (n == 0) return null;
    return std.mem.trim(u8, buf[0..n], " \t\r\n");
}

/// Writes content to an absolute file path, creating parent directories if needed.
pub fn writeFileAbsolute(io: std.Io, path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try std.Io.Dir.cwd().createDirPath(io, parent);
    }
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}
