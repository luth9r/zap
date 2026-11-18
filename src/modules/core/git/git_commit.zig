const std = @import("std");
const formatter = @import("../../../engine/formatter.zig");
const git_utils = @import("../../../utils/git_utils.zig");
const parse_utils = @import("../../../utils/parse_utils.zig");

pub const PromptContext = @import("../../../engine/context.zig").PromptContext;
pub const DebugContext = @import("../../../engine/context.zig").DebugContext;

pub const is_git_dependent: bool = true;

pub const Var = enum { hash, tag };

pub const GitCommitConfig = struct {
    // Format template for the git_commit module.
    format: []const u8 = "[\\($hash$tag\\)]($style) ",
    // Style string for the commit hash and tag.
    style: []const u8 = "bold green",
    // Number of characters to display from the commit hash (0 = full SHA).
    commit_hash_length: usize = 7,
    // Only display git_commit when HEAD is detached.
    only_detached: bool = true,
    // Symbol preceding tag name.
    tag_symbol: []const u8 = "  ",
    // Whether to disable tag display.
    tag_disabled: bool = true,
    // Whether the git_commit module is disabled.
    disabled: bool = false,
};

pub const Config = GitCommitConfig;

/// Renders the git_commit module according to configuration.
pub fn render(
    writer: anytype,
    config: GitCommitConfig,
    ctx: PromptContext,
) !void {
    if (config.disabled) return;
    const io = ctx.io orelse return;

    var git_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_dir = ctx.getGitDir(io, &git_dir_buf) orelse return;

    var oid_buf: [64]u8 = undefined;
    var tag_name_buf: [128]u8 = undefined;
    const commit_info = git_utils.resolveCommit(
        io,
        ctx.cwd,
        git_dir,
        ctx.git_status,
        !config.tag_disabled,
        config.only_detached,
        &oid_buf,
        &tag_name_buf,
    ) orelse return;

    if (config.only_detached and !commit_info.is_detached) return;
    if (commit_info.hash.len == 0) return;

    var short_hash = commit_info.hash;
    const hash_len = config.commit_hash_length;
    if (hash_len > 0 and short_hash.len > hash_len) {
        short_hash = short_hash[0..hash_len];
    }

    var tag_buf: [256]u8 = undefined;
    var tag_str: []const u8 = "";
    if (!config.tag_disabled and commit_info.tag.len > 0) {
        tag_str = std.fmt.bufPrint(&tag_buf, "{s}{s}", .{ config.tag_symbol, commit_info.tag }) catch "";
    }

    try formatter.formatTemplateWriter(writer, config.format, formatter.FormatContext(Var){
        .style = config.style,
        .shell = ctx.shell,
        .vars = &.{
            .{ .name = .hash, .value = short_hash },
            .{ .name = .tag, .value = tag_str, .escape_shell = true },
        },
    });
}

pub fn debug(writer: anytype, dctx: DebugContext) !void {
    const io = dctx.prompt.io orelse return;

    var git_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_dir_opt = dctx.prompt.getGitDir(io, &git_dir_buf);

    if (git_dir_opt == null) {
        try git_utils.writeNotInGitRepo(writer, dctx.json, "git_commit");
        return;
    }

    const git_dir = git_dir_opt.?;
    var oid_buf: [64]u8 = undefined;
    var tag_buf: [128]u8 = undefined;
    const commit_info = git_utils.resolveCommit(io, dctx.prompt.cwd, git_dir, dctx.prompt.git_status, true, false, &oid_buf, &tag_buf);

    if (commit_info) |c| {
        if (dctx.json) {
            var j_tag: [256]u8 = undefined;
            try writer.print(
                \\{{ "module": "git_commit", "hash": "{s}", "tag": "{s}", "is_detached": {} }}
                \\
            , .{ c.hash, parse_utils.escapeJsonBuf(&j_tag, c.tag), c.is_detached });
        } else {
            try writer.print(
                \\⚡ Module: git_commit
                \\  Commit Hash: {s}
                \\  Tag:         {s}
                \\  Detached:    {}
                \\
            , .{ c.hash, if (c.tag.len > 0) c.tag else "none", c.is_detached });
        }
    } else {
        if (dctx.json) {
            try writer.writeAll("{\"module\": \"git_commit\", \"hash\": null}\n");
        } else {
            try writer.writeAll("⚡ Module: git_commit\n  Commit Hash: none\n\n");
        }
    }
}

const Harness = @import("../../../tests/harness.zig").Harness;

test "integration: git_commit hidden on normal branch by default" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.setConfig(
        \\format = "$git_commit"
        \\add_newline = false
    );

    const out = try h.collect(.generic);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "integration: git_commit in detached head state renders hash" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("file.txt", "content");
    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "initial commit" });
    try h.git(&.{ "checkout", "--detach", "HEAD" });
    try h.setConfig(
        \\format = "$git_commit"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectNotEmpty(out);
    try Harness.expectVisibleText(out, "(");
    try Harness.expectVisibleText(out, ")");
}

test "integration: git_commit custom hash length" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("file.txt", "content");
    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "initial commit" });
    try h.git(&.{ "checkout", "--detach", "HEAD" });
    try h.setConfig(
        \\format = "$git_commit"
        \\add_newline = false
        \\
        \\[git_commit]
        \\commit_hash_length = 5
    );

    const out = try h.collectAllShells();

    var oid_buf: [64]u8 = undefined;
    var tag_buf: [128]u8 = undefined;
    const commit = git_utils.resolveCommit(std.testing.io, h.tmp_dir, h.tmp_dir, null, false, false, &oid_buf, &tag_buf) orelse return error.MissingHead;
    const sha = commit.hash;

    try Harness.expectVisibleText(out, sha[0..5]);
    try Harness.expectVisibleText(out, "(");
    try Harness.expectVisibleText(out, ")");
}

test "integration: git_commit full hash length (0)" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("file.txt", "content");
    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "initial commit" });
    try h.git(&.{ "checkout", "--detach", "HEAD" });
    try h.setConfig(
        \\format = "$git_commit"
        \\add_newline = false
        \\
        \\[git_commit]
        \\commit_hash_length = 0
    );

    const out = try h.collectAllShells();

    var oid_buf: [64]u8 = undefined;
    var tag_buf: [128]u8 = undefined;
    const commit = git_utils.resolveCommit(std.testing.io, h.tmp_dir, h.tmp_dir, null, false, false, &oid_buf, &tag_buf) orelse return error.MissingHead;
    const sha = commit.hash;

    try Harness.expectVisibleText(out, sha);
}

test "integration: git_commit disabled in config" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.git(&.{ "checkout", "--detach", "HEAD" });
    try h.setConfig(
        \\format = "$git_commit"
        \\add_newline = false
        \\
        \\[git_commit]
        \\disabled = true
    );

    const out = try h.collect(.generic);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "integration: git_commit only_detached = false shows hash on normal branch" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("file.txt", "content");
    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "initial commit" });
    try h.setConfig(
        \\format = "$git_commit"
        \\add_newline = false
        \\
        \\[git_commit]
        \\only_detached = false
    );

    const out = try h.collectAllShells();
    try Harness.expectNotEmpty(out);
    try Harness.expectVisibleText(out, "(");
    try Harness.expectVisibleText(out, ")");
}

test "integration: git_commit tag_disabled = false shows tag" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("file.txt", "content");
    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "initial commit" });
    try h.git(&.{ "tag", "v1.0.0" });
    try h.git(&.{ "checkout", "--detach", "HEAD" });
    try h.setConfig(
        \\format = "$git_commit"
        \\add_newline = false
        \\
        \\[git_commit]
        \\tag_disabled = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "v1.0.0");
    try Harness.expectVisibleText(out, "");
}

test "integration: git_commit in git worktree resolves tag from common git dir" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("file.txt", "content");
    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "tagged commit" });
    try h.git(&.{ "tag", "v2.5.0" });

    const wt_path = try std.fmt.allocPrint(h.arena.allocator(), "{s}/wt", .{h.tmp_dir});
    try h.git(&.{ "worktree", "add", "--detach", wt_path, "HEAD" });
    _ = try h.setCwd("wt");

    try h.setConfig(
        \\format = "$git_branch$git_commit"
        \\add_newline = false
        \\
        \\[git_commit]
        \\tag_disabled = false
    );

    const out = try h.collect(.generic);
    try Harness.expectVisibleText(out, "v2.5.0");
    try Harness.expectNotContains(out, "on ");
}
