const std = @import("std");
const root = @import("root.zig");
const platform = @import("../utils/platform.zig");
const fs = @import("../utils/fs.zig");
const Shell = root.Shell;

const BASH_RC_REL = ".bashrc";
const ZSH_RC_REL = ".zshrc";
const FISH_RC_REL = ".config" ++ platform.sep ++ "fish" ++ platform.sep ++ "config.fish";
const PWSH_RC_REL = if (platform.is_windows)
    "Documents\\PowerShell\\Microsoft.PowerShell_profile.ps1"
else
    ".config/powershell/Microsoft.PowerShell_profile.ps1";
const CMD_RC_REL = if (platform.is_windows)
    "AppData\\Local\\clink\\zap.lua"
else
    ".config/clink/zap.lua";

pub const InstallResult = struct {
    already_installed: bool = false,
    config_path: []const u8,
    backup_path: ?[]const u8 = null,
};

/// Resolves the canonical shell configuration file path for the given shell.
pub fn resolveShellConfigFile(
    io: std.Io,
    shell: Shell,
    home_dir: []const u8,
    buf: *[std.fs.max_path_bytes]u8,
) ?[]const u8 {
    _ = io;
    const rel = switch (shell) {
        .bash => BASH_RC_REL,
        .zsh => ZSH_RC_REL,
        .fish => FISH_RC_REL,
        .powershell => PWSH_RC_REL,
        .cmd => CMD_RC_REL,
        .generic => return null,
    };
    return platform.joinPath(buf, home_dir, rel);
}

/// Generates the one-line hook invocation for the given shell.
pub fn getHookSnippet(
    shell: Shell,
    exe_name: []const u8,
    buf: []u8,
) ?[]const u8 {
    var quoted_buf: [std.fs.max_path_bytes + 8]u8 = undefined;
    const effective_exe = if (shell != .cmd and std.mem.indexOfScalar(u8, exe_name, ' ') != null)
        std.fmt.bufPrint(&quoted_buf, "\"{s}\"", .{exe_name}) catch return null
    else
        exe_name;

    return switch (shell) {
        .bash => std.fmt.bufPrint(buf, root.bash.HOOK_TEMPLATE, .{effective_exe}) catch null,
        .zsh => std.fmt.bufPrint(buf, root.zsh.HOOK_TEMPLATE, .{effective_exe}) catch null,
        .fish => std.fmt.bufPrint(buf, root.fish.HOOK_TEMPLATE, .{effective_exe}) catch null,
        .powershell => std.fmt.bufPrint(buf, root.powershell.HOOK_TEMPLATE, .{effective_exe}) catch null,
        .cmd => std.fmt.bufPrint(buf, root.cmd.HOOK_TEMPLATE, .{exe_name}) catch null,
        .generic => null,
    };
}

fn containsActiveHookLine(content: []const u8, hook_cmd: []const u8, search_pattern: []const u8) bool {
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or std.mem.startsWith(u8, line, "--")) continue;
        if (std.mem.indexOf(u8, line, hook_cmd) != null or
            std.mem.indexOf(u8, line, search_pattern) != null)
        {
            return true;
        }
    }
    return false;
}

/// Installs the Zap prompt hook into the user's shell configuration file idempotently with automatic backup.
pub fn installHook(
    io: std.Io,
    shell: Shell,
    exe_name: []const u8,
    home_dir: []const u8,
    writer: anytype,
) !bool {
    if (shell == .generic) {
        try writer.print("✖ Error: cannot auto-install hook for generic/plain shell. Please specify bash, zsh, fish, or powershell.\n", .{});
        return false;
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const config_path = resolveShellConfigFile(io, shell, home_dir, &path_buf) orelse {
        try writer.print("✖ Error: failed to resolve config file path for shell '{s}'.\n", .{@tagName(shell)});
        return false;
    };

    var hook_buf: [std.fs.max_path_bytes + 256]u8 = undefined;
    const hook_cmd = getHookSnippet(shell, exe_name, &hook_buf) orelse return false;

    // Check if configuration file exists and read its content safely
    var existing_content_buf: [128 * 1024]u8 = undefined;
    const file_exists = fs.fileExists(io, config_path);
    const existing_opt = fs.readFileRaw(io, config_path, &existing_content_buf);
    const existing_len = if (existing_opt) |s| s.len else 0;

    if (file_exists and existing_opt == null) {
        // Distinguish an empty 0-byte file from an unreadable existing file
        if (fs.openFile(io, config_path, .{})) |f| {
            f.close(io);
        } else |err| {
            try writer.print("✖ Error: failed to read existing config file '{s}': {any}\n", .{ config_path, err });
            return false;
        }
    }

    if (existing_len == existing_content_buf.len) {
        try writer.print("✖ Error: config file '{s}' exceeds 128 KB safety buffer; refusing to overwrite to prevent truncation.\n", .{config_path});
        return false;
    }

    if (existing_opt) |existing_content| {
        // Check for existing hook (idempotency, ignoring commented-out lines)
        var search_pattern_buf: [64]u8 = undefined;
        const search_pattern = std.fmt.bufPrint(&search_pattern_buf, "init {s}", .{@tagName(shell)}) catch @tagName(shell);

        if (containsActiveHookLine(existing_content, hook_cmd, search_pattern)) {
            try writer.print("ℹ Zap hook is already installed in '{s}'.\n", .{config_path});
            return true;
        }
    }

    // Create backup if the file already exists and has content
    var backup_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (file_exists and existing_len > 0) {
        const backup_path = (std.fmt.bufPrint(&backup_path_buf, "{s}.zap.bak", .{config_path}) catch null) orelse {
            try writer.print("✖ Error: failed to generate backup path.\n", .{});
            return false;
        };

        if (fs.writeFile(io, backup_path, existing_content_buf[0..existing_len])) |_| {
            try writer.print("✔ Backup created at '{s}'.\n", .{backup_path});
        } else |err| {
            try writer.print("⚠ Warning: failed to create backup file '{s}': {any}\n", .{ backup_path, err });
        }
    }

    // Ensure parent directory exists
    if (std.fs.path.dirname(config_path)) |parent_dir| {
        std.Io.Dir.cwd().createDirPath(io, parent_dir) catch {};
    }

    // Append hook snippet with clean demarcations
    var append_buf: [std.fs.max_path_bytes + 512]u8 = undefined;
    const append_snippet = std.fmt.bufPrint(&append_buf, "\n# Zap prompt hook\n{s}\n", .{hook_cmd}) catch return false;

    // Write / append to configuration file
    if (fs.createFile(io, config_path, .{})) |wf| {
        var write_file = wf;
        defer write_file.close(io);
        if (existing_len > 0) {
            try write_file.writeStreamingAll(io, existing_content_buf[0..existing_len]);
        }
        try write_file.writeStreamingAll(io, append_snippet);
    } else |err| {
        try writer.print("✖ Error: failed to write to '{s}': {any}\n", .{ config_path, err });
        return false;
    }

    try writer.print("✔ Successfully installed Zap hook for {s} into '{s}'!\n", .{ @tagName(shell), config_path });
    try writer.print("✔ Restart your shell or run your shell's source command to apply.\n", .{});
    return true;
}

test "unit: resolveShellConfigFile for bash, zsh, fish, powershell" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = "/home/user";

    const bash_cfg = resolveShellConfigFile(std.testing.io, .bash, home, &buf).?;
    try std.testing.expect(std.mem.endsWith(u8, bash_cfg, ".bashrc"));

    const zsh_cfg = resolveShellConfigFile(std.testing.io, .zsh, home, &buf).?;
    try std.testing.expect(std.mem.endsWith(u8, zsh_cfg, ".zshrc"));

    const fish_cfg = resolveShellConfigFile(std.testing.io, .fish, home, &buf).?;
    try std.testing.expect(std.mem.endsWith(u8, fish_cfg, "config.fish"));

    const pwsh_cfg = resolveShellConfigFile(std.testing.io, .powershell, home, &buf).?;
    try std.testing.expect(std.mem.endsWith(u8, pwsh_cfg, "Microsoft.PowerShell_profile.ps1"));

    const cmd_cfg = resolveShellConfigFile(std.testing.io, .cmd, home, &buf).?;
    try std.testing.expect(std.mem.endsWith(u8, cmd_cfg, "zap.lua"));
}

test "unit: getHookSnippet for all shells" {
    var buf: [128]u8 = undefined;

    const bash_hook = getHookSnippet(.bash, "zap", &buf).?;
    try std.testing.expectEqualStrings("eval \"$(zap init bash)\"", bash_hook);

    const zsh_hook = getHookSnippet(.zsh, "zap", &buf).?;
    try std.testing.expectEqualStrings("eval \"$(zap init zsh)\"", zsh_hook);

    const fish_hook = getHookSnippet(.fish, "zap", &buf).?;
    try std.testing.expectEqualStrings("zap init fish | source", fish_hook);

    const pwsh_hook = getHookSnippet(.powershell, "zap", &buf).?;
    try std.testing.expectEqualStrings("Invoke-Expression (&zap init powershell | Out-String)", pwsh_hook);

    const cmd_hook = getHookSnippet(.cmd, "zap", &buf).?;
    try std.testing.expectEqualStrings(
        "local h=io.popen('\"zap\" init cmd');if h then local s=h:read('*a');h:close();local f=load(s);if f then f() end end",
        cmd_hook,
    );
}
