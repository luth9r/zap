const std = @import("std");
const context = @import("../../../engine/context.zig");
const git_utils = @import("../../../utils/git_utils.zig");
const DebugContext = context.DebugContext;

pub fn printGitVerboseDebug(init: std.process.Init, writer: anytype, dctx: DebugContext) !void {
    _ = init;
    const io = dctx.prompt.io orelse return;

    var start_ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (@import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &start_ts);
    }

    var git_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_dir_opt = dctx.prompt.git_dir orelse git_utils.findGitDir(io, dctx.prompt.cwd, &git_dir_buf);

    if (git_dir_opt == null) {
        if (dctx.json) {
            try writer.writeAll("{\"in_git_repo\": false}\n");
        } else {
            try writer.print("⚡ Zap Git Inspector (Verbose)\n\n✖ Not a git repository (cwd: {s})\n", .{dctx.prompt.cwd});
        }
        return;
    }

    const git_dir = git_dir_opt.?;
    const repo_root = git_utils.gitDirToRepoRoot(git_dir);

    var branch_buf: [512]u8 = undefined;
    const branch_opt = git_utils.getGitBranchFromDir(io, git_dir, &branch_buf);
    const branch_name = branch_opt orelse "DETACHED HEAD";

    var head_buf: [512]u8 = undefined;
    var ref_buf: [512]u8 = undefined;
    const commit_info = git_utils.getGitCommit(io, git_dir, &head_buf, &ref_buf);
    var ab = git_utils.git.ahead_behind.AheadBehindResult{};
    if (branch_opt) |b| {
        ab = git_utils.getAheadBehind(io, git_dir, b);
    }
    const status = git_utils.getGitStatusForDir(io, dctx.prompt.cwd, git_dir, branch_opt);
    const index_scan = git_utils.scanGitIndex(io, git_dir, repo_root);

    var cur_buf: [32]u8 = undefined;
    var total_buf: [32]u8 = undefined;
    const git_state = git_utils.getGitState(io, git_dir, &cur_buf, &total_buf);

    var collector = git_utils.GitFileCollector{};
    git_utils.collectDetailedGitFiles(io, git_dir, repo_root, &collector);

    const is_worktree = !std.mem.endsWith(u8, git_dir, "/.git") and !std.mem.eql(u8, git_dir, ".git");

    var elapsed_us: u64 = 0;
    if (@import("builtin").os.tag == .linux) {
        var end_ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
        _ = std.os.linux.clock_gettime(.MONOTONIC, &end_ts);
        const sec_diff = end_ts.sec - start_ts.sec;
        const nsec_diff = end_ts.nsec - start_ts.nsec;
        const total_ns = @as(u64, @intCast(@max(0, sec_diff * 1_000_000_000 + nsec_diff)));
        elapsed_us = @divTrunc(total_ns, 1000);
    }

    if (dctx.json) {
        try writer.print(
            \\{{ "module": "git", "verbose": true, "in_git_repo": true, "repo_root": "{s}", "git_dir": "{s}", "is_worktree": {}, "branch": "{s}", "commit": "{s}", "tag": "{s}", "detached": {}, "ahead": {d}, "behind": {d}, "index_entries": {d}, "status": {{ "staged": {}, "modified": {}, "untracked": {}, "deleted": {}, "stashed": {}, "conflicted": {} }}, "files": {{ "modified": [
        , .{
            repo_root,
            git_dir,
            is_worktree,
            branch_name,
            if (commit_info) |c| c.hash else "",
            if (commit_info) |c| c.tag else "",
            if (commit_info) |c| c.is_detached else false,
            ab.ahead,
            ab.behind,
            index_scan.entry_count,
            status.staged,
            status.modified,
            status.untracked,
            status.deleted,
            status.stashed,
            status.conflicted,
        });

        var m_idx: usize = 0;
        while (m_idx < collector.modified_count) : (m_idx += 1) {
            if (m_idx > 0) try writer.writeAll(", ");
            try writer.print("\"{s}\"", .{collector.getModified(m_idx)});
        }
        try writer.writeAll("], \"untracked\": [");
        var u_idx: usize = 0;
        while (u_idx < collector.untracked_count) : (u_idx += 1) {
            if (u_idx > 0) try writer.writeAll(", ");
            try writer.print("\"{s}\"", .{collector.getUntracked(u_idx)});
        }
        try writer.writeAll("], \"deleted\": [");
        var d_idx: usize = 0;
        while (d_idx < collector.deleted_count) : (d_idx += 1) {
            if (d_idx > 0) try writer.writeAll(", ");
            try writer.print("\"{s}\"", .{collector.getDeleted(d_idx)});
        }
        try writer.writeAll("], \"conflicted\": [");
        var c_idx: usize = 0;
        while (c_idx < collector.conflicted_count) : (c_idx += 1) {
            if (c_idx > 0) try writer.writeAll(", ");
            try writer.print("\"{s}\"", .{collector.getConflicted(c_idx)});
        }
        try writer.print(
            \\ ] }}, "state": "{s}", "scan_duration_us": {d} }}
            \\
        , .{
            @tagName(git_state.state_type),
            elapsed_us,
        });
    } else {
        try writer.print(
            \\⚡ Zap Git Diagnostic Inspector (Verbose Mode)
            \\
            \\Repository:
            \\  Repo Root:        {s}
            \\  Git Dir:          {s}
            \\  Worktree:         {s}
            \\  Index Entries:    {d} tracked files
            \\
            \\Reference & Commit:
            \\  Branch:           {s}
            \\  Commit SHA:       {s}
            \\  Tag:              {s}
            \\  HEAD Detached:    {}
            \\
            \\Ahead / Behind:
            \\  Ahead (⇡):        {d} commits
            \\  Behind (⇣):       {d} commits
            \\
            \\Status Flags:
            \\  Staged (+):       {}
            \\  Modified (!):     {} ({d} files)
            \\  Untracked (?):    {} ({d} files)
            \\  Deleted (✘):      {} ({d} files)
            \\  Stashed ($):      {}
            \\  Conflicted (=):   {} ({d} files)
            \\
            \\Modified Files (!):
            \\
        , .{
            repo_root,
            git_dir,
            if (is_worktree) "Yes (linked worktree)" else "No (standard repository)",
            index_scan.entry_count,
            branch_name,
            if (commit_info) |c| c.hash else "none",
            if (commit_info) |c| (if (c.tag.len > 0) c.tag else "none") else "none",
            if (commit_info) |c| c.is_detached else false,
            ab.ahead,
            ab.behind,
            status.staged,
            status.modified,
            collector.modified_count,
            status.untracked,
            collector.untracked_count,
            status.deleted,
            collector.deleted_count,
            status.stashed,
            status.conflicted,
            collector.conflicted_count,
        });

        if (collector.modified_count == 0) {
            try writer.writeAll("  (none)\n");
        } else {
            var i: usize = 0;
            while (i < collector.modified_count) : (i += 1) {
                try writer.print("  - {s}\n", .{collector.getModified(i)});
            }
        }

        try writer.writeAll("\nUntracked Files (?):\n");
        if (collector.untracked_count == 0) {
            try writer.writeAll("  (none)\n");
        } else {
            var i: usize = 0;
            while (i < collector.untracked_count) : (i += 1) {
                try writer.print("  - {s}\n", .{collector.getUntracked(i)});
            }
        }

        try writer.writeAll("\nDeleted Files (✘):\n");
        if (collector.deleted_count == 0) {
            try writer.writeAll("  (none)\n");
        } else {
            var i: usize = 0;
            while (i < collector.deleted_count) : (i += 1) {
                try writer.print("  - {s}\n", .{collector.getDeleted(i)});
            }
        }

        try writer.writeAll("\nConflicted Files (=):\n");
        if (collector.conflicted_count == 0) {
            try writer.writeAll("  (none)\n");
        } else {
            var i: usize = 0;
            while (i < collector.conflicted_count) : (i += 1) {
                try writer.print("  - {s}\n", .{collector.getConflicted(i)});
            }
        }

        try writer.print(
            \\
            \\Operation State:
            \\  State:            {s}
            \\
            \\Performance:
            \\  Scan Duration:    {d} µs ({d}.{d:0>3} ms)
            \\
        , .{
            @tagName(git_state.state_type),
            elapsed_us,
            @divTrunc(elapsed_us, 1000),
            @mod(elapsed_us, 1000),
        });
    }
}
