const std = @import("std");

/// Parses the contents of a .git/HEAD file and extracts the branch name or short commit SHA.
pub fn parseHeadContent(content_raw: []const u8) ?[]const u8 {
    const content = std.mem.trim(u8, content_raw, " \t\r\n");
    if (content.len == 0) return null;

    if (std.mem.startsWith(u8, content, "ref: refs/heads/")) {
        return content["ref: refs/heads/".len..];
    } else if (std.mem.startsWith(u8, content, "ref: refs/")) {
        return content["ref: refs/".len..];
    }

    // Check if it's a raw commit hash (SHA-1: 40 hex chars, or SHA-256: 64 hex chars)
    if (content.len >= 7) {
        var is_hex = true;
        for (content[0..7]) |c| {
            if (!std.ascii.isHex(c)) {
                is_hex = false;
                break;
            }
        }
        if (is_hex) {
            return content[0..7];
        }
    }

    return content;
}

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
        // Build path: "<current>/.git"
        const git_path = std.fmt.bufPrint(out_buf, "{s}/.git", .{current}) catch return null;

        // Try opening .git as a directory or file
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

/// Resolves the current git branch name or short commit SHA from cwd.
pub fn getGitBranch(
    io: std.Io,
    cwd: []const u8,
    git_dir_buf: *[std.fs.max_path_bytes]u8,
    head_content_buf: *[512]u8,
) ?[]const u8 {
    const git_dir = findGitDir(io, cwd, git_dir_buf) orelse return null;

    var head_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const head_path = std.fmt.bufPrint(&head_path_buf, "{s}/HEAD", .{git_dir}) catch return null;

    const file = std.Io.Dir.openFileAbsolute(io, head_path, .{}) catch return null;
    defer file.close(io);

    var stream_buf: [512]u8 = undefined;
    var file_reader = file.reader(io, &stream_buf);

    const bytes_read = file_reader.interface.readSliceShort(head_content_buf) catch return null;
    if (bytes_read == 0) return null;

    return parseHeadContent(head_content_buf[0..bytes_read]);
}

test "parseHeadContent on regular branch" {
    const raw = "ref: refs/heads/main\n";
    try std.testing.expectEqualStrings("main", parseHeadContent(raw).?);

    const nested = "ref: refs/heads/feature/auth-v2\n";
    try std.testing.expectEqualStrings("feature/auth-v2", parseHeadContent(nested).?);
}

test "parseHeadContent on detached HEAD SHA-1" {
    const raw = "4cd65cc6c714604db0f7a6f6df0b6b66a7620ce0\n";
    try std.testing.expectEqualStrings("4cd65cc", parseHeadContent(raw).?);
}

test "parseGitDirPointer worktree" {
    const raw = "gitdir: /home/user/project/.git/worktrees/feat\n";
    try std.testing.expectEqualStrings("/home/user/project/.git/worktrees/feat", parseGitDirPointer(raw).?);
}
