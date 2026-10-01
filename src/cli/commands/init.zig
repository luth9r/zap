const std = @import("std");
const init_mod = @import("../../init/root.zig");
const BufferWriter = @import("../../utils/buffer_writer.zig").BufferWriter;

pub const Args = struct {
    shell: init_mod.Shell,
    exe_name: []const u8 = "zap",
    install: bool = false,
};

pub fn execute(init: std.process.Init, init_args: Args) !void {
    if (init_args.install) {
        const home_path = resolveHomePath(init);
        var out_buf: [4096]u8 = undefined;
        var pos: usize = 0;
        const writer = BufferWriter.init(&out_buf, &pos);

        const ok = try init_mod.install.installHook(
            init.io,
            init_args.shell,
            init_args.exe_name,
            home_path,
            writer,
        );
        try std.Io.File.stdout().writeStreamingAll(init.io, out_buf[0..pos]);

        if (!ok) {
            std.process.exit(1);
        }
    } else {
        var script_buf: [8192]u8 = undefined;
        var pos: usize = 0;
        const writer = BufferWriter.init(&script_buf, &pos);
        try init_mod.renderInitScript(writer, init_args.shell, init_args.exe_name);
        try std.Io.File.stdout().writeStreamingAll(init.io, script_buf[0..pos]);
    }
}

pub fn resolveHomePath(init: std.process.Init) []const u8 {
    return init.environ_map.get("HOME") orelse init.environ_map.get("USERPROFILE") orelse ".";
}

const testing = std.testing;
const Harness = @import("../../tests/harness.zig").Harness;

test "integration: zap init all 4 shells" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    const bash_init = try h.execZap(&.{ "init", "bash" });
    try Harness.expectContains(bash_init, "PROMPT_COMMAND");
    try Harness.expectContains(bash_init, "prompt --status");

    const zsh_init = try h.execZap(&.{ "init", "zsh" });
    try Harness.expectContains(zsh_init, "add-zsh-hook");
    try Harness.expectContains(zsh_init, "prompt --status");

    const fish_init = try h.execZap(&.{ "init", "fish" });
    try Harness.expectContains(fish_init, "function fish_prompt");
    try Harness.expectContains(fish_init, "prompt --status");

    const pwsh_init = try h.execZap(&.{ "init", "powershell" });
    try Harness.expectContains(pwsh_init, "function global:prompt");
    try Harness.expectContains(pwsh_init, "prompt --status");
}

test "integration: zap init --install creates backup and is idempotent" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    // Create an initial .bashrc with existing content
    try h.writeFile(".bashrc", "# Existing bashrc content\nexport FOO=BAR\n");

    // First install run
    const res1 = try h.execZapAllowFail(&.{ "init", "bash", "--install" });
    try testing.expectEqual(@as(u8, 0), res1.exit_code);
    try Harness.expectContains(res1.stdout, "Backup created");
    try Harness.expectContains(res1.stdout, "Successfully installed");

    // Second install run (should detect existing hook and not duplicate)
    const res2 = try h.execZapAllowFail(&.{ "init", "bash", "--install" });
    try testing.expectEqual(@as(u8, 0), res2.exit_code);
    try Harness.expectContains(res2.stdout, "already installed");
}

test "integration: zap init --install for zsh and fish" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    const res_zsh = try h.execZapAllowFail(&.{ "init", "zsh", "--install" });
    try testing.expectEqual(@as(u8, 0), res_zsh.exit_code);
    try Harness.expectContains(res_zsh.stdout, "Successfully installed");

    const res_fish = try h.execZapAllowFail(&.{ "init", "fish", "--install" });
    try testing.expectEqual(@as(u8, 0), res_fish.exit_code);
    try Harness.expectContains(res_fish.stdout, "Successfully installed");
}
