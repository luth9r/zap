const std = @import("std");

pub const HOOK_TEMPLATE = "{s} init fish | source";

pub const SCRIPT =
    \\# Zap prompt integration for Fish
    \\
    \\set -g __zap_first_prompt 1
    \\
    \\function __zap_postexec --on-event fish_postexec
    \\    if string match -qr '^(clear|cls|reset)(\s|$)' -- "$argv[1]"
    \\        set -g __zap_first_prompt 1
    \\    end
    \\end
    \\
    \\function fish_prompt
    \\    set -l last_status $status
    \\    set -l duration "$CMD_DURATION"
    \\    if test -z "$duration"
    \\        set duration 0
    \\    end
    \\    if test "$__zap_first_prompt" = "1"
    \\        set -g __zap_first_prompt 0
    \\        "{{EXE}}" prompt --status "$last_status" --duration "$duration" --shell fish --no-newline
    \\    else
    \\        "{{EXE}}" prompt --status "$last_status" --duration "$duration" --shell fish
    \\    end
    \\end
    \\
    \\function fish_right_prompt
    \\    set -l last_status $status
    \\    set -l duration "$CMD_DURATION"
    \\    if test -z "$duration"
    \\        set duration 0
    \\    end
    \\    "{{EXE}}" prompt --right --status "$last_status" --duration "$duration" --shell fish
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

    const cmd = try std.fmt.allocPrint(h.arena.allocator(), "source \"{s}/.config/fish/config.fish\"; fish_prompt", .{h.tmp_dir});
    const fish_prompt_out = (try h.runShellScript(&.{ "fish", "--no-config", "-c", cmd })) orelse return;
    try Harness.expectContains(fish_prompt_out, "fish-branch");
    try Harness.expectContains(fish_prompt_out, "❯");
    try Harness.expectAnsi(fish_prompt_out, .fish);
}
