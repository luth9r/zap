const std = @import("std");

pub const HOOK_TEMPLATE = "Invoke-Expression (&{s} init powershell | Out-String)";

pub const SCRIPT =
    \\# Zap prompt integration for PowerShell
    \\
    \\$global:_zap_start_time = $null
    \\$global:_zap_first_prompt = $true
    \\
    \\function global:prompt {
    \\    $lastExitCodeForPrompt = if ($global:LASTEXITCODE -ne $null) { $global:LASTEXITCODE } else { 0 }
    \\    $duration = 0
    \\
    \\    if ($global:_zap_start_time -ne $null) {
    \\        $duration = [math]::Round(((Get-Date) - $global:_zap_start_time).TotalMilliseconds)
    \\        $global:_zap_start_time = $null
    \\    }
    \\
    \\    $env:PWD = "$PWD"
    \\    if ($global:_zap_first_prompt) {
    \\        $global:_zap_first_prompt = $false
    \\        $out = & "{{EXE}}" prompt --status $lastExitCodeForPrompt --duration $duration --shell powershell --no-newline
    \\    } else {
    \\        $out = & "{{EXE}}" prompt --status $lastExitCodeForPrompt --duration $duration --shell powershell
    \\    }
    \\    if ($out -is [array]) {
    \\        $out -join "`n"
    \\    } else {
    \\        $out
    \\    }
    \\}
    \\
;

const testing = std.testing;
const init_mod = @import("root.zig");
const prompt = @import("../engine/prompt.zig");
const config_mod = @import("../config/config.zig");
const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;
const Harness = @import("../tests/harness.zig").Harness;

test "unit: init powershell script generation" {
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    try init_mod.renderInitScript(writer, .powershell, "zap");
    const script = buf[0..pos];

    try testing.expect(std.mem.indexOf(u8, script, "function global:prompt") != null);
    try testing.expect(std.mem.indexOf(u8, script, "$out = & \"zap\" prompt --status $lastExitCodeForPrompt") != null);
    try testing.expect(std.mem.indexOf(u8, script, "{{EXE}}") == null);
}

test "unit: prompt render with powershell raw escapes" {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    var cfg = config_mod.defaultConfig();
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

test "integration: real powershell session with auto-installed zap hook and config" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    const platform = @import("../utils/platform.zig");
    const install = @import("install.zig");

    try h.setupGit();
    try h.git(&.{ "checkout", "-b", "pwsh-branch" });

    try h.writeFile(".config/zap/zap.toml",
        \\format = "$directory$git_branch$character"
        \\add_newline = false
    );

    const install_res = try h.execZapAllowFail(&.{ "init", "powershell", "--install" });
    try testing.expectEqual(@as(u8, 0), install_res.exit_code);

    var profile_buf: [std.fs.max_path_bytes]u8 = undefined;
    const profile_path = install.resolveShellConfigFile(std.testing.io, .powershell, h.tmp_dir, &profile_buf).?;
    const cmd = try std.fmt.allocPrint(h.arena.allocator(), ". '{s}'; prompt", .{profile_path});

    const pwsh_prompt_out = (try h.runShellScript(&.{
        platform.powershell_bin,
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-Command",
        cmd,
    })) orelse return;
    try Harness.expectContains(pwsh_prompt_out, "pwsh-branch");
    try Harness.expectContains(pwsh_prompt_out, "❯");
}
