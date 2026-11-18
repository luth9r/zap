const std = @import("std");
const platform = @import("platform.zig");

pub const testTempSubdir = platform.testTempSubdir;

/// Checks access to an absolute or relative path.
pub fn access(io: std.Io, path: []const u8, options: std.Io.Dir.AccessOptions) !void {
    if (path.len == 0) return error.FileNotFound;
    if (std.fs.path.isAbsolute(path)) {
        try std.Io.Dir.accessAbsolute(io, path, options);
    } else {
        try std.Io.Dir.cwd().access(io, path, options);
    }
}

/// Opens an existing file at an absolute or relative path.
pub fn openFile(io: std.Io, path: []const u8, flags: std.Io.File.OpenFlags) !std.Io.File {
    if (path.len == 0) return error.FileNotFound;
    return if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(io, path, flags)
    else
        try std.Io.Dir.cwd().openFile(io, path, flags);
}

/// Creates or truncates a file at an absolute or relative path.
pub fn createFile(io: std.Io, path: []const u8, flags: std.Io.File.CreateFlags) !std.Io.File {
    if (path.len == 0) return error.FileNotFound;
    return if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.createFileAbsolute(io, path, flags)
    else
        try std.Io.Dir.cwd().createFile(io, path, flags);
}

/// Opens a directory at an absolute or relative path.
pub fn openDir(io: std.Io, path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    if (path.len == 0) return error.FileNotFound;
    return if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openDirAbsolute(io, path, options)
    else
        try std.Io.Dir.cwd().openDir(io, path, options);
}

/// Checks if a file exists at the given path using fast access check.
pub fn fileExists(io: std.Io, path: []const u8) bool {
    access(io, path, .{}) catch return false;
    return true;
}

/// Checks if a directory exists at the given path (supports both absolute and relative paths safely).
pub fn dirExists(io: std.Io, path: []const u8) bool {
    var dir = openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

/// Returns the first matching relative subpath from `subpaths` that exists in `base_dir`.
pub fn findFirstSubpath(io: std.Io, base_dir: []const u8, comptime subpaths: []const []const u8) ?[]const u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    inline for (subpaths) |sub| {
        if (std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ base_dir, sub })) |p| {
            if (fileExists(io, p)) return sub;
        } else |_| {}
    }
    return null;
}

/// Checks if any of the given relative subpaths exist within base_dir.
pub fn anySubpathExists(io: std.Io, base_dir: []const u8, comptime subpaths: []const []const u8) bool {
    return findFirstSubpath(io, base_dir, subpaths) != null;
}

/// Finds the first non-hidden file in `dir_path` matching any extension in `extensions` and copies its name into `out_buf`.
pub fn findFirstExtensionFile(
    io: std.Io,
    dir_path: []const u8,
    comptime extensions: []const []const u8,
    out_buf: []u8,
) ?[]const u8 {
    if (extensions.len == 0) return null;
    var dir = openDir(io, dir_path, .{ .iterate = true }) catch null;
    if (dir) |*d| {
        defer d.close(io);
        var iter = d.iterate();
        while (iter.next(io) catch null) |entry| {
            if (entry.kind == .directory or entry.name.len == 0 or entry.name[0] == '.') continue;
            inline for (extensions) |ext| {
                if (entry.name.len > ext.len and std.mem.endsWith(u8, entry.name, ext)) {
                    const n = @min(entry.name.len, out_buf.len);
                    @memcpy(out_buf[0..n], entry.name[0..n]);
                    return out_buf[0..n];
                }
            }
        }
    }
    return null;
}

/// Checks if any file with the specified extensions exists in the given directory.
pub fn hasFileWithExtension(
    io: std.Io,
    dir_path: []const u8,
    comptime extensions: []const []const u8,
) bool {
    var buf: [256]u8 = undefined;
    return findFirstExtensionFile(io, dir_path, extensions, &buf) != null;
}

fn isRootOrHomeBoundary(dir_path: []const u8, home_dir: []const u8) bool {
    return std.mem.eql(u8, dir_path, "/") or
        platform.pathEql(dir_path, platform.fs_root) or
        (home_dir.len > 0 and platform.pathEql(dir_path, home_dir));
}

fn reachedScanBoundary(dir_path: []const u8, home_dir: []const u8, repo_root: ?[]const u8) bool {
    if (isRootOrHomeBoundary(dir_path, home_dir)) {
        return true;
    }
    if (repo_root) |root| {
        if (platform.pathEql(dir_path, root) or !platform.pathIsSubpath(dir_path, root)) {
            return true;
        }
    }
    return false;
}

pub const ParentMatch = struct {
    dir: []const u8,
    file: []const u8,
    depth: usize,
};

/// Traverses parent directories upwards starting from `start_dir` up to `repo_root`, `home_dir`, or `max_depth`,
/// returning the first matching manifest file along with its directory and depth.
pub fn findInParentDirs(
    io: std.Io,
    start_dir: []const u8,
    home_dir: []const u8,
    repo_root: ?[]const u8,
    comptime files: []const []const u8,
    max_depth: usize,
) ?ParentMatch {
    if (files.len == 0 or max_depth == 0) return null;
    if (reachedScanBoundary(start_dir, home_dir, repo_root)) return null;

    var curr_dir = std.fs.path.dirname(start_dir);
    var depth: usize = 1;
    while (curr_dir) |p| : (depth += 1) {
        if (depth > max_depth) break;

        if (findFirstSubpath(io, p, files)) |sub| {
            return .{ .dir = p, .file = sub, .depth = depth };
        }

        if (reachedScanBoundary(p, home_dir, repo_root)) break;

        curr_dir = std.fs.path.dirname(p);
    }

    return null;
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
    return findInParentDirs(io, start_dir, home_dir, repo_root, files, max_depth) != null;
}

/// Reads a file into `buf` (up to `buf.len` bytes), supporting both absolute and relative paths.
pub fn readFileRaw(io: std.Io, path: []const u8, buf: []u8) ?[]const u8 {
    const file = openFile(io, path, .{}) catch return null;
    defer file.close(io);
    const n = platform.readStreamToBuf(io, file, buf);
    if (n == 0) return null;
    return buf[0..n];
}

/// Reads a small text file into a buffer, trimming leading and trailing whitespace.
pub fn readSmallFile(io: std.Io, path: []const u8, buf: []u8) ?[]const u8 {
    const raw = readFileRaw(io, path, buf) orelse return null;
    return std.mem.trim(u8, raw, " \t\r\n");
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
    fn setMatch(self: *MatchDetail, dir_path: []const u8, file_name: []const u8, depth: usize) void {
        self.matched = true;
        const flen = @min(file_name.len, self.matched_file.len);
        @memcpy(self.matched_file[0..flen], file_name[0..flen]);
        self.matched_file_len = flen;
        if (std.fmt.bufPrint(&self.matched_path, "{s}/{s}", .{ dir_path, file_name })) |full_p| {
            self.matched_path_len = full_p.len;
        } else |_| {
            self.matched_path_len = 0;
        }
        self.depth = depth;
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
    if (findFirstSubpath(io, cwd, files)) |sub| {
        res.setMatch(cwd, sub, 0);
        return res;
    }

    // 2. Check extensions in cwd
    var ext_name_buf: [256]u8 = undefined;
    if (findFirstExtensionFile(io, cwd, extensions, &ext_name_buf)) |name| {
        res.setMatch(cwd, name, 0);
        return res;
    }

    // 3. Upward parent directories
    if (findInParentDirs(io, cwd, home, repo_root, files, max_depth)) |m| {
        res.setMatch(m.dir, m.file, m.depth);
    }

    return res;
}

/// Writes content to an absolute or relative file path, creating parent directories if needed.
pub fn writeFile(io: std.Io, path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        std.Io.Dir.cwd().createDirPath(io, parent) catch {};
    }
    var file = try createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

test "unit: fs.anySubpathExists on non-existent path returns false" {
    const io = std.testing.io;
    try std.testing.expect(!anySubpathExists(io, "/nonexistent_folder_xyz_123", &.{"file.txt"}));
}

test "unit: fs unified file and directory helpers" {
    const io = std.testing.io;

    try std.testing.expect(!fileExists(io, ""));
    try std.testing.expect(!dirExists(io, ""));
    try std.testing.expectError(error.FileNotFound, openFile(io, "", .{}));
    try std.testing.expectError(error.FileNotFound, createFile(io, "", .{}));
    try std.testing.expectError(error.FileNotFound, openDir(io, "", .{}));
    try std.testing.expectError(error.FileNotFound, access(io, "", .{}));

    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_dir = try testTempSubdir(&tmp_buf, "zap_test_fs_ssot");
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    var file_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_path = platform.joinPath(&file_buf, tmp_dir, "nested/test.txt").?;
    try writeFile(io, file_path, "hello zap");

    try std.testing.expect(dirExists(io, tmp_dir));
    try std.testing.expect(fileExists(io, file_path));

    var dir = try openDir(io, tmp_dir, .{});
    dir.close(io);

    var file = try openFile(io, file_path, .{});
    file.close(io);

    var read_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hello zap", readFileRaw(io, file_path, &read_buf).?);
}
