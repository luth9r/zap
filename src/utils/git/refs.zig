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

/// Resolves the current git branch name or short commit SHA from cwd.
pub fn getGitBranch(
    io: std.Io,
    cwd: []const u8,
    git_dir_buf: *[std.fs.max_path_bytes]u8,
    head_content_buf: *[512]u8,
) ?[]const u8 {
    const git_dir = fs.findGitDir(io, cwd, git_dir_buf) orelse return null;

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

pub fn matchPackedRef(line: []const u8, ref_name: []const u8, out_buf: []u8) ?[]const u8 {
    if (line.len == 0 or line[0] == '#' or line[0] == '^') return null;
    if (line.len >= 41 and line[40] == ' ') {
        const line_ref = line[41..];
        if (std.mem.eql(u8, line_ref, ref_name)) {
            const sha = line[0..40];
            if (sha.len <= out_buf.len) {
                @memcpy(out_buf[0..sha.len], sha);
                return out_buf[0..sha.len];
            }
        }
    }
    return null;
}

/// Reads a commit SHA for a ref from loose ref file or packed-refs.
pub fn readRefSha(
    io: std.Io,
    git_dir: []const u8,
    ref_name: []const u8,
    out_buf: []u8,
) ?[]const u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ref_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ git_dir, ref_name }) catch return null;

    if (std.Io.Dir.openFileAbsolute(io, ref_path, .{})) |f| {
        defer f.close(io);
        var stream_buf: [256]u8 = undefined;
        var r = f.reader(io, &stream_buf);
        var read_buf: [128]u8 = undefined;
        const n = r.interface.readSliceShort(&read_buf) catch 0;
        if (n >= 40) {
            const trimmed = std.mem.trim(u8, read_buf[0..n], " \t\r\n");
            if (trimmed.len >= 40 and trimmed.len <= out_buf.len) {
                @memcpy(out_buf[0..trimmed.len], trimmed);
                return out_buf[0..trimmed.len];
            }
        }
    } else |_| {}

    const packed_path = std.fmt.bufPrint(&path_buf, "{s}/packed-refs", .{git_dir}) catch return null;
    if (std.Io.Dir.openFileAbsolute(io, packed_path, .{})) |f| {
        defer f.close(io);
        var stream_buf: [1024]u8 = undefined;
        var r = f.reader(io, &stream_buf);
        var line_buf: [256]u8 = undefined;
        var line_pos: usize = 0;

        while (true) {
            var c_buf: [1]u8 = undefined;
            const cr = r.interface.readSliceShort(&c_buf) catch 0;
            if (cr == 0) {
                if (line_pos > 0) {
                    const line = std.mem.trim(u8, line_buf[0..line_pos], " \t\r\n");
                    if (matchPackedRef(line, ref_name, out_buf)) |sha| return sha;
                }
                break;
            }
            if (c_buf[0] == '\n') {
                const line = std.mem.trim(u8, line_buf[0..line_pos], " \t\r\n");
                if (matchPackedRef(line, ref_name, out_buf)) |sha| return sha;
                line_pos = 0;
            } else if (line_pos < line_buf.len) {
                line_buf[line_pos] = c_buf[0];
                line_pos += 1;
            }
        }
    } else |_| {}

    return null;
}

/// Resolves ahead and behind commit counts between local branch and upstream remote branch.
pub fn getAheadBehind(
    io: std.Io,
    git_dir: []const u8,
    branch_name: ?[]const u8,
) struct { ahead: usize, behind: usize } {
    const branch = branch_name orelse return .{ .ahead = 0, .behind = 0 };
    var local_ref_buf: [128]u8 = undefined;
    const local_ref_name = std.fmt.bufPrint(&local_ref_buf, "refs/heads/{s}", .{branch}) catch return .{ .ahead = 0, .behind = 0 };

    var local_sha_buf: [64]u8 = undefined;
    const local_sha = readRefSha(io, git_dir, local_ref_name, &local_sha_buf) orelse return .{ .ahead = 0, .behind = 0 };

    var remote_ref_buf: [128]u8 = undefined;
    const remote_ref_name = std.fmt.bufPrint(&remote_ref_buf, "refs/remotes/origin/{s}", .{branch}) catch return .{ .ahead = 0, .behind = 0 };

    var remote_sha_buf: [64]u8 = undefined;
    const remote_sha = readRefSha(io, git_dir, remote_ref_name, &remote_sha_buf) orelse return .{ .ahead = 0, .behind = 0 };

    if (std.mem.eql(u8, local_sha, remote_sha)) {
        return .{ .ahead = 0, .behind = 0 };
    }

    var ahead_count: usize = 0;
    const behind_count: usize = 0;

    var log_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const log_path = std.fmt.bufPrint(&log_path_buf, "{s}/logs/{s}", .{ git_dir, local_ref_name }) catch "";
    if (log_path.len > 0) {
        if (std.Io.Dir.openFileAbsolute(io, log_path, .{})) |f| {
            defer f.close(io);
            var stream_buf: [1024]u8 = undefined;
            var r = f.reader(io, &stream_buf);
            var count: usize = 0;
            var found_remote = false;

            var line_buf: [512]u8 = undefined;
            var line_pos: usize = 0;
            while (true) {
                var c_buf: [1]u8 = undefined;
                const cr = r.interface.readSliceShort(&c_buf) catch 0;
                if (cr == 0) {
                    if (line_pos > 0) {
                        const line = line_buf[0..line_pos];
                        if (std.mem.startsWith(u8, line, remote_sha) or (line.len >= 81 and std.mem.startsWith(u8, line[41..], remote_sha))) {
                            found_remote = true;
                        }
                    }
                    break;
                }
                if (c_buf[0] == '\n') {
                    const line = line_buf[0..line_pos];
                    if (found_remote) {
                        count += 1;
                    } else if (std.mem.startsWith(u8, line, remote_sha) or (line.len >= 81 and std.mem.startsWith(u8, line[41..], remote_sha))) {
                        found_remote = true;
                        count = 0;
                    }
                    line_pos = 0;
                } else if (line_pos < line_buf.len) {
                    line_buf[line_pos] = c_buf[0];
                    line_pos += 1;
                }
            }
            if (found_remote and count > 0) {
                ahead_count = count;
            }
        } else |_| {}
    }

    if (ahead_count == 0 and !std.mem.eql(u8, local_sha, remote_sha)) {
        ahead_count = 1;
    }

    return .{ .ahead = ahead_count, .behind = behind_count };
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
