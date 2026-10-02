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

const testing = std.testing;

test "unit: getGitState returns none on clean repo" {
    const io = testing.io;
    var cur_buf: [32]u8 = undefined;
    var tot_buf: [32]u8 = undefined;

    const tmp = "/tmp/zap_test_git_state_clean";
    std.Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try std.Io.Dir.cwd().createDirPath(io, tmp);
    defer std.Io.Dir.cwd().deleteTree(io, tmp) catch {};

    const res = getGitState(io, tmp, &cur_buf, &tot_buf);
    try testing.expectEqual(GitStateType.none, res.state_type);
    try testing.expectEqualStrings("", res.progress_current);
    try testing.expectEqualStrings("", res.progress_total);
}

test "unit: getGitState detects merge, cherry-pick, revert, bisect" {
    const io = testing.io;
    var cur_buf: [32]u8 = undefined;
    var tot_buf: [32]u8 = undefined;

    const tmp = "/tmp/zap_test_git_state_markers";
    std.Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try std.Io.Dir.cwd().createDirPath(io, tmp);
    defer std.Io.Dir.cwd().deleteTree(io, tmp) catch {};

    // 1. Merge
    var merge_head_buf: [std.fs.max_path_bytes]u8 = undefined;
    const merge_head = try std.fmt.bufPrint(&merge_head_buf, "{s}/MERGE_HEAD", .{tmp});
    try fs.writeFileAbsolute(io, merge_head, "1234567\n");
    var res = getGitState(io, tmp, &cur_buf, &tot_buf);
    try testing.expectEqual(GitStateType.merge, res.state_type);
    try std.Io.Dir.deleteFileAbsolute(io, merge_head);

    // 2. Cherry-pick
    var cp_head_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cp_head = try std.fmt.bufPrint(&cp_head_buf, "{s}/CHERRY_PICK_HEAD", .{tmp});
    try fs.writeFileAbsolute(io, cp_head, "1234567\n");
    res = getGitState(io, tmp, &cur_buf, &tot_buf);
    try testing.expectEqual(GitStateType.cherry_pick, res.state_type);
    try std.Io.Dir.deleteFileAbsolute(io, cp_head);

    // 3. Revert
    var rev_head_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rev_head = try std.fmt.bufPrint(&rev_head_buf, "{s}/REVERT_HEAD", .{tmp});
    try fs.writeFileAbsolute(io, rev_head, "1234567\n");
    res = getGitState(io, tmp, &cur_buf, &tot_buf);
    try testing.expectEqual(GitStateType.revert, res.state_type);
    try std.Io.Dir.deleteFileAbsolute(io, rev_head);

    // 4. Bisect
    var bisect_buf: [std.fs.max_path_bytes]u8 = undefined;
    const bisect_file = try std.fmt.bufPrint(&bisect_buf, "{s}/BISECT_LOG", .{tmp});
    try fs.writeFileAbsolute(io, bisect_file, "git bisect start\n");
    res = getGitState(io, tmp, &cur_buf, &tot_buf);
    try testing.expectEqual(GitStateType.bisect, res.state_type);
}

test "unit: getGitState detects rebase-merge with progress steps" {
    const io = testing.io;
    var cur_buf: [32]u8 = undefined;
    var tot_buf: [32]u8 = undefined;

    const tmp = "/tmp/zap_test_git_state_rebase";
    std.Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try std.Io.Dir.cwd().createDirPath(io, tmp);
    defer std.Io.Dir.cwd().deleteTree(io, tmp) catch {};

    var msgnum_buf: [std.fs.max_path_bytes]u8 = undefined;
    const msgnum_path = try std.fmt.bufPrint(&msgnum_buf, "{s}/rebase-merge/msgnum", .{tmp});
    try fs.writeFileAbsolute(io, msgnum_path, "2\n");

    var end_buf: [std.fs.max_path_bytes]u8 = undefined;
    const end_path = try std.fmt.bufPrint(&end_buf, "{s}/rebase-merge/end", .{tmp});
    try fs.writeFileAbsolute(io, end_path, "5\n");

    const res = getGitState(io, tmp, &cur_buf, &tot_buf);
    try testing.expectEqual(GitStateType.rebase, res.state_type);
    try testing.expectEqualStrings("2", res.progress_current);
    try testing.expectEqualStrings("5", res.progress_total);
}
