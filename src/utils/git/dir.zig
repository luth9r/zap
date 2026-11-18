const std = @import("std");
const platform = @import("../platform.zig");
const fs = @import("../fs.zig");

/// Parses a .git pointer file (common in git worktrees and submodules) with format "gitdir: <path>".
pub fn parseGitDirPointer(content_raw: []const u8) ?[]const u8 {
    const content = std.mem.trim(u8, content_raw, " \t\r\n");
    if (std.mem.startsWith(u8, content, "gitdir:")) {
        return std.mem.trim(u8, content["gitdir:".len..], " \t\r\n");
    }
    return null;
}

const GitEntryKind = enum { dir, file };

fn detectGitEntry(io: std.Io, git_path: []const u8) ?GitEntryKind {
    if (fs.dirExists(io, git_path)) {
        return .dir;
    }
    if (fs.fileExists(io, git_path)) {
        return .file;
    }
    return null;
}

const GitAncestorMatch = struct {
    repo_root: []const u8,
    git_path: []const u8,
    kind: GitEntryKind,
};

fn findDotGitInAncestors(
    io: std.Io,
    cwd: []const u8,
    git_path_buf: *[std.fs.max_path_bytes]u8,
) ?GitAncestorMatch {
    var current: []const u8 = cwd;

    while (current.len > 0) {
        const git_path = platform.joinPath(git_path_buf, current, ".git") orelse return null;

        if (detectGitEntry(io, git_path)) |kind| {
            return .{
                .repo_root = current,
                .git_path = git_path,
                .kind = kind,
            };
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        current = parent;
    }

    return null;
}

/// Locates the .git directory or gitdir pointer by searching the current directory and its ancestors.
pub fn findGitDir(
    io: std.Io,
    cwd: []const u8,
    out_buf: *[std.fs.max_path_bytes]u8,
) ?[]const u8 {
    const match = findDotGitInAncestors(io, cwd, out_buf) orelse return null;
    switch (match.kind) {
        .dir => return match.git_path,
        .file => {
            var content_buf: [512]u8 = undefined;
            const content = fs.readSmallFile(io, match.git_path, &content_buf) orelse return null;
            const target_gitdir = parseGitDirPointer(content) orelse return null;
            if (std.fs.path.isAbsolute(target_gitdir)) {
                return std.fmt.bufPrint(out_buf, "{s}", .{target_gitdir}) catch null;
            }
            return std.fmt.bufPrint(out_buf, "{s}/{s}", .{ match.repo_root, target_gitdir }) catch null;
        },
    }
}

/// Locates the repository root directory by searching the current directory and its ancestors for .git.
pub fn findRepoRoot(
    io: std.Io,
    cwd: []const u8,
    out_buf: *[std.fs.max_path_bytes]u8,
) ?[]const u8 {
    var git_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const match = findDotGitInAncestors(io, cwd, &git_path_buf) orelse return null;
    return std.fmt.bufPrint(out_buf, "{s}", .{match.repo_root}) catch null;
}

const worktree_markers = [_][]const u8{
    "/.git/worktrees/",
    "\\.git\\worktrees\\",
    "\\.git/worktrees/",
};

const module_markers = [_][]const u8{
    "/.git/modules/",
    "\\.git\\modules\\",
    "\\.git/modules/",
};

/// Returns the shared common `.git` directory for a repository or linked worktree.
pub fn gitDirToCommonDir(git_dir: []const u8) []const u8 {
    for (worktree_markers) |marker| {
        if (std.mem.indexOf(u8, git_dir, marker)) |wt_idx| {
            return git_dir[0 .. wt_idx + "/.git".len];
        }
    }
    return git_dir;
}

/// Extracts repository root from a known git_dir path without filesystem I/O.
pub fn gitDirToRepoRoot(git_dir: []const u8) []const u8 {
    if (std.mem.endsWith(u8, git_dir, "/.git") or std.mem.endsWith(u8, git_dir, "\\.git")) {
        return git_dir[0 .. git_dir.len - "/.git".len];
    }
    for (worktree_markers) |marker| {
        if (std.mem.indexOf(u8, git_dir, marker)) |wt_idx| {
            return git_dir[0..wt_idx];
        }
    }
    for (module_markers) |marker| {
        if (std.mem.indexOf(u8, git_dir, marker)) |mod_idx| {
            return git_dir[0..mod_idx];
        }
    }
    return std.fs.path.dirname(git_dir) orelse git_dir;
}

/// Resolves the active working tree root for a repository, linked worktree, or submodule.
pub fn resolveRepoRoot(
    io: std.Io,
    cwd: []const u8,
    git_dir: []const u8,
    out_buf: *[std.fs.max_path_bytes]u8,
) []const u8 {
    for (worktree_markers) |marker| {
        if (std.mem.indexOf(u8, git_dir, marker) != null) {
            var gitdir_file_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (platform.joinPath(&gitdir_file_buf, git_dir, "gitdir")) |gitdir_file| {
                if (fs.readSmallFile(io, gitdir_file, out_buf)) |dot_git_path| {
                    if (std.fs.path.isAbsolute(dot_git_path)) {
                        if (std.fs.path.dirname(dot_git_path)) |wt_root| {
                            return wt_root;
                        }
                    }
                }
            }
            if (cwd.len > 0) {
                if (findRepoRoot(io, cwd, out_buf)) |wt_root| return wt_root;
            }
            break;
        }
    }

    for (module_markers) |marker| {
        if (std.mem.indexOf(u8, git_dir, marker) != null) {
            if (cwd.len > 0) {
                if (findRepoRoot(io, cwd, out_buf)) |sub_root| return sub_root;
            }
            break;
        }
    }

    const static_root = gitDirToRepoRoot(git_dir);
    if (cwd.len > 0 and !platform.pathIsSubpath(cwd, static_root)) {
        if (findRepoRoot(io, cwd, out_buf)) |found_root| return found_root;
    }
    return static_root;
}

test "unit: parseGitDirPointer parses valid and invalid pointers" {
    try std.testing.expectEqualStrings(
        "/path/to/.git/worktrees/wt",
        parseGitDirPointer("gitdir: /path/to/.git/worktrees/wt\n").?,
    );
    try std.testing.expect(parseGitDirPointer("not a gitdir pointer") == null);
}

test "unit: gitDirToRepoRoot and gitDirToCommonDir extract paths" {
    try std.testing.expectEqualStrings("/home/user/zap", gitDirToRepoRoot("/home/user/zap/.git"));
    try std.testing.expectEqualStrings("/home/user/zap", gitDirToRepoRoot("/home/user/zap/.git/worktrees/feature"));
    try std.testing.expectEqualStrings("C:\\Users\\user\\zap", gitDirToRepoRoot("C:\\Users\\user\\zap\\.git"));
    try std.testing.expectEqualStrings("C:\\Users\\user\\zap", gitDirToRepoRoot("C:\\Users\\user\\zap\\.git\\worktrees\\feature"));

    try std.testing.expectEqualStrings("/home/user/zap/.git", gitDirToCommonDir("/home/user/zap/.git"));
    try std.testing.expectEqualStrings("/home/user/zap/.git", gitDirToCommonDir("/home/user/zap/.git/worktrees/feature"));
}
