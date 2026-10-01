const std = @import("std");
const fs = @import("../fs.zig");

pub const GitStateType = enum {
    none,
    rebase,
    merge,
    revert,
    cherry_pick,
    bisect,
    am,
    am_or_rebase,
};

pub const GitStateResult = struct {
    state_type: GitStateType = .none,
    progress_current: []const u8 = "",
    progress_total: []const u8 = "",
};

/// Detects the active git operation state (REBASING, MERGING, CHERRY-PICKING, REVERTING, etc.).
pub fn getGitState(
    io: std.Io,
    git_dir: []const u8,
    cur_step_buf: *[32]u8,
    total_step_buf: *[32]u8,
) GitStateResult {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;

    // 1. Rebase merge
    const rebase_merge = std.fmt.bufPrint(&path_buf, "{s}/rebase-merge", .{git_dir}) catch return .{};
    if (std.Io.Dir.openDirAbsolute(io, rebase_merge, .{})) |dir| {
        var d = dir;
        d.close(io);

        var cur: []const u8 = "";
        var total: []const u8 = "";

        const msgnum_path = std.fmt.bufPrint(&path_buf, "{s}/rebase-merge/msgnum", .{git_dir}) catch "";
        if (msgnum_path.len > 0) {
            if (fs.readSmallFile(io, msgnum_path, cur_step_buf)) |val| {
                cur = val;
            }
        }

        const end_path = std.fmt.bufPrint(&path_buf, "{s}/rebase-merge/end", .{git_dir}) catch "";
        if (end_path.len > 0) {
            if (fs.readSmallFile(io, end_path, total_step_buf)) |val| {
                total = val;
            }
        }

        return GitStateResult{
            .state_type = .rebase,
            .progress_current = cur,
            .progress_total = total,
        };
    } else |_| {}

    // 2. Rebase apply
    const rebase_apply = std.fmt.bufPrint(&path_buf, "{s}/rebase-apply", .{git_dir}) catch return .{};
    if (std.Io.Dir.openDirAbsolute(io, rebase_apply, .{})) |dir| {
        var d = dir;
        d.close(io);

        var is_am = false;
        const applying_path = std.fmt.bufPrint(&path_buf, "{s}/rebase-apply/applying", .{git_dir}) catch "";
        if (applying_path.len > 0) {
            if (fs.fileExists(io, applying_path)) {
                is_am = true;
            }
        }

        var cur: []const u8 = "";
        var total: []const u8 = "";

        const next_path = std.fmt.bufPrint(&path_buf, "{s}/rebase-apply/next", .{git_dir}) catch "";
        if (next_path.len > 0) {
            if (fs.readSmallFile(io, next_path, cur_step_buf)) |val| {
                cur = val;
            }
        }

        const last_path = std.fmt.bufPrint(&path_buf, "{s}/rebase-apply/last", .{git_dir}) catch "";
        if (last_path.len > 0) {
            if (fs.readSmallFile(io, last_path, total_step_buf)) |val| {
                total = val;
            }
        }

        return GitStateResult{
            .state_type = if (is_am) .am else .rebase,
            .progress_current = cur,
            .progress_total = total,
        };
    } else |_| {}

    // 3. Merge
    if (fs.anySubpathExists(io, git_dir, &.{"MERGE_HEAD"})) {
        return GitStateResult{ .state_type = .merge };
    }

    // 4. Cherry-pick
    if (fs.anySubpathExists(io, git_dir, &.{"CHERRY_PICK_HEAD"})) {
        return GitStateResult{ .state_type = .cherry_pick };
    }

    // 5. Revert
    if (fs.anySubpathExists(io, git_dir, &.{"REVERT_HEAD"})) {
        return GitStateResult{ .state_type = .revert };
    }

    // 6. Bisect
    if (fs.anySubpathExists(io, git_dir, &.{"BISECT_LOG"})) {
        return GitStateResult{ .state_type = .bisect };
    }

    return GitStateResult{};
}
