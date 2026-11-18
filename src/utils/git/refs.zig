const std = @import("std");
const platform = @import("../platform.zig");

pub const GitCommitResult = struct {
    hash: []const u8 = "",
    tag: []const u8 = "",
    is_detached: bool = false,
};

/// Resolves the tag pointing to `target_sha` using `git describe --tags --exact-match`.
/// Supports lightweight tags, annotated tags, nested tag names, packed-refs, and worktrees.
pub fn findTagForHash(
    io: std.Io,
    git_dir: []const u8,
    target_sha: []const u8,
    tag_name_buf: []u8,
) ?[]const u8 {
    if (target_sha.len == 0) return null;

    var child = std.process.spawn(io, .{
        .argv = &.{
            "git",
            "--git-dir",
            git_dir,
            "--no-optional-locks",
            "-c",
            "core.fsmonitor=false",
            "describe",
            "--tags",
            "--exact-match",
            target_sha,
        },
        .stdout = .pipe,
        .stderr = .ignore,
        .stdin = .ignore,
    }) catch return null;

    var raw_buf: [256]u8 = undefined;
    const n = platform.readStreamToBuf(io, child.stdout.?, &raw_buf);
    const term = child.wait(io) catch return null;
    if (term != .exited or term.exited != 0 or n == 0) return null;

    const trimmed = std.mem.trim(u8, raw_buf[0..n], " \t\r\n");
    if (trimmed.len == 0) return null;

    const copy_len = @min(trimmed.len, tag_name_buf.len);
    @memcpy(tag_name_buf[0..copy_len], trimmed[0..copy_len]);
    return tag_name_buf[0..copy_len];
}
