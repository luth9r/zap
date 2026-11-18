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

fn readStepFile(io: std.Io, git_dir: []const u8, subpath: []const u8, out_buf: *[32]u8) []const u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ git_dir, subpath }) catch return "";
    return fs.readSmallFile(io, full_path, out_buf) orelse "";
}

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
    if (fs.dirExists(io, rebase_merge)) {
        return GitStateResult{
            .state_type = .rebase,
            .progress_current = readStepFile(io, git_dir, "rebase-merge/msgnum", cur_step_buf),
            .progress_total = readStepFile(io, git_dir, "rebase-merge/end", total_step_buf),
        };
    }

    // 2. Rebase apply
    const rebase_apply = std.fmt.bufPrint(&path_buf, "{s}/rebase-apply", .{git_dir}) catch return .{};
    if (fs.dirExists(io, rebase_apply)) {
        const is_am = fs.anySubpathExists(io, git_dir, &.{"rebase-apply/applying"});
        const is_rebase = fs.anySubpathExists(io, git_dir, &.{"rebase-apply/rebasing"});
        const cur = readStepFile(io, git_dir, "rebase-apply/next", cur_step_buf);
        const total = readStepFile(io, git_dir, "rebase-apply/last", total_step_buf);

        const state_type: GitStateType = if (is_am)
            .am
        else if (is_rebase or cur.len > 0 or total.len > 0)
            .rebase
        else
            .am_or_rebase;

        return GitStateResult{
            .state_type = state_type,
            .progress_current = cur,
            .progress_total = total,
        };
    }

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

    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = try fs.testTempSubdir(&tmp_buf, "zap_test_git_state_clean");
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

    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = try fs.testTempSubdir(&tmp_buf, "zap_test_git_state_markers");
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

    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = try fs.testTempSubdir(&tmp_buf, "zap_test_git_state_rebase");
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

test "unit: getGitState detects am_or_rebase on plain rebase-apply directory" {
    const io = testing.io;
    var cur_buf: [32]u8 = undefined;
    var tot_buf: [32]u8 = undefined;

    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = try fs.testTempSubdir(&tmp_buf, "zap_test_git_state_am_or_rebase");
    std.Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try std.Io.Dir.cwd().createDirPath(io, tmp);
    defer std.Io.Dir.cwd().deleteTree(io, tmp) catch {};

    var ra_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ra_path = try std.fmt.bufPrint(&ra_buf, "{s}/rebase-apply", .{tmp});
    try std.Io.Dir.cwd().createDirPath(io, ra_path);

    const res = getGitState(io, tmp, &cur_buf, &tot_buf);
    try testing.expectEqual(GitStateType.am_or_rebase, res.state_type);
}
