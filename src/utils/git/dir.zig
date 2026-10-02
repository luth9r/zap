const std = @import("std");

/// Parses a .git pointer file (common in git worktrees and submodules) with format "gitdir: <path>".
pub fn parseGitDirPointer(content_raw: []const u8) ?[]const u8 {
    const content = std.mem.trim(u8, content_raw, " \t\r\n");
    if (std.mem.startsWith(u8, content, "gitdir:")) {
        return std.mem.trim(u8, content["gitdir:".len..], " \t\r\n");
    }
    return null;
}

/// Locates the .git directory or gitdir pointer by searching the current directory and its ancestors.
pub fn findGitDir(
    io: std.Io,
    cwd: []const u8,
    out_buf: *[std.fs.max_path_bytes]u8,
) ?[]const u8 {
    var current: []const u8 = cwd;

    while (current.len > 0) {
        const git_path = std.fmt.bufPrint(out_buf, "{s}/.git", .{current}) catch return null;

        // Try opening .git as a directory
        if (std.Io.Dir.openDirAbsolute(io, git_path, .{})) |dir| {
            var d = dir;
            d.close(io);
            return git_path;
        } else |_| {
            // Check if .git is a file (worktree or submodule pointer)
            if (std.Io.Dir.openFileAbsolute(io, git_path, .{})) |file| {
                var stream_buf: [512]u8 = undefined;
                var file_reader = file.reader(io, &stream_buf);
                var content_buf: [512]u8 = undefined;
                const bytes_read = file_reader.interface.readSliceShort(&content_buf) catch 0;
                file.close(io);

                if (bytes_read > 0) {
                    if (parseGitDirPointer(content_buf[0..bytes_read])) |target_gitdir| {
                        if (std.fs.path.isAbsolute(target_gitdir)) {
                            return std.fmt.bufPrint(out_buf, "{s}", .{target_gitdir}) catch null;
                        } else {
                            return std.fmt.bufPrint(out_buf, "{s}/{s}", .{ current, target_gitdir }) catch null;
                        }
                    }
                }
            } else |_| {}
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        current = parent;
    }

    return null;
}

/// Locates the repository root directory by searching the current directory and its ancestors for .git.
pub fn findRepoRoot(
    io: std.Io,
    cwd: []const u8,
    out_buf: *[std.fs.max_path_bytes]u8,
) ?[]const u8 {
    var current: []const u8 = cwd;

    while (current.len > 0) {
        var git_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const git_path = std.fmt.bufPrint(&git_path_buf, "{s}/.git", .{current}) catch return null;

        // Check if .git is a directory
        if (std.Io.Dir.openDirAbsolute(io, git_path, .{})) |dir| {
            var d = dir;
            d.close(io);
            return std.fmt.bufPrint(out_buf, "{s}", .{current}) catch null;
        } else |_| {
            // Check if .git is a worktree / submodule pointer file
            if (std.Io.Dir.openFileAbsolute(io, git_path, .{})) |file| {
                file.close(io);
                return std.fmt.bufPrint(out_buf, "{s}", .{current}) catch null;
            } else |_| {}
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        current = parent;
    }

    return null;
}

/// Extracts repository root from a known git_dir path without filesystem I/O.
pub fn gitDirToRepoRoot(git_dir: []const u8) []const u8 {
    if (std.mem.endsWith(u8, git_dir, "/.git")) {
        return git_dir[0 .. git_dir.len - "/.git".len];
    }
    if (std.mem.indexOf(u8, git_dir, "/.git/worktrees/")) |wt_idx| {
        return git_dir[0..wt_idx];
    }
    return std.fs.path.dirname(git_dir) orelse git_dir;
}

test "unit: parseGitDirPointer parses valid and invalid pointers" {
    try std.testing.expectEqualStrings(
        "/path/to/.git/worktrees/wt",
        parseGitDirPointer("gitdir: /path/to/.git/worktrees/wt\n").?,
    );
    try std.testing.expect(parseGitDirPointer("not a gitdir pointer") == null);
}

test "unit: gitDirToRepoRoot extracts repo root" {
    try std.testing.expectEqualStrings("/home/user/zap", gitDirToRepoRoot("/home/user/zap/.git"));
    try std.testing.expectEqualStrings("/home/user/zap", gitDirToRepoRoot("/home/user/zap/.git/worktrees/feature"));
}
