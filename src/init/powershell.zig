const std = @import("std");

pub const HOOK_TEMPLATE = "Invoke-Expression (&{s} init powershell | Out-String)";

pub const SCRIPT =
    \\# Zap prompt integration for PowerShell
    \\
    \\$global:_zap_start_time = $null
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
    \\    $out = & "{{EXE}}" prompt --status $lastExitCodeForPrompt --duration $duration --shell powershell
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

    const builtin = @import("builtin");
    try h.setupGit();
    try h.git(&.{ "checkout", "-b", "pwsh-branch" });

    try h.writeFile(".config/zap/zap.toml",
        \\format = "$directory$git_branch$character"
        \\add_newline = false
    );

    const install_res = try h.execZapAllowFail(&.{ "init", "powershell", "--install" });
    try testing.expectEqual(@as(u8, 0), install_res.exit_code);

    const alloc = h.arena.allocator();
    const profile_path = if (builtin.os.tag == .windows)
        try std.fmt.allocPrint(alloc, "{s}\\Documents\\PowerShell\\Microsoft.PowerShell_profile.ps1", .{h.tmp_dir})
    else
        try std.fmt.allocPrint(alloc, "{s}/.config/powershell/Microsoft.PowerShell_profile.ps1", .{h.tmp_dir});

    const cmd = try std.fmt.allocPrint(alloc, ". '{s}'; prompt", .{profile_path});

    const home_env = try std.fmt.allocPrint(alloc, "HOME={s}", .{h.tmp_dir});
    const xdg_env = try std.fmt.allocPrint(alloc, "XDG_CONFIG_HOME={s}/.config", .{h.tmp_dir});
    const zap_dir = std.fs.path.dirname(h.zap_bin) orelse ".";
    const path_env = if (builtin.os.tag == .windows)
        try std.fmt.allocPrint(alloc, "PATH={s};C:\\Windows\\System32;C:\\Windows", .{zap_dir})
    else
        try std.fmt.allocPrint(alloc, "PATH={s}:/usr/bin:/bin:/usr/local/bin", .{zap_dir});
    const pwsh_bin = if (builtin.os.tag == .windows) "powershell.exe" else "pwsh";

    const argv = [_][]const u8{
        "env",
        home_env,
        xdg_env,
        path_env,
        pwsh_bin,
        "-NoProfile",
        "-NonInteractive",
        "-Command",
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
    const term = try child.wait(std.testing.io);
    if (term == .exited and term.exited == 127) return;

    const pwsh_prompt_out = out_buf[0..n];
    try Harness.expectContains(pwsh_prompt_out, "pwsh-branch");
    try Harness.expectContains(pwsh_prompt_out, "❯");
}
