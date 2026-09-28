const std = @import("std");
const testing = std.testing;
const init_mod = @import("../init/root.zig");
const formatter = @import("../engine/formatter.zig");
const prompt = @import("../engine/prompt.zig");
const Config = @import("../config/config.zig").Config;
const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;

test "init bash script generation" {
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    try init_mod.renderInitScript(writer, .bash, "zap");
    const script = buf[0..pos];

    try testing.expect(std.mem.indexOf(u8, script, "PROMPT_COMMAND") != null);
    try testing.expect(std.mem.indexOf(u8, script, "_zap_prompt_command") != null);
    try testing.expect(std.mem.indexOf(u8, script, "\"zap\" prompt --status") != null);
    try testing.expect(std.mem.indexOf(u8, script, "{{EXE}}") == null);
}

test "init zsh script generation" {
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    try init_mod.renderInitScript(writer, .zsh, "zap");
    const script = buf[0..pos];

    try testing.expect(std.mem.indexOf(u8, script, "add-zsh-hook precmd _zap_precmd") != null);
    try testing.expect(std.mem.indexOf(u8, script, "add-zsh-hook preexec _zap_preexec") != null);
    try testing.expect(std.mem.indexOf(u8, script, "\"zap\" prompt --status") != null);
    try testing.expect(std.mem.indexOf(u8, script, "{{EXE}}") == null);
}

test "init fish script generation" {
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    try init_mod.renderInitScript(writer, .fish, "zap");
    const script = buf[0..pos];

    try testing.expect(std.mem.indexOf(u8, script, "function fish_prompt") != null);
    try testing.expect(std.mem.indexOf(u8, script, "\"zap\" prompt --status \"$last_status\"") != null);
    try testing.expect(std.mem.indexOf(u8, script, "{{EXE}}") == null);
}

test "init powershell script generation" {
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    try init_mod.renderInitScript(writer, .powershell, "zap");
    const script = buf[0..pos];

    try testing.expect(std.mem.indexOf(u8, script, "function global:prompt") != null);
    try testing.expect(std.mem.indexOf(u8, script, "$out = & \"zap\" prompt --status $lastExitCodeForPrompt") != null);
    try testing.expect(std.mem.indexOf(u8, script, "{{EXE}}") == null);
}

test "prompt render with bash zero-width escapes" {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    var cfg = Config{};
    cfg.add_newline = false;

    try prompt.render(writer, cfg, .{
        .cwd = "/home/user/zap",
        .home = "/home/user",
        .status_code = 0,
        .shell = .bash,
    });

    const rendered = buf[0..pos];
    // Must contain bash zero-width markers \x01 and \x02
    try testing.expect(std.mem.indexOfScalar(u8, rendered, '\x01') != null);
    try testing.expect(std.mem.indexOfScalar(u8, rendered, '\x02') != null);
    // Must not contain zsh markers %{ or %}
    try testing.expect(std.mem.indexOf(u8, rendered, "%{") == null);
}

test "prompt render with zsh zero-width escapes" {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    var cfg = Config{};
    cfg.add_newline = false;

    try prompt.render(writer, cfg, .{
        .cwd = "/home/user/zap",
        .home = "/home/user",
        .status_code = 0,
        .shell = .zsh,
    });

    const rendered = buf[0..pos];
    // Must contain zsh zero-width markers %{ and %}
    try testing.expect(std.mem.indexOf(u8, rendered, "%{") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "%}") != null);
    // Must not contain bash markers \x01 or \x02
    try testing.expect(std.mem.indexOfScalar(u8, rendered, '\x01') == null);
    try testing.expect(std.mem.indexOfScalar(u8, rendered, '\x02') == null);
}

test "prompt render with fish raw escapes" {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    var cfg = Config{};
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

test "prompt render with powershell raw escapes" {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    var cfg = Config{};
    cfg.add_newline = false;

    try prompt.render(writer, cfg, .{
        .cwd = "/home/user/zap",
        .home = "/home/user",
        .status_code = 0,
        .shell = .powershell,
    });

    const rendered = buf[0..pos];
    try testing.expect(std.mem.indexOfScalar(u8, rendered, '\x01') == null);
    try testing.expect(std.mem.indexOfScalar(u8, rendered, '\x02') == null);
    try testing.expect(std.mem.indexOf(u8, rendered, "%{") == null);
    try testing.expect(std.mem.indexOf(u8, rendered, "%}") == null);
}

test "matrix fixture: all modules on all shells" {
    const Fixture = @import("fixture.zig").Fixture;
    const Shell = init_mod.Shell;
    const shells = [_]Shell{ .bash, .zsh, .fish, .powershell };

    var buf: [2048]u8 = undefined;
    var cfg = Config{};
    cfg.add_newline = false;
    cfg.cmd_duration.min_time = 0; // ensure duration renders

    for (shells) |sh| {
        const ctx = @import("../engine/context.zig").PromptContext{
            .cwd = "/home/user/project",
            .home = "/home/user",
            .status_code = 1,
            .cmd_duration = 3500,
            .shell = sh,
        };

        // 1. Test directory module
        const dir_out = try Fixture.renderModule("directory", cfg, ctx, &buf);
        try Fixture.assertValidShellAnsi(dir_out, sh);

        // 2. Test character module (with error status)
        const char_out = try Fixture.renderModule("character", cfg, ctx, &buf);
        try Fixture.assertValidShellAnsi(char_out, sh);

        // 3. Test cmd_duration module
        const dur_out = try Fixture.renderModule("cmd_duration", cfg, ctx, &buf);
        try Fixture.assertValidShellAnsi(dur_out, sh);

        // 4. Test full prompt
        const prompt_out = try Fixture.renderPrompt(cfg, ctx, &buf);
        try Fixture.assertValidShellAnsi(prompt_out, sh);
    }
}



