const std = @import("std");

pub const HOOK_TEMPLATE = "{s} init fish | source";

pub const SCRIPT =
    \\# Zap prompt integration for Fish
    \\
    \\function fish_prompt
    \\    set -l last_status $status
    \\    set -l duration "$CMD_DURATION"
    \\    if test -z "$duration"
    \\        set duration 0
    \\    end
    \\    "{{EXE}}" prompt --status "$last_status" --duration "$duration" --shell fish
    \\end
    \\
;

const testing = std.testing;
const init_mod = @import("root.zig");
const prompt = @import("../engine/prompt.zig");
const config_mod = @import("../config/config.zig");
const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;
const Harness = @import("../tests/harness.zig").Harness;

test "unit: init fish script generation" {
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    try init_mod.renderInitScript(writer, .fish, "zap");
    const script = buf[0..pos];

    try testing.expect(std.mem.indexOf(u8, script, "function fish_prompt") != null);
    try testing.expect(std.mem.indexOf(u8, script, "\"zap\" prompt --status \"$last_status\"") != null);
    try testing.expect(std.mem.indexOf(u8, script, "{{EXE}}") == null);
}

test "unit: prompt render with fish raw escapes" {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    var cfg = config_mod.defaultConfig();
    cfg.add_newline = false;

    try prompt.render(writer, cfg, .{
        .cwd = "/home/user/zap",
        .home = "/home/user",
        .status_code = 0,
        .shell = .fish,
    });

    const rendered = buf[0..pos];
    // Must not contain bash markers \x01 or \x02, nor zsh %{ / %}
    try testing.expect(std.mem.indexOfScalar(u8, rendered, '\x01') == null);
    try testing.expect(std.mem.indexOfScalar(u8, rendered, '\x02') == null);
    try testing.expect(std.mem.indexOf(u8, rendered, "%{") == null);
    try testing.expect(std.mem.indexOf(u8, rendered, "%}") == null);
}

test "integration: real fish session with auto-installed zap hook and config" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.git(&.{ "checkout", "-b", "fish-branch" });

    try h.writeFile(".config/zap/zap.toml",
        \\format = "$directory$git_branch$character"
        \\add_newline = false
    );

    const install_res = try h.execZapAllowFail(&.{ "init", "fish", "--install" });
    try testing.expectEqual(@as(u8, 0), install_res.exit_code);

    const alloc = h.arena.allocator();
    const cmd = try std.fmt.allocPrint(alloc, "source \"{s}/.config/fish/config.fish\"; fish_prompt", .{h.tmp_dir});

    const home_env = try std.fmt.allocPrint(alloc, "HOME={s}", .{h.tmp_dir});
    const xdg_env = try std.fmt.allocPrint(alloc, "XDG_CONFIG_HOME={s}/.config", .{h.tmp_dir});
    const argv = [_][]const u8{
        "env",
        home_env,
        xdg_env,
        "fish",
        "--no-config",
        "-c",
        cmd,
    };

    var child = std.process.spawn(std.testing.io, .{
        .argv = &argv,
        .cwd = .{ .path = h.tmp_dir },
        .stdout = .pipe,
        .stderr = .pipe,
        .stdin = .ignore,
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };

    var stream_buf: [512]u8 = undefined;
    var reader = child.stdout.?.reader(std.testing.io, &stream_buf);
    var out_buf: [4096]u8 = undefined;
    const n = try reader.interface.readSliceShort(&out_buf);
    _ = try child.wait(std.testing.io);

    const fish_prompt_out = out_buf[0..n];
    try Harness.expectContains(fish_prompt_out, "fish-branch");
    try Harness.expectContains(fish_prompt_out, "❯");
    try Harness.expectAnsi(fish_prompt_out, .fish);
}
