const std = @import("std");
const fs = @import("../fs.zig");
const dir = @import("dir.zig");

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
    const git_dir = dir.findGitDir(io, cwd, git_dir_buf) orelse return null;
    return getGitBranchFromDir(io, git_dir, head_content_buf);
}

pub const GitCommitResult = struct {
    hash: []const u8 = "",
    tag: []const u8 = "",
    is_detached: bool = false,
};

fn findTagForHash(
    io: std.Io,
    git_dir: []const u8,
    target_sha: []const u8,
    tag_name_buf: []u8,
) ?[]const u8 {
    var tags_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tags_path = std.fmt.bufPrint(&tags_path_buf, "{s}/refs/tags", .{git_dir}) catch return null;

    if (std.Io.Dir.openDirAbsolute(io, tags_path, .{ .iterate = true })) |tags_dir| {
        var dir_val = tags_dir;
        defer dir_val.close(io);
        var iter = std.Io.Dir.iterate(dir_val);
        while (iter.next(io) catch null) |entry| {
            if (entry.kind == .file) {
                var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const file_path = std.fmt.bufPrint(&file_path_buf, "{s}/{s}", .{tags_path, entry.name}) catch continue;
                
                var sha_buf: [64]u8 = undefined;
                if (fs.readSmallFile(io, file_path, &sha_buf)) |raw_sha| {
                    const sha = std.mem.trim(u8, raw_sha, " \t\r\n");
                    if (std.mem.eql(u8, sha, target_sha)) {
                        const name_len = @min(entry.name.len, tag_name_buf.len);
                        @memcpy(tag_name_buf[0..name_len], entry.name[0..name_len]);
                        return tag_name_buf[0..name_len];
                    }
                }
            }
        }
    } else |_| {}

    var packed_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const packed_path = std.fmt.bufPrint(&packed_path_buf, "{s}/packed-refs", .{git_dir}) catch return null;
    if (std.Io.Dir.openFileAbsolute(io, packed_path, .{})) |file_h| {
        var f = file_h;
        defer f.close(io);
        var stream_buf: [4096]u8 = undefined;
        var reader = f.reader(io, &stream_buf);
        var content_buf: [32768]u8 = undefined;
        const bytes = reader.interface.readSliceShort(&content_buf) catch 0;
        const packed_content = content_buf[0..bytes];
        
        var lines = std.mem.splitScalar(u8, packed_content, '\n');
        var prev_line_tag: ?[]const u8 = null;
        
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            
            if (trimmed[0] == '^') {
                const peeled_sha = trimmed[1..];
                if (std.mem.eql(u8, peeled_sha, target_sha)) {
                    if (prev_line_tag) |tag_ref| {
                        if (std.mem.startsWith(u8, tag_ref, "refs/tags/")) {
                            const tag_name = tag_ref["refs/tags/".len..];
                            const name_len = @min(tag_name.len, tag_name_buf.len);
                            @memcpy(tag_name_buf[0..name_len], tag_name[0..name_len]);
                            return tag_name_buf[0..name_len];
                        }
                    }
                }
            } else {
                var it = std.mem.splitScalar(u8, trimmed, ' ');
                const sha = it.next() orelse continue;
                const ref = it.next() orelse continue;
                
                if (std.mem.eql(u8, sha, target_sha)) {
                    if (std.mem.startsWith(u8, ref, "refs/tags/")) {
                        const tag_name = ref["refs/tags/".len..];
                        const name_len = @min(tag_name.len, tag_name_buf.len);
                        @memcpy(tag_name_buf[0..name_len], tag_name[0..name_len]);
                        return tag_name_buf[0..name_len];
                    }
                }
                prev_line_tag = ref;
            }
        }
    } else |_| {}

    return null;
}

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
                const tag = findTagForHash(io, git_dir, sha, ref_content_buf[64..192]) orelse "";
                return GitCommitResult{
                    .hash = sha,
                    .tag = tag,
                    .is_detached = false,
                };
            }
        } else |_| {}

        return GitCommitResult{
            .hash = "",
            .is_detached = false,
        };
    } else if (raw_head.len >= 7) {
        const tag = findTagForHash(io, git_dir, raw_head, ref_content_buf[0..128]) orelse "";
        return GitCommitResult{
            .hash = raw_head,
            .tag = tag,
            .is_detached = true,
        };
    }

    return null;
}
