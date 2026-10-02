const std = @import("std");
const fs = @import("../fs.zig");
const testing = std.testing;

pub const AheadBehindResult = struct {
    ahead: usize = 0,
    behind: usize = 0,
};

pub const UpstreamConfig = struct {
    remote: []const u8 = "",
    merge: []const u8 = "",
};

/// Reads .git/config and resolves upstream tracking remote and merge ref for a branch.
pub fn parseUpstreamFromConfig(
    config_content: []const u8,
    branch_name: []const u8,
) UpstreamConfig {
    var res = UpstreamConfig{};
    var line_it = std.mem.splitScalar(u8, config_content, '\n');
    var in_target_branch = false;

    // Target section header: [branch "branch_name"]
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        if (line[0] == '[') {
            if (std.mem.startsWith(u8, line, "[branch \"") and std.mem.endsWith(u8, line, "\"]")) {
                const sec_branch = line["[branch \"".len .. line.len - "\"]".len];
                in_target_branch = std.mem.eql(u8, sec_branch, branch_name);
            } else {
                in_target_branch = false;
            }
            continue;
        }

        if (!in_target_branch) continue;

        if (std.mem.indexOfScalar(u8, line, '=')) |eq_idx| {
            const key = std.mem.trim(u8, line[0..eq_idx], " \t");
            const val = std.mem.trim(u8, line[eq_idx + 1 ..], " \t");

            if (std.mem.eql(u8, key, "remote")) {
                res.remote = val;
            } else if (std.mem.eql(u8, key, "merge")) {
                res.merge = val;
            }
        }
    }

    return res;
}

/// Resolves commit SHA from .git/refs or packed-refs
pub fn resolveRefSha(
    io: std.Io,
    git_dir: []const u8,
    ref_subpath: []const u8,
    sha_buf: *[64]u8,
) ?[]const u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;

    // 1. Direct loose ref file: .git/<ref_subpath>
    const full_ref_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ git_dir, ref_subpath }) catch return null;
    if (fs.readSmallFile(io, full_ref_path, sha_buf)) |content| {
        const sha = std.mem.trim(u8, content, " \t\r\n");
        if (sha.len >= 40) return sha[0..40];
    }

    // 2. Packed refs: .git/packed-refs
    const packed_path = std.fmt.bufPrint(&path_buf, "{s}/packed-refs", .{git_dir}) catch return null;
    var packed_buf: [4096]u8 = undefined;
    if (fs.readSmallFile(io, packed_path, &packed_buf)) |packed_content| {
        var it = std.mem.splitScalar(u8, packed_content, '\n');
        while (it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
            if (std.mem.indexOfScalar(u8, line, ' ')) |sp_idx| {
                const sha = line[0..sp_idx];
                const ref = line[sp_idx + 1 ..];
                if (std.mem.eql(u8, ref, ref_subpath) and sha.len >= 40) {
                    @memcpy(sha_buf[0..40], sha[0..40]);
                    return sha_buf[0..40];
                }
            }
        }
    }

    return null;
}

/// Resolves ahead/behind commit counts between local branch and its upstream tracking ref.
pub fn getAheadBehind(
    io: std.Io,
    git_dir: []const u8,
    branch_name: []const u8,
) AheadBehindResult {
    var config_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const config_path = std.fmt.bufPrint(&config_path_buf, "{s}/config", .{git_dir}) catch return .{};

    var config_buf: [4096]u8 = undefined;
    const config_content = fs.readSmallFile(io, config_path, &config_buf) orelse return .{};

    const upstream = parseUpstreamFromConfig(config_content, branch_name);
    if (upstream.remote.len == 0 or upstream.merge.len == 0) return .{};

    // Resolve local ref SHA
    var local_ref_buf: [256]u8 = undefined;
    const local_ref_subpath = std.fmt.bufPrint(&local_ref_buf, "refs/heads/{s}", .{branch_name}) catch return .{};
    var local_sha_buf: [64]u8 = undefined;
    const local_sha = resolveRefSha(io, git_dir, local_ref_subpath, &local_sha_buf) orelse return .{};

    // Resolve upstream ref SHA
    var upstream_ref_buf: [256]u8 = undefined;
    const upstream_ref_subpath = if (std.mem.eql(u8, upstream.remote, "."))
        (if (std.mem.startsWith(u8, upstream.merge, "refs/")) upstream.merge else std.fmt.bufPrint(&upstream_ref_buf, "refs/heads/{s}", .{upstream.merge}) catch return .{})
    else blk: {
        const merge_name = if (std.mem.startsWith(u8, upstream.merge, "refs/heads/"))
            upstream.merge["refs/heads/".len..]
        else
            upstream.merge;
        break :blk std.fmt.bufPrint(&upstream_ref_buf, "refs/remotes/{s}/{s}", .{ upstream.remote, merge_name }) catch return .{};
    };

    var upstream_sha_buf: [64]u8 = undefined;
    const upstream_sha = resolveRefSha(io, git_dir, upstream_ref_subpath, &upstream_sha_buf) orelse return .{};

    // Up to date
    if (std.mem.eql(u8, local_sha, upstream_sha)) {
        return .{ .ahead = 0, .behind = 0 };
    }

    // Extract recent commit chains from both reflogs to find merge-base
    const max_chain = 128;
    var local_shas: [max_chain][40]u8 = undefined;
    var local_count: usize = 0;
    @memcpy(&local_shas[0], local_sha);
    local_count = 1;

    var log_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const local_log_path = std.fmt.bufPrint(&log_path_buf, "{s}/logs/{s}", .{ git_dir, local_ref_subpath }) catch return .{};
    var local_log_buf: [8192]u8 = undefined;

    if (fs.readTailFile(io, local_log_path, &local_log_buf)) |log_content| {
        var current_target: [40]u8 = undefined;
        @memcpy(&current_target, local_sha);

        var line_it = std.mem.splitBackwardsScalar(u8, log_content, '\n');
        while (line_it.next()) |raw_line| {
            if (local_count >= max_chain) break;
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len < 81) continue;
            const old_sha = line[0..40];
            const new_sha = line[41..81];
            if (std.mem.eql(u8, new_sha, &current_target)) {
                if (std.mem.eql(u8, old_sha, "0000000000000000000000000000000000000000")) break;
                @memcpy(&local_shas[local_count], old_sha);
                @memcpy(&current_target, old_sha);
                local_count += 1;
            }
        }
    }

    var upstream_shas: [max_chain][40]u8 = undefined;
    var upstream_count: usize = 0;
    @memcpy(&upstream_shas[0], upstream_sha);
    upstream_count = 1;

    const upstream_log_path = std.fmt.bufPrint(&log_path_buf, "{s}/logs/{s}", .{ git_dir, upstream_ref_subpath }) catch return .{ .ahead = 1, .behind = 0 };
    var upstream_log_buf: [8192]u8 = undefined;

    if (fs.readTailFile(io, upstream_log_path, &upstream_log_buf)) |log_content| {
        var current_target: [40]u8 = undefined;
        @memcpy(&current_target, upstream_sha);

        var line_it = std.mem.splitBackwardsScalar(u8, log_content, '\n');
        while (line_it.next()) |raw_line| {
            if (upstream_count >= max_chain) break;
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len < 81) continue;
            const old_sha = line[0..40];
            const new_sha = line[41..81];
            if (std.mem.eql(u8, new_sha, &current_target)) {
                if (std.mem.eql(u8, old_sha, "0000000000000000000000000000000000000000")) break;
                @memcpy(&upstream_shas[upstream_count], old_sha);
                @memcpy(&current_target, old_sha);
                upstream_count += 1;
            }
        }
    }

    // Find the newest common ancestor in local history that exists in upstream history
    var i: usize = 0;
    while (i < local_count) : (i += 1) {
        var j: usize = 0;
        while (j < upstream_count) : (j += 1) {
            if (std.mem.eql(u8, &local_shas[i], &upstream_shas[j])) {
                return .{
                    .ahead = i,
                    .behind = j,
                };
            }
        }
    }

    const has_local_log = fs.fileExists(io, local_log_path);
    const has_upstream_log = fs.fileExists(io, upstream_log_path);

    if (!has_local_log and !has_upstream_log) {
        return .{ .ahead = 0, .behind = 0 };
    }

    return .{ .ahead = 1, .behind = 1 };
}

test "unit: parseUpstreamFromConfig extracts remote and merge" {
    const config =
        \\[core]
        \\    repositoryformatversion = 0
        \\[branch "master"]
        \\    remote = origin
        \\    merge = refs/heads/main
        \\[branch "feature"]
        \\    remote = .
        \\    merge = refs/heads/base_branch
    ;

    const up_master = parseUpstreamFromConfig(config, "master");
    try testing.expectEqualStrings("origin", up_master.remote);
    try testing.expectEqualStrings("refs/heads/main", up_master.merge);

    const up_feat = parseUpstreamFromConfig(config, "feature");
    try testing.expectEqualStrings(".", up_feat.remote);
    try testing.expectEqualStrings("refs/heads/base_branch", up_feat.merge);

    const up_none = parseUpstreamFromConfig(config, "nonexistent");
    try testing.expectEqualStrings("", up_none.remote);
    try testing.expectEqualStrings("", up_none.merge);
}
