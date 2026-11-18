const std = @import("std");

pub const dir = @import("dir.zig");
pub const refs = @import("refs.zig");
pub const state = @import("state.zig");
pub const details = @import("details.zig");

pub const GitHeadInfo = struct {
    branch_buf: [256]u8 = undefined,
    branch_len: u16 = 0,
    oid_buf: [64]u8 = undefined,
    oid_len: u8 = 0,
    upstream_buf: [256]u8 = undefined,
    upstream_len: u16 = 0,
    is_detached: bool = false,

    pub fn getBranch(self: *const GitHeadInfo) ?[]const u8 {
        if (self.is_detached) return null;
        if (self.branch_len > 0) return self.branch_buf[0..self.branch_len];
        return null;
    }

    pub fn getOid(self: *const GitHeadInfo) []const u8 {
        return self.oid_buf[0..self.oid_len];
    }

    pub fn getRemoteBranch(self: *const GitHeadInfo) []const u8 {
        if (self.upstream_len == 0) return "";
        const up = self.upstream_buf[0..self.upstream_len];
        if (std.mem.indexOfScalar(u8, up, '/')) |slash_idx| {
            return up[slash_idx + 1 ..];
        }
        return up;
    }
};

// Status flags and info
pub const GitStatusInfo = struct {
    staged: bool = false,
    modified: bool = false,
    untracked: bool = false,
    deleted: bool = false,
    renamed: bool = false,
    stashed: bool = false,
    conflicted: bool = false,
    ahead: usize = 0,
    behind: usize = 0,
    head: GitHeadInfo = .{},

    pub fn hasAnyStatus(self: GitStatusInfo) bool {
        inline for (@typeInfo(GitStatusInfo).@"struct".fields) |field| {
            if (field.type == bool) {
                if (@field(self, field.name)) return true;
            } else if (field.type == usize or field.type == u64 or field.type == u32) {
                if (@field(self, field.name) > 0) return true;
            }
        }
        return false;
    }
};

// Re-export common types
pub const GitCommitResult = refs.GitCommitResult;
pub const GitStateType = state.GitStateType;
pub const GitStateResult = state.GitStateResult;

// Re-export standalone utility functions
pub const findGitDir = dir.findGitDir;
pub const findRepoRoot = dir.findRepoRoot;
pub const gitDirToRepoRoot = dir.gitDirToRepoRoot;
pub const gitDirToCommonDir = dir.gitDirToCommonDir;
pub const resolveRepoRoot = dir.resolveRepoRoot;
pub const parseGitDirPointer = dir.parseGitDirPointer;

pub const findTagForHash = refs.findTagForHash;

pub const getGitState = state.getGitState;

pub const GitFileCollector = details.GitFileCollector;
pub const collectDetailedGitFiles = details.collectDetailedGitFiles;

pub fn writeNotInGitRepo(writer: anytype, json: bool, module_name: []const u8) !void {
    if (json) {
        try writer.print("{{\"module\": \"{s}\", \"in_git_repo\": false}}\n", .{module_name});
    } else {
        try writer.print("⚡ Module: {s}\n  In Git Repo: false\n\n", .{module_name});
    }
}

/// Resolves the current branch name strictly from `git status` (no `.git/HEAD` fallback).
pub fn resolveBranch(
    io: std.Io,
    cwd: []const u8,
    git_dir: []const u8,
    cached_status: ?*const GitStatusInfo,
    out_buf: *[256]u8,
) ?[]const u8 {
    if (cached_status) |st| {
        return st.head.getBranch();
    }
    const st = getGitStatusForDir(io, cwd, git_dir);
    const branch = st.head.getBranch() orelse return null;
    const n = copyToBuf(out_buf, branch);
    return out_buf[0..n];
}

/// Resolves the current commit hash/tag/detached state strictly from `git status` (no `.git/HEAD` fallback).
pub fn resolveCommit(
    io: std.Io,
    cwd: []const u8,
    git_dir: []const u8,
    cached_status: ?*const GitStatusInfo,
    include_tag: bool,
    only_detached: bool,
    oid_buf: *[64]u8,
    tag_buf: *[128]u8,
) ?GitCommitResult {
    var local_st: GitStatusInfo = undefined;
    const st: *const GitStatusInfo = cached_status orelse blk: {
        local_st = getGitStatusForDir(io, cwd, git_dir);
        break :blk &local_st;
    };

    if (only_detached and !st.head.is_detached) {
        return .{ .hash = "", .tag = "", .is_detached = false };
    }

    const oid = st.head.getOid();
    if (oid.len == 0) return null;

    const hash = if (cached_status != null) oid else blk: {
        const n = copyToBuf(oid_buf, oid);
        break :blk oid_buf[0..n];
    };
    const tag = if (include_tag)
        refs.findTagForHash(io, git_dir, hash, tag_buf) orelse ""
    else
        "";

    return .{ .hash = hash, .tag = tag, .is_detached = st.head.is_detached };
}

/// Reads the tracked entry count from the 12-byte `.git/index` header (`DIRC`) with zero subprocesses.
pub fn getIndexEntryCount(io: std.Io, git_dir: []const u8) u32 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const index_path = std.fmt.bufPrint(&path_buf, "{s}/index", .{git_dir}) catch return 0;

    var header_buf: [12]u8 = undefined;
    const raw = @import("../fs.zig").readFileRaw(io, index_path, &header_buf) orelse return 0;
    if (raw.len < 12 or !std.mem.eql(u8, raw[0..4], "DIRC")) return 0;

    return std.mem.readInt(u32, raw[8..12], .big);
}

fn skipSpaceFields(line: []const u8, count: usize) ?[]const u8 {
    var spaces: usize = 0;
    for (line, 0..) |c, idx| {
        if (c == ' ') {
            spaces += 1;
            if (spaces == count) {
                if (idx + 1 < line.len) return line[idx + 1 ..];
                return null;
            }
        }
    }
    return null;
}

const PorcelainHeader = enum {
    @"branch.oid",
    @"branch.head",
    @"branch.upstream",
    @"branch.ab",
    stash,
};

const header_map = std.StaticStringMap(PorcelainHeader).initComptime(.{
    .{ "branch.oid", .@"branch.oid" },
    .{ "branch.head", .@"branch.head" },
    .{ "branch.upstream", .@"branch.upstream" },
    .{ "branch.ab", .@"branch.ab" },
    .{ "stash", .stash },
});

fn copyToBuf(dest: []u8, src: []const u8) u16 {
    const n = @min(src.len, dest.len);
    @memcpy(dest[0..n], src[0..n]);
    return @intCast(n);
}

fn parsePorcelainHeader(line: []const u8, info: *GitStatusInfo) void {
    if (!std.mem.startsWith(u8, line, "# ")) return;
    const rest = line[2..];
    const space_idx = std.mem.indexOfScalar(u8, rest, ' ') orelse return;
    const key = rest[0..space_idx];
    const val = std.mem.trim(u8, rest[space_idx + 1 ..], " \t");

    const header = header_map.get(key) orelse return;
    switch (header) {
        .@"branch.oid" => {
            if (!std.mem.eql(u8, val, "(initial)")) {
                info.head.oid_len = @intCast(copyToBuf(&info.head.oid_buf, val));
            }
        },
        .@"branch.head" => {
            if (std.mem.eql(u8, val, "(detached)")) {
                info.head.is_detached = true;
            } else if (!std.mem.eql(u8, val, "(unknown)")) {
                info.head.is_detached = false;
                info.head.branch_len = copyToBuf(&info.head.branch_buf, val);
            }
        },
        .@"branch.upstream" => {
            info.head.upstream_len = copyToBuf(&info.head.upstream_buf, val);
        },
        .@"branch.ab" => {
            var it = std.mem.splitScalar(u8, val, ' ');
            while (it.next()) |tok| {
                if (tok.len <= 1) continue;
                switch (tok[0]) {
                    '+' => info.ahead = std.fmt.parseInt(usize, tok[1..], 10) catch 0,
                    '-' => info.behind = std.fmt.parseInt(usize, tok[1..], 10) catch 0,
                    else => {},
                }
            }
        },
        .stash => {
            const count = std.fmt.parseInt(usize, val, 10) catch 0;
            if (count > 0) info.stashed = true;
        },
    }
}

fn extractTrackedPath(line: []const u8, is_rename: bool) ?[]const u8 {
    const spaces: usize = if (is_rename) 9 else 8;
    const rest = skipSpaceFields(line, spaces) orelse return null;
    const tab_idx = std.mem.indexOfScalar(u8, rest, '\t') orelse rest.len;
    return rest[0..tab_idx];
}

/// Parses a single line of `git status --porcelain=v2 --branch --show-stash` output.
pub fn parsePorcelainV2Line(
    raw_line: []const u8,
    info: *GitStatusInfo,
    collector: ?*details.GitFileCollector,
) void {
    const line = std.mem.trimEnd(u8, raw_line, "\r\n");
    if (line.len < 2) return;

    switch (line[0]) {
        '#' => parsePorcelainHeader(line, info),
        '1', '2' => {
            if (line.len < 4 or line[1] != ' ') return;
            const is_rename = line[0] == '2' or line[2] == 'R';
            const tracked_path = if (collector != null) extractTrackedPath(line, line[0] == '2') else null;

            if (is_rename) {
                info.renamed = true;
                if (collector) |col| {
                    if (tracked_path) |path| col.addRenamed(path);
                }
            } else if (line[2] != '.') {
                info.staged = true;
                if (collector) |col| {
                    if (tracked_path) |path| col.addStaged(path);
                }
            }

            switch (line[3]) {
                'M', 'T', 'A' => {
                    info.modified = true;
                    if (collector) |col| {
                        if (tracked_path) |path| col.addModified(path);
                    }
                },
                'D' => {
                    info.deleted = true;
                    if (collector) |col| {
                        if (tracked_path) |path| col.addDeleted(path);
                    }
                },
                else => {},
            }
        },
        'u' => {
            if (line.len < 4 or line[1] != ' ') return;
            info.conflicted = true;
            if (collector) |col| {
                if (skipSpaceFields(line, 10)) |path| col.addConflicted(path);
            }
        },
        '?' => {
            if (line[1] != ' ') return;
            info.untracked = true;
            if (collector) |col| {
                if (line.len > 2) col.addUntracked(line[2..]);
            }
        },
        else => {},
    }
}

/// Spawns `git status --porcelain=v2 --branch --show-stash` and streams its output on the stack.
pub fn runGitStatusPorcelain(
    io: std.Io,
    work_dir: []const u8,
    untracked_all: bool,
    info: *GitStatusInfo,
    collector: ?*details.GitFileCollector,
) bool {
    const argv_buf = [_][]const u8{
        "git",
        "-C",
        work_dir,
        "--no-optional-locks",
        "-c",
        "core.fsmonitor=false",
        "status",
        "--porcelain=v2",
        "--branch",
        "--show-stash",
        "--untracked-files=all",
    };
    const argv = if (untracked_all) argv_buf[0..11] else argv_buf[0..10];

    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdout = .pipe,
        .stderr = .ignore,
        .stdin = .ignore,
    }) catch return false;

    var stream_buf: [1024]u8 = undefined;
    var reader = child.stdout.?.reader(io, &stream_buf);

    var line_buf: [2048]u8 = undefined;
    var line_len: usize = 0;
    var chunk_buf: [4096]u8 = undefined;

    while (true) {
        const n = reader.interface.readSliceShort(&chunk_buf) catch break;
        if (n == 0) break;

        for (chunk_buf[0..n]) |b| {
            if (b == '\n') {
                parsePorcelainV2Line(line_buf[0..line_len], info, collector);
                line_len = 0;
            } else if (line_len < line_buf.len) {
                line_buf[line_len] = b;
                line_len += 1;
            }
        }
    }
    if (line_len > 0) {
        parsePorcelainV2Line(line_buf[0..line_len], info, collector);
    }

    const term = child.wait(io) catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Retrieves git status info for the repository by invoking git child process.
pub fn getGitStatus(io: std.Io, git_dir: []const u8) GitStatusInfo {
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const work_dir = dir.resolveRepoRoot(io, "", git_dir, &root_buf);
    return getGitStatusForDir(io, work_dir, git_dir);
}

/// Computes git status using `git status --porcelain=v2 --branch --show-stash` with zero heap allocations.
pub fn getGitStatusForDir(
    io: std.Io,
    work_dir: []const u8,
    git_dir_opt: ?[]const u8,
) GitStatusInfo {
    var info = GitStatusInfo{};

    var git_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = git_dir_opt orelse findGitDir(io, work_dir, &git_dir_buf) orelse return info;

    if (!runGitStatusPorcelain(io, work_dir, false, &info, null)) {
        return .{};
    }

    return info;
}

test "unit: parsePorcelainV2Line parses branch metadata, ahead/behind, stash, and file statuses" {
    var info = GitStatusInfo{};
    var collector = details.GitFileCollector{};

    parsePorcelainV2Line("# branch.oid 4cd65cc6c714604db0f7a6f6df0b6b66a7620ce0", &info, &collector);
    parsePorcelainV2Line("# branch.head main", &info, &collector);
    parsePorcelainV2Line("# branch.upstream origin/main", &info, &collector);
    parsePorcelainV2Line("# branch.ab +2 -4", &info, &collector);
    parsePorcelainV2Line("# stash 1", &info, &collector);
    parsePorcelainV2Line("1 M. N... 100644 100644 100644 1111111 2222222 src/staged.zig", &info, &collector);
    parsePorcelainV2Line("2 R. N... 100644 100644 100644 1111111 2222222 R100 src/renamed.zig\tsrc/old.zig", &info, &collector);
    parsePorcelainV2Line("1 .M N... 100644 100644 100644 1111111 2222222 src/modified.zig", &info, &collector);
    parsePorcelainV2Line("1 .D N... 100644 100644 000000 1111111 0000000 src/deleted.zig", &info, &collector);
    parsePorcelainV2Line("u UU N... 100644 100644 100644 100644 1111111 2222222 3333333 src/conflict.zig", &info, &collector);
    parsePorcelainV2Line("? src/untracked.zig", &info, &collector);

    try std.testing.expectEqualStrings("main", info.head.getBranch().?);
    try std.testing.expectEqualStrings("4cd65cc6c714604db0f7a6f6df0b6b66a7620ce0", info.head.getOid());
    try std.testing.expectEqualStrings("main", info.head.getRemoteBranch());
    try std.testing.expect(!info.head.is_detached);
    try std.testing.expectEqual(@as(usize, 2), info.ahead);
    try std.testing.expectEqual(@as(usize, 4), info.behind);
    try std.testing.expect(info.stashed);
    try std.testing.expect(info.staged);
    try std.testing.expect(info.renamed);
    try std.testing.expect(info.modified);
    try std.testing.expect(info.deleted);
    try std.testing.expect(info.conflicted);
    try std.testing.expect(info.untracked);

    try std.testing.expectEqual(@as(usize, 1), collector.staged_count);
    try std.testing.expectEqualStrings("src/staged.zig", collector.getStaged(0));
    try std.testing.expectEqual(@as(usize, 1), collector.renamed_count);
    try std.testing.expectEqualStrings("src/renamed.zig", collector.getRenamed(0));

    try std.testing.expectEqual(@as(usize, 1), collector.modified_count);
    try std.testing.expectEqualStrings("src/modified.zig", collector.getModified(0));
    try std.testing.expectEqual(@as(usize, 1), collector.deleted_count);
    try std.testing.expectEqualStrings("src/deleted.zig", collector.getDeleted(0));
    try std.testing.expectEqual(@as(usize, 1), collector.conflicted_count);
    try std.testing.expectEqualStrings("src/conflict.zig", collector.getConflicted(0));
    try std.testing.expectEqual(@as(usize, 1), collector.untracked_count);
    try std.testing.expectEqualStrings("src/untracked.zig", collector.getUntracked(0));
}
