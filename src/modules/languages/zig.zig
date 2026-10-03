const std = @import("std");
const module = @import("../module.zig");

pub const ZigLangModule = module.GenericLanguageModule(.{
    .name = "zig_lang",
    .symbol = "↯ ",
    .style = "bold yellow",
    .extensions = &.{ ".zig", ".zon" },
    .files = &.{ "build.zig", "build.zig.zon" },
});

pub const Config = ZigLangModule.Config;
pub const ZigLangConfig = Config;
pub const render = ZigLangModule.render;
pub const buffer_size = ZigLangModule.buffer_size;
pub const debug = ZigLangModule.debug;

pub const Harness = @import("../../tests/harness.zig").Harness;

test "integration: zig_lang renders symbol when build.zig is present" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.writeFile("build.zig", "const std = @import(\"std\");\n");
    try h.setConfig(
        \\format = "$zig_lang"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectContains(out, "↯");
}

test "integration: zig_lang renders symbol when .zig file is present" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.writeFile("main.zig", "pub fn main() void {}\n");
    try h.setConfig(
        \\format = "$zig_lang"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectContains(out, "↯");
}

test "integration: zig_lang renders nothing when no zig files are present" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.writeFile("other.txt", "hello");
    try h.setConfig(
        \\format = "$zig_lang"
        \\add_newline = false
    );

    const out = try h.collect(.generic);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "integration: zig_lang custom symbol and style" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.writeFile("build.zig", "");
    try h.setConfig(
        \\format = "$zig_lang"
        \\add_newline = false
        \\
        \\[zig_lang]
        \\symbol = "ZIG "
        \\style = "bold cyan"
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "ZIG");
}

test "integration: zig_lang renders symbol in nested subdirectory when build.zig is in project root" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("build.zig", "const std = @import(\"std\");\n");
    _ = try h.setCwd("nested/docs/markdown");
    try h.writeFile("nested/docs/markdown/readme.txt", "doc");

    try h.setConfig(
        \\format = "$zig_lang"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectContains(out, "↯");
}

test "integration: zig_lang traverses multiple levels up to git root" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("build.zig", "const std = @import(\"std\");\n");
    _ = try h.setCwd("a/b/c/d/e/f");
    try h.writeFile("a/b/c/d/e/f/note.txt", "deep note");

    try h.setConfig(
        \\format = "$zig_lang"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectContains(out, "↯");
}

test "integration: zig_lang disabled in config renders nothing" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.writeFile("build.zig", "");
    try h.setConfig(
        \\format = "$zig_lang"
        \\add_newline = false
        \\
        \\[zig_lang]
        \\disabled = true
    );

    const out = try h.collect(.generic);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "integration: zig_lang in git worktree" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    const worktree_path = try std.fmt.allocPrint(h.arena.allocator(), "{s}/wt", .{h.tmp_dir});
    try h.git(&.{ "worktree", "add", "-b", "wt-branch", worktree_path });
    try h.writeFile("wt/build.zig", "const std = @import(\"std\");\n");
    _ = try h.setCwd("wt/sub/nested");
    try h.writeFile("wt/sub/nested/file.txt", "content");

    try h.setConfig(
        \\format = "$zig_lang"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectContains(out, "↯");
}

test "unit: zig_lang satisfies module contract" {
    comptime module.validateModule(ZigLangModule);
}


