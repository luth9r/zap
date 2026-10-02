const std = @import("std");

pub const bash = @import("bash.zig");
pub const zsh = @import("zsh.zig");
pub const fish = @import("fish.zig");
pub const powershell = @import("powershell.zig");
pub const install = @import("install.zig");

pub const Shell = enum {
    generic,
    bash,
    zsh,
    fish,
    powershell,

    pub fn parse(str: []const u8) ?Shell {
        if (std.ascii.eqlIgnoreCase(str, "bash")) return .bash;
        if (std.ascii.eqlIgnoreCase(str, "zsh")) return .zsh;
        if (std.ascii.eqlIgnoreCase(str, "fish")) return .fish;
        if (std.ascii.eqlIgnoreCase(str, "powershell") or std.ascii.eqlIgnoreCase(str, "pwsh")) return .powershell;
        if (std.ascii.eqlIgnoreCase(str, "generic") or std.ascii.eqlIgnoreCase(str, "plain")) return .generic;
        return null;
    }
};

pub fn renderInitScript(
    writer: anytype,
    shell: Shell,
    exe_name: []const u8,
) !void {
    const raw_script = switch (shell) {
        .bash => bash.SCRIPT,
        .zsh => zsh.SCRIPT,
        .fish => fish.SCRIPT,
        .powershell => powershell.SCRIPT,
        .generic => return,
    };

    const target = "{{EXE}}";
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, raw_script, start, target)) |idx| {
        try writer.writeAll(raw_script[start..idx]);
        try writer.writeAll(exe_name);
        start = idx + target.len;
    }
    if (start < raw_script.len) {
        try writer.writeAll(raw_script[start..]);
    }
}

test "unit: renderInitScript all shells" {
    const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;
    var buf: [4096]u8 = undefined;
    const shells = [_]Shell{ .bash, .zsh, .fish, .powershell };

    for (shells) |sh| {
        var pos: usize = 0;
        const writer = BufferWriter.init(&buf, &pos);
        try renderInitScript(writer, sh, "zap");
        const out = buf[0..pos];
        try std.testing.expect(out.len > 0);
        try std.testing.expect(std.mem.indexOf(u8, out, "zap") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "{{EXE}}") == null);
    }
}

test "unit: Shell.parse" {
    try std.testing.expectEqual(Shell.bash, Shell.parse("bash").?);
    try std.testing.expectEqual(Shell.zsh, Shell.parse("Zsh").?);
    try std.testing.expectEqual(Shell.fish, Shell.parse("FISH").?);
    try std.testing.expectEqual(Shell.powershell, Shell.parse("powershell").?);
    try std.testing.expectEqual(Shell.powershell, Shell.parse("pwsh").?);
    try std.testing.expectEqual(Shell.generic, Shell.parse("plain").?);
    try std.testing.expect(Shell.parse("unknown") == null);
}

test "unit: matrix fixture: all modules on all shells" {
    const Fixture = @import("../tests/fixture.zig").Fixture;
    const config_mod = @import("../config/config.zig");
    const shells = [_]Shell{ .bash, .zsh, .fish, .powershell };

    var buf: [2048]u8 = undefined;
    var cfg = config_mod.defaultConfig();
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

test "unit: init refAllDecls" {
    std.testing.refAllDecls(@This());
}
