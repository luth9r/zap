const std = @import("std");
const context = @import("../../../engine/context.zig");
const git_utils = @import("../../../utils/git_utils.zig");
const parse_utils = @import("../../../utils/parse_utils.zig");
const DebugContext = context.DebugContext;

fn writeJsonFileList(
    writer: anytype,
    collector: *const git_utils.GitFileCollector,
    list: *const git_utils.GitFileCollector.PathList,
) !void {
    var idx: usize = 0;
    while (idx < list.count) : (idx += 1) {
        if (idx > 0) try writer.writeAll(", ");
        const offset = list.offsets[idx];
        const slice = collector.storage[offset .. offset + list.lens[idx]];
        try writer.writeByte('"');
        try parse_utils.writeJsonEscaped(writer, slice);
        try writer.writeByte('"');
    }
}

fn writeTextFileList(
    writer: anytype,
    header: []const u8,
    collector: *const git_utils.GitFileCollector,
    list: *const git_utils.GitFileCollector.PathList,
) !void {
    try writer.print("\n{s}:\n", .{header});
    if (list.count == 0) {
        try writer.writeAll("  (none)\n");
    } else {
        var idx: usize = 0;
        while (idx < list.count) : (idx += 1) {
            const offset = list.offsets[idx];
            const slice = collector.storage[offset .. offset + list.lens[idx]];
            try writer.print("  - {s}\n", .{slice});
        }
    }
}

pub fn printGitVerboseDebug(init: std.process.Init, writer: anytype, dctx: DebugContext) !void {
    _ = init;
    const io = dctx.prompt.io orelse return;

    const start_ts = std.Io.Clock.awake.now(io);

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
    var repo_root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo_root = git_utils.resolveRepoRoot(io, dctx.prompt.cwd, git_dir, &repo_root_buf);

    var collector = git_utils.GitFileCollector{};
    const status = git_utils.collectDetailedGitFiles(io, git_dir, repo_root, &collector);

    var branch_buf: [256]u8 = undefined;
    const branch_opt = git_utils.resolveBranch(io, dctx.prompt.cwd, git_dir, &status, &branch_buf);
    const branch_name = branch_opt orelse "DETACHED HEAD";

    var oid_buf: [64]u8 = undefined;
    var tag_buf: [128]u8 = undefined;
    const commit_info = git_utils.resolveCommit(io, dctx.prompt.cwd, git_dir, &status, true, false, &oid_buf, &tag_buf);
    const index_entry_count = git_utils.getIndexEntryCount(io, git_dir);

    var cur_buf: [32]u8 = undefined;
    var total_buf: [32]u8 = undefined;
    const git_state = git_utils.getGitState(io, git_dir, &cur_buf, &total_buf);

    const is_worktree = !std.mem.eql(u8, std.fs.path.basename(git_dir), ".git");

    const total_ns = start_ts.untilNow(io, .awake).toNanoseconds();
    const elapsed_us: u64 = @intCast(@divTrunc(@max(0, total_ns), 1000));

    if (dctx.json) {
        var j_root: [std.fs.max_path_bytes]u8 = undefined;
        var j_gd: [std.fs.max_path_bytes]u8 = undefined;
        var j_br: [512]u8 = undefined;
        var j_tag: [256]u8 = undefined;
        try writer.print(
            \\{{ "module": "git", "verbose": true, "in_git_repo": true, "repo_root": "{s}", "git_dir": "{s}", "is_worktree": {}, "branch": "{s}", "commit": "{s}", "tag": "{s}", "detached": {}, "ahead": {d}, "behind": {d}, "index_entries": {d}, "status": {{ "staged": {}, "modified": {}, "untracked": {}, "deleted": {}, "renamed": {}, "stashed": {}, "conflicted": {} }}, "files": {{ "modified": [
        , .{
            parse_utils.escapeJsonBuf(&j_root, repo_root),
            parse_utils.escapeJsonBuf(&j_gd, git_dir),
            is_worktree,
            parse_utils.escapeJsonBuf(&j_br, branch_name),
            if (commit_info) |c| c.hash else "",
            if (commit_info) |c| parse_utils.escapeJsonBuf(&j_tag, c.tag) else "",
            if (commit_info) |c| c.is_detached else false,
            status.ahead,
            status.behind,
            index_entry_count,
            status.staged,
            status.modified,
            status.untracked,
            status.deleted,
            status.renamed,
            status.stashed,
            status.conflicted,
        });

        try writeJsonFileList(writer, &collector, &collector.modified);
        try writer.writeAll("], \"untracked\": [");
        try writeJsonFileList(writer, &collector, &collector.untracked);
        try writer.writeAll("], \"deleted\": [");
        try writeJsonFileList(writer, &collector, &collector.deleted);
        try writer.writeAll("], \"renamed\": [");
        try writeJsonFileList(writer, &collector, &collector.renamed);
        try writer.writeAll("], \"conflicted\": [");
        try writeJsonFileList(writer, &collector, &collector.conflicted);
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
            \\  Staged (+):       {} ({d} files)
            \\  Modified (!):     {} ({d} files)
            \\  Untracked (?):    {} ({d} files)
            \\  Deleted (✘):      {} ({d} files)
            \\  Renamed (»):      {} ({d} files)
            \\  Stashed ($):      {}
            \\  Conflicted (=):   {} ({d} files)
            \\
        , .{
            repo_root,
            git_dir,
            if (is_worktree) "Yes (linked worktree)" else "No (standard repository)",
            index_entry_count,
            branch_name,
            if (commit_info) |c| c.hash else "none",
            if (commit_info) |c| (if (c.tag.len > 0) c.tag else "none") else "none",
            if (commit_info) |c| c.is_detached else false,
            status.ahead,
            status.behind,
            status.staged,
            collector.staged_count,
            status.modified,
            collector.modified_count,
            status.untracked,
            collector.untracked_count,
            status.deleted,
            collector.deleted_count,
            status.renamed,
            collector.renamed_count,
            status.stashed,
            status.conflicted,
            collector.conflicted_count,
        });

        try writeTextFileList(writer, "Modified Files (!)", &collector, &collector.modified);
        try writeTextFileList(writer, "Untracked Files (?)", &collector, &collector.untracked);
        try writeTextFileList(writer, "Deleted Files (✘)", &collector, &collector.deleted);
        try writeTextFileList(writer, "Renamed Files (»)", &collector, &collector.renamed);
        try writeTextFileList(writer, "Conflicted Files (=)", &collector, &collector.conflicted);

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
