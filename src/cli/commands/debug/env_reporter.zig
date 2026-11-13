const std = @import("std");
const context = @import("../../../engine/context.zig");
const toml_parser = @import("../../../config/toml_parser.zig");
const install = @import("../../../init/install.zig");
const DebugContext = context.DebugContext;

fn escapeJson(buf: []u8, input: []const u8) []const u8 {
    var pos: usize = 0;
    for (input) |c| {
        if (c == '\\' or c == '"') {
            if (pos + 2 > buf.len) break;
            buf[pos] = '\\';
            buf[pos + 1] = c;
            pos += 2;
        } else {
            if (pos + 1 > buf.len) break;
            buf[pos] = c;
            pos += 1;
        }
    }
    return buf[0..pos];
}

fn checkFileContains(io: std.Io, path: []const u8, needle: []const u8) bool {
    var buf: [16384]u8 = undefined;
    const file = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(io, path, .{}) catch null
    else
        std.Io.Dir.cwd().openFile(io, path, .{}) catch null;
    if (file) |f| {
        var handle = f;
        defer handle.close(io);
        var stream_buf: [4096]u8 = undefined;
        var reader = handle.reader(io, &stream_buf);
        const bytes_read = reader.interface.readSliceShort(&buf) catch 0;
        if (bytes_read > 0) {
            return std.mem.indexOf(u8, buf[0..bytes_read], needle) != null;
        }
    }
    return false;
}

pub fn printEnvDebug(init: std.process.Init, writer: anytype, dctx: DebugContext) !void {
    const io = dctx.prompt.io orelse return;

    const shell_env = init.environ_map.get("SHELL") orelse "";
    const shell_name = if (shell_env.len > 0) std.fs.path.basename(shell_env) else "unknown";
    const term = init.environ_map.get("TERM") orelse "unknown";
    const colorterm = init.environ_map.get("COLORTERM") orelse "";
    const term_program = init.environ_map.get("TERM_PROGRAM") orelse "";

    const lang = init.environ_map.get("LC_ALL") orelse init.environ_map.get("LC_CTYPE") orelse init.environ_map.get("LANG") orelse "";
    const is_utf8 = std.mem.indexOf(u8, lang, "UTF-8") != null or std.mem.indexOf(u8, lang, "utf8") != null or std.mem.indexOf(u8, lang, "UTF8") != null;

    const has_truecolor = std.mem.eql(u8, colorterm, "truecolor") or std.mem.eql(u8, colorterm, "24bit");
    const has_256color = has_truecolor or std.mem.indexOf(u8, term, "256color") != null or std.mem.indexOf(u8, term, "256") != null;

    const zap_config_env = init.environ_map.get("ZAP_CONFIG");
    const shlvl = init.environ_map.get("SHLVL") orelse "1";

    var cfg_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved_cfg_path = toml_parser.resolveExistingConfigPath(io, &cfg_path_buf, init.environ_map);

    var bash_hook_path: [std.fs.max_path_bytes]u8 = undefined;
    const bash_rc = install.resolveShellConfigFile(io, .bash, dctx.prompt.home, &bash_hook_path) orelse "";
    const bash_hook = checkFileContains(io, bash_rc, "zap init bash") or checkFileContains(io, bash_rc, "zap prompt");

    var zsh_hook_path: [std.fs.max_path_bytes]u8 = undefined;
    const zsh_rc = install.resolveShellConfigFile(io, .zsh, dctx.prompt.home, &zsh_hook_path) orelse "";
    const zsh_hook = checkFileContains(io, zsh_rc, "zap init zsh") or checkFileContains(io, zsh_rc, "zap prompt");

    var fish_hook_path: [std.fs.max_path_bytes]u8 = undefined;
    const fish_rc = install.resolveShellConfigFile(io, .fish, dctx.prompt.home, &fish_hook_path) orelse "";
    const fish_hook = checkFileContains(io, fish_rc, "zap init fish") or checkFileContains(io, fish_rc, "zap prompt");

    var pwsh_hook_path: [std.fs.max_path_bytes]u8 = undefined;
    const pwsh_rc = install.resolveShellConfigFile(io, .powershell, dctx.prompt.home, &pwsh_hook_path) orelse "";
    const pwsh_hook = checkFileContains(io, pwsh_rc, "zap init powershell") or checkFileContains(io, pwsh_rc, "zap prompt");

    if (dctx.json) {
        var j_shell_env: [std.fs.max_path_bytes]u8 = undefined;
        var j_home: [std.fs.max_path_bytes]u8 = undefined;
        var j_cwd: [std.fs.max_path_bytes]u8 = undefined;
        var j_zc: [std.fs.max_path_bytes]u8 = undefined;
        var j_rc: [std.fs.max_path_bytes]u8 = undefined;
        try writer.print(
            \\{{ "target": "env", "shell": "{s}", "shell_path": "{s}", "term": "{s}", "term_program": "{s}", "color_support": {{ "truecolor": {}, "color_256": {} }}, "utf8_locale": {}, "locale": "{s}", "variables": {{ "HOME": "{s}", "PWD": "{s}", "ZAP_CONFIG": {s}{s}{s}, "SHLVL": "{s}" }}, "config": {{ "resolved_path": {s}{s}{s}, "exists": {} }}, "hooks": {{ "bash": {}, "zsh": {}, "fish": {}, "powershell": {} }} }}
            \\
        , .{
            shell_name,
            escapeJson(&j_shell_env, shell_env),
            term,
            term_program,
            has_truecolor,
            has_256color,
            is_utf8,
            lang,
            escapeJson(&j_home, dctx.prompt.home),
            escapeJson(&j_cwd, dctx.prompt.cwd),
            if (zap_config_env != null) "\"" else "",
            if (zap_config_env) |zc| escapeJson(&j_zc, zc) else "null",
            if (zap_config_env != null) "\"" else "",
            shlvl,
            if (resolved_cfg_path != null) "\"" else "",
            if (resolved_cfg_path) |rc| escapeJson(&j_rc, rc) else "null",
            if (resolved_cfg_path != null) "\"" else "",
            resolved_cfg_path != null,
            bash_hook,
            zsh_hook,
            fish_hook,
            pwsh_hook,
        });
    } else {
        try writer.print(
            \\⚡ Zap Environment & Terminal Inspector
            \\
            \\Terminal & Display:
            \\  Detected Shell:    {s} ({s})
            \\  Terminal ($TERM):  {s}{s}{s}
            \\  Color Support:     {s}
            \\  Locale (UTF-8):    {s} ({s})
            \\
            \\Key Environment Variables:
            \\  $HOME:             {s}
            \\  $PWD:              {s}
            \\  $ZAP_CONFIG:       {s}
            \\  $SHLVL:            {s}
            \\
            \\Zap Configuration:
            \\  Resolved Path:     {s}
            \\
            \\Shell Integration Hooks:
            \\  {s} bash:           {s} ({s})
            \\  {s} zsh:            {s} ({s})
            \\  {s} fish:           {s} ({s})
            \\  {s} powershell:     {s} ({s})
            \\
        , .{
            shell_name,
            if (shell_env.len > 0) shell_env else "none",
            term,
            if (term_program.len > 0) " (" else "",
            if (term_program.len > 0) term_program else "",
            if (has_truecolor) "TrueColor (24-bit) & 256-color" else if (has_256color) "256-color" else "Standard ANSI (16 colors)",
            if (lang.len > 0) lang else "not set",
            if (is_utf8) "UTF-8 supported" else "non-UTF8 or standard ASCII",
            dctx.prompt.home,
            dctx.prompt.cwd,
            if (zap_config_env) |zc| zc else "(not set - using default discovery)",
            shlvl,
            if (resolved_cfg_path) |rc| rc else "Default built-in configuration (no file found)",
            if (bash_hook) "✔" else "·",
            if (bash_hook) "Hook installed" else "Not installed",
            bash_rc,
            if (zsh_hook) "✔" else "·",
            if (zsh_hook) "Hook installed" else "Not installed",
            zsh_rc,
            if (fish_hook) "✔" else "·",
            if (fish_hook) "Hook installed" else "Not installed",
            fish_rc,
            if (pwsh_hook) "✔" else "·",
            if (pwsh_hook) "Hook installed" else "Not installed",
            pwsh_rc,
        });
    }
}

pub fn printShellDebug(init: std.process.Init, writer: anytype, dctx: DebugContext) !void {
    const io = dctx.prompt.io orelse return;
    const init_mod = @import("../../../init/root.zig");

    const shell_env = init.environ_map.get("SHELL") orelse "";
    const shell_name = if (shell_env.len > 0) std.fs.path.basename(shell_env) else "unknown";

    var bash_hook_path: [std.fs.max_path_bytes]u8 = undefined;
    const bash_rc = install.resolveShellConfigFile(io, .bash, dctx.prompt.home, &bash_hook_path) orelse "";
    const bash_hook = checkFileContains(io, bash_rc, "zap init bash") or checkFileContains(io, bash_rc, "zap prompt");

    var zsh_hook_path: [std.fs.max_path_bytes]u8 = undefined;
    const zsh_rc = install.resolveShellConfigFile(io, .zsh, dctx.prompt.home, &zsh_hook_path) orelse "";
    const zsh_hook = checkFileContains(io, zsh_rc, "zap init zsh") or checkFileContains(io, zsh_rc, "zap prompt");

    var fish_hook_path: [std.fs.max_path_bytes]u8 = undefined;
    const fish_rc = install.resolveShellConfigFile(io, .fish, dctx.prompt.home, &fish_hook_path) orelse "";
    const fish_hook = checkFileContains(io, fish_rc, "zap init fish") or checkFileContains(io, fish_rc, "zap prompt");

    var pwsh_hook_path: [std.fs.max_path_bytes]u8 = undefined;
    const pwsh_rc = install.resolveShellConfigFile(io, .powershell, dctx.prompt.home, &pwsh_hook_path) orelse "";
    const pwsh_hook = checkFileContains(io, pwsh_rc, "zap init powershell") or checkFileContains(io, pwsh_rc, "zap prompt");

    if (dctx.json) {
        var j_shell_env: [std.fs.max_path_bytes]u8 = undefined;
        var j_bash_rc: [std.fs.max_path_bytes]u8 = undefined;
        var j_zsh_rc: [std.fs.max_path_bytes]u8 = undefined;
        var j_fish_rc: [std.fs.max_path_bytes]u8 = undefined;
        var j_pwsh_rc: [std.fs.max_path_bytes]u8 = undefined;
        try writer.print(
            \\{{ "target": "shell", "detected_shell": "{s}", "shell_path": "{s}", "hooks": {{ "bash": {{ "installed": {}, "rc_path": "{s}", "right_prompt": false }}, "zsh": {{ "installed": {}, "rc_path": "{s}", "right_prompt": true }}, "fish": {{ "installed": {}, "rc_path": "{s}", "right_prompt": true }}, "powershell": {{ "installed": {}, "rc_path": "{s}", "right_prompt": false }} }} }}
            \\
        , .{
            shell_name,
            escapeJson(&j_shell_env, shell_env),
            bash_hook,
            escapeJson(&j_bash_rc, bash_rc),
            zsh_hook,
            escapeJson(&j_zsh_rc, zsh_rc),
            fish_hook,
            escapeJson(&j_fish_rc, fish_rc),
            pwsh_hook,
            escapeJson(&j_pwsh_rc, pwsh_rc),
        });
        return;
    }

    try writer.print(
        \\⚡ Zap Shell Integration Inspector
        \\
        \\Current Session:
        \\  Detected Shell:    {s} ({s})
        \\
        \\Supported Shells & Hook Status:
        \\  {s} bash        {s:<16} RC: {s}
        \\                  Features: first-prompt --no-newline, duration tracking, \[...\] escapes
        \\  {s} zsh         {s:<16} RC: {s}
        \\                  Features: first-prompt --no-newline, RPROMPT (--right), %{{...%}} escapes
        \\  {s} fish        {s:<16} RC: {s}
        \\                  Features: first-prompt --no-newline, fish_right_prompt (--right), $CMD_DURATION
        \\  {s} powershell  {s:<16} RC: {s}
        \\                  Features: first-prompt --no-newline, Clear-Host wrapper, execution history timer
        \\
    , .{
        shell_name,
        if (shell_env.len > 0) shell_env else "none",
        if (bash_hook) "✔" else "·",
        if (bash_hook) "Installed" else "Not installed",
        bash_rc,
        if (zsh_hook) "✔" else "·",
        if (zsh_hook) "Installed" else "Not installed",
        zsh_rc,
        if (fish_hook) "✔" else "·",
        if (fish_hook) "Installed" else "Not installed",
        fish_rc,
        if (pwsh_hook) "✔" else "·",
        if (pwsh_hook) "Installed" else "Not installed",
        pwsh_rc,
    });

    if (dctx.verbose) {
        const parsed_sh = init_mod.Shell.parse(shell_name) orelse .fish;
        try writer.print("\nGenerated Init Script Preview ({s}):\n----------------------------------------\n", .{@tagName(parsed_sh)});
        try init_mod.renderInitScript(writer, parsed_sh, "zap");
        try writer.writeAll("----------------------------------------\n");
    }
}

