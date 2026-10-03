const std = @import("std");

/// Checks if a file exists at the given path using fast access check.
pub fn fileExists(io: std.Io, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        if (std.Io.Dir.accessAbsolute(io, path, .{})) |_| return true else |_| return false;
    } else {
        if (std.Io.Dir.cwd().access(io, path, .{})) |_| return true else |_| return false;
    }
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

/// Checks if any file with the specified extensions exists in the given directory.
pub fn hasFileWithExtension(
    io: std.Io,
    dir_path: []const u8,
    comptime extensions: []const []const u8,
) bool {
    if (extensions.len == 0) return false;
    var dir = if (std.fs.path.isAbsolute(dir_path))
        std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch null
    else
        std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch null;
    if (dir) |*d| {
        defer d.close(io);
        var iter = d.iterate();
        while (iter.next(io) catch null) |entry| {
            inline for (extensions) |ext| {
                if (std.mem.endsWith(u8, entry.name, ext)) {
                    return true;
                }
            }
        }
    }
    return false;
}

/// Traverses parent directories upwards starting from start_dir up to repo_root, home_dir, or max_depth,
/// checking if any candidate manifest files exist.
pub fn scanParentDirsForFiles(
    io: std.Io,
    start_dir: []const u8,
    home_dir: []const u8,
    repo_root: ?[]const u8,
    comptime files: []const []const u8,
    max_depth: usize,
) bool {
    if (files.len == 0 or max_depth == 0) return false;

    var curr_dir = std.fs.path.dirname(start_dir);
    var depth: usize = 0;
    while (curr_dir) |p| : (depth += 1) {
        if (depth >= max_depth) break;

        if (anySubpathExists(io, p, files)) {
            return true;
        }

        if (repo_root) |root| {
            if (std.mem.eql(u8, p, root) or !std.mem.startsWith(u8, p, root)) break;
        }
        if (std.mem.eql(u8, p, home_dir) or std.mem.eql(u8, p, "/") or p.len == 0) break;

        curr_dir = std.fs.path.dirname(p);
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

/// Reads the trailing bytes (tail) of a file up to buf.len.
pub fn readTailFile(io: std.Io, path: []const u8, buf: []u8) ?[]const u8 {
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    const st = file.stat(io) catch return null;
    if (st.size == 0) return null;
    const to_read: usize = @intCast(@min(st.size, buf.len));
    const offset: u64 = st.size - to_read;
    var stream_buf: [256]u8 = undefined;
    var reader = file.reader(io, &stream_buf);
    reader.seekTo(offset) catch return null;
    const n = reader.interface.readSliceShort(buf[0..to_read]) catch return null;
    if (n == 0) return null;
    return buf[0..n];
}

pub const MatchDetail = struct {
    matched: bool = false,
    matched_file: [256]u8 = undefined,
    matched_file_len: usize = 0,
    matched_path: [std.fs.max_path_bytes]u8 = undefined,
    matched_path_len: usize = 0,
    depth: usize = 0,

    pub fn getMatchedFile(self: *const MatchDetail) []const u8 {
        return self.matched_file[0..self.matched_file_len];
    }

    pub fn getMatchedPath(self: *const MatchDetail) []const u8 {
        return self.matched_path[0..self.matched_path_len];
    }
};

pub fn detectDetailed(
    io: std.Io,
    cwd: []const u8,
    home: []const u8,
    repo_root: ?[]const u8,
    comptime files: []const []const u8,
    comptime extensions: []const []const u8,
    max_depth: usize,
) MatchDetail {
    var res = MatchDetail{};

    // 1. Check files in cwd
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    inline for (files) |sub| {
        if (std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ cwd, sub })) |p| {
            if (fileExists(io, p)) {
                res.matched = true;
                const flen = @min(sub.len, res.matched_file.len);
                @memcpy(res.matched_file[0..flen], sub[0..flen]);
                res.matched_file_len = flen;
                const plen = @min(p.len, res.matched_path.len);
                @memcpy(res.matched_path[0..plen], p[0..plen]);
                res.matched_path_len = plen;
                res.depth = 0;
                return res;
            }
        } else |_| {}
    }

    // 2. Check extensions in cwd
    if (extensions.len > 0) {
        var dir = if (std.fs.path.isAbsolute(cwd))
            std.Io.Dir.openDirAbsolute(io, cwd, .{ .iterate = true }) catch null
        else
            std.Io.Dir.cwd().openDir(io, cwd, .{ .iterate = true }) catch null;
        if (dir) |*d| {
            defer d.close(io);
            var iter = d.iterate();
            while (iter.next(io) catch null) |entry| {
                inline for (extensions) |ext| {
                    if (std.mem.endsWith(u8, entry.name, ext)) {
                        res.matched = true;
                        const flen = @min(entry.name.len, res.matched_file.len);
                        @memcpy(res.matched_file[0..flen], entry.name[0..flen]);
                        res.matched_file_len = flen;
                        if (std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ cwd, entry.name })) |p| {
                            const plen = @min(p.len, res.matched_path.len);
                            @memcpy(res.matched_path[0..plen], p[0..plen]);
                            res.matched_path_len = plen;
                        } else |_| {}
                        res.depth = 0;
                        return res;
                    }
                }
            }
        }
    }

    // 3. Upward parent directories
    if (files.len > 0 and max_depth > 0) {
        var curr_dir = std.fs.path.dirname(cwd);
        var depth: usize = 1;
        while (curr_dir) |p| : (depth += 1) {
            if (depth > max_depth) break;

            inline for (files) |sub| {
                if (std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ p, sub })) |full_p| {
                    if (fileExists(io, full_p)) {
                        res.matched = true;
                        const flen = @min(sub.len, res.matched_file.len);
                        @memcpy(res.matched_file[0..flen], sub[0..flen]);
                        res.matched_file_len = flen;
                        const plen = @min(full_p.len, res.matched_path.len);
                        @memcpy(res.matched_path[0..plen], full_p[0..plen]);
                        res.matched_path_len = plen;
                        res.depth = depth;
                        return res;
                    }
                } else |_| {}
            }

            if (repo_root) |root| {
                if (std.mem.eql(u8, p, root) or !std.mem.startsWith(u8, p, root)) break;
            }
            if (std.mem.eql(u8, p, home) or std.mem.eql(u8, p, "/") or p.len == 0) break;

            curr_dir = std.fs.path.dirname(p);
        }
    }

    return res;
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

test "unit: fs.anySubpathExists on non-existent path returns false" {
    const io = std.testing.io;
    try std.testing.expect(!anySubpathExists(io, "/nonexistent_folder_xyz_123", &.{"file.txt"}));
}
