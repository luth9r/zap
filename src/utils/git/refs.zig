const std = @import("std");
const fs = @import("fs.zig");

/// Parses the contents of a .git/HEAD file and extracts the branch name or short commit SHA.
pub fn parseHeadContent(content_raw: []const u8) ?[]const u8 {
    const content = std.mem.trim(u8, content_raw, " \t\r\n");
    if (content.len == 0) return null;

    if (std.mem.startsWith(u8, content, "ref: refs/heads/")) {
        return content["ref: refs/heads/".len..];
    } else if (std.mem.startsWith(u8, content, "ref: refs/")) {
        return content["ref: refs/".len..];
    }

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

/// Resolves the current git branch name or short commit SHA directly from git_dir.
pub fn getGitBranchFromDir(
    io: std.Io,
    git_dir: []const u8,
    head_content_buf: *[512]u8,
) ?[]const u8 {
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

/// Resolves the current git branch name or short commit SHA from cwd.
pub fn getGitBranch(
    io: std.Io,
    cwd: []const u8,
    git_dir_buf: *[std.fs.max_path_bytes]u8,
    head_content_buf: *[512]u8,
) ?[]const u8 {
    const git_dir = fs.findGitDir(io, cwd, git_dir_buf) orelse return null;
    return getGitBranchFromDir(io, git_dir, head_content_buf);
}

pub const GitCommitResult = struct {
    hash: []const u8 = "",
    tag: []const u8 = "",
    is_detached: bool = false,
};

/// Resolves commit hash and detached state from .git directory.
pub fn getGitCommit(
    io: std.Io,
    git_dir: []const u8,
    head_content_buf: *[512]u8,
    ref_content_buf: *[512]u8,
) ?GitCommitResult {
    var head_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const head_path = std.fmt.bufPrint(&head_path_buf, "{s}/HEAD", .{git_dir}) catch return null;

    const file = std.Io.Dir.openFileAbsolute(io, head_path, .{}) catch return null;
    defer file.close(io);

    var stream_buf: [512]u8 = undefined;
    var file_reader = file.reader(io, &stream_buf);
    const bytes_read = file_reader.interface.readSliceShort(head_content_buf) catch return null;
    if (bytes_read == 0) return null;

    const raw_head = std.mem.trim(u8, head_content_buf[0..bytes_read], " \t\r\n");

    if (std.mem.startsWith(u8, raw_head, "ref: refs/heads/")) {
        const branch_ref = raw_head["ref: ".len..];
        var ref_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const ref_path = std.fmt.bufPrint(&ref_path_buf, "{s}/{s}", .{ git_dir, branch_ref }) catch return null;

        if (std.Io.Dir.openFileAbsolute(io, ref_path, .{})) |ref_file| {
            defer ref_file.close(io);
            var ref_stream_buf: [512]u8 = undefined;
            var ref_reader = ref_file.reader(io, &ref_stream_buf);
            const ref_bytes = ref_reader.interface.readSliceShort(ref_content_buf) catch 0;
            if (ref_bytes >= 7) {
                const sha = std.mem.trim(u8, ref_content_buf[0..ref_bytes], " \t\r\n");
                return GitCommitResult{
                    .hash = sha,
                    .is_detached = false,
                };
            }
        } else |_| {}

        return GitCommitResult{
            .hash = "",
            .is_detached = false,
        };
    } else if (raw_head.len >= 7) {
        return GitCommitResult{
            .hash = raw_head,
            .is_detached = true,
        };
    }

    return null;
}
