const std = @import("std");
const formatter = @import("../../engine/formatter.zig");
const path_utils = @import("../../utils/path_utils.zig");

pub const PromptContext = @import("../../engine/context.zig").PromptContext;

pub const buffer_size: usize = std.fs.max_path_bytes + 256;

pub const Var = enum { read_only_style, path, read_only };

pub const DirectoryConfig = struct {
    // Format string used to render the directory module.
    format: []const u8 = "[$path]($style)[$read_only]($read_only_style) ",
    // Style string for the directory path.
    style: []const u8 = "bold cyan",
    // Replacement symbol for the user home directory.
    home_symbol: []const u8 = "~",
    // Symbol shown when the directory is read-only (Nerd Font lock icon).
    read_only: []const u8 = "󰌾",
    // Style string for the read-only symbol.
    read_only_style: []const u8 = "bold red",
    // Number of path components to show (0 = no truncation, default = 3).
    truncation_length: usize = 3,
    // Symbol replacing truncated path elements.
    truncation_symbol: []const u8 = "…/",
    // Whether to truncate path relative to git repository root.
    truncate_to_repo: bool = true,
    // Whether the directory module is disabled.
    disabled: bool = false,
};

pub const Config = DirectoryConfig;

/// Renders the directory module according to the directory configuration.
pub fn render(
    writer: anytype,
    config: DirectoryConfig,
    ctx: PromptContext,
) !void {
    if (config.disabled) return;

    var repo_root_buf: [std.fs.max_path_bytes]u8 = undefined;
    var repo_root: ?[]const u8 = null;

    if (config.truncate_to_repo) {
        const git_dir_opt = ctx.git_dir orelse if (ctx.io) |io_val|
            @import("../../utils/git_utils.zig").findGitDir(io_val, ctx.cwd, &repo_root_buf)
        else
            null;
        if (git_dir_opt) |git_dir| {
            if (std.mem.endsWith(u8, git_dir, "/.git")) {
                repo_root = git_dir[0 .. git_dir.len - "/.git".len];
            } else {
                repo_root = std.fs.path.dirname(git_dir) orelse git_dir;
            }
        }
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_str = path_utils.formatPathTruncatedBuf(
        &path_buf,
        ctx.cwd,
        ctx.home,
        config.home_symbol,
        config.truncation_length,
        config.truncation_symbol,
        repo_root,
    ) orelse ctx.cwd;

    var is_read_only = false;
    if (ctx.io) |io| {
        if (std.Io.Dir.accessAbsolute(io, ctx.cwd, .{ .write = true })) |_| {
            // Write access is granted
        } else |_| {
            is_read_only = true;
        }
    }
    const read_only_val = if (is_read_only) config.read_only else "";

    try formatter.formatTemplateWriter(writer, config.format, formatter.FormatContext(Var){
        .style = config.style,
        .shell = ctx.shell,
        .vars = &.{
            .{ .name = .path, .value = path_str },
            .{ .name = .read_only, .value = read_only_val },
            .{ .name = .read_only_style, .value = config.read_only_style },
        },
    });
}

pub const Harness = @import("../../tests/harness.zig").Harness;

test "integration: directory default path renders home symbol" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setConfig(
        \\format = "$directory"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "~");
}

test "integration: directory custom home symbol and style" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setConfig(
        \\format = "$directory"
        \\add_newline = false
        \\
        \\[directory]
        \\home_symbol = ""
        \\style = "bold yellow"
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "");
}

test "integration: directory truncation length" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    _ = try h.setCwd("a/b/c/d");

    try h.setConfig(
        \\format = "$directory"
        \\add_newline = false
        \\
        \\[directory]
        \\truncation_length = 2
        \\truncation_symbol = "…/"
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "…/c/d");
}

test "integration: directory truncate_to_repo" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    _ = try h.setCwd("src/modules/foo");
    try h.setConfig(
        \\format = "$directory"
        \\add_newline = false
        \\
        \\[directory]
        \\truncate_to_repo = true
        \\truncation_length = 0
    );

    const out = try h.collectAllShells();
    // tmp_dir is something like /tmp/zap-test-XYZ. repo_name is zap-test-XYZ.
    // It should render "zap-test-XYZ/src/modules/foo" instead of "~/..." or "/tmp/..."
    const repo_name = std.fs.path.basename(h.tmp_dir);
    
    var expected_buf: [1024]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "{s}/src/modules/foo", .{repo_name});
    try Harness.expectVisibleText(out, expected);
}

test "integration: directory disabled in config" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setConfig(
        \\format = "$directory"
        \\add_newline = false
        \\
        \\[directory]
        \\disabled = true
    );

    const out = try h.collect(.generic);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "integration: directory at filesystem root" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    _ = try h.setCwd("/");
    try h.setConfig(
        \\format = "$directory"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "/");
}

test "integration: directory outside home renders full or truncated path" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    _ = try h.setHome("fake_home");
    _ = try h.setCwd("other_project/sub");
    try h.setConfig(
        \\format = "$directory"
        \\add_newline = false
        \\
        \\[directory]
        \\truncation_length = 2
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "other_project/sub");
}

test "integration: directory read_only rendering" {
    if (@import("builtin").os.tag == .windows) return; // chmod not supported on windows

    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    _ = try h.setCwd("readonly_dir");
    const io = std.testing.io;
    var child = std.process.spawn(io, .{
        .argv = &[_][]const u8{ "chmod", "555", h.custom_cwd.? },
    }) catch return;
    _ = child.wait(io) catch {};

    try h.setConfig(
        \\format = "$directory"
        \\add_newline = false
        \\
        \\[directory]
        \\read_only = "LOCK"
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "LOCK");
}

