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
