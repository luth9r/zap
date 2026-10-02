const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const Shell = root.Shell;

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
    const sep = if (builtin.os.tag == .windows) "\\" else "/";

    return switch (shell) {
        .bash => std.fmt.bufPrint(buf, "{s}{s}.bashrc", .{ home_dir, sep }) catch null,
        .zsh => std.fmt.bufPrint(buf, "{s}{s}.zshrc", .{ home_dir, sep }) catch null,
        .fish => std.fmt.bufPrint(buf, "{s}{s}.config{s}fish{s}config.fish", .{ home_dir, sep, sep, sep }) catch null,
        .powershell => if (builtin.os.tag == .windows)
            std.fmt.bufPrint(buf, "{s}\\Documents\\PowerShell\\Microsoft.PowerShell_profile.ps1", .{home_dir}) catch null
        else
            std.fmt.bufPrint(buf, "{s}/.config/powershell/Microsoft.PowerShell_profile.ps1", .{home_dir}) catch null,
        .generic => null,
    };
}

/// Generates the one-line hook invocation for the given shell.
pub fn getHookSnippet(
    shell: Shell,
    exe_name: []const u8,
    buf: []u8,
) ?[]const u8 {
    return switch (shell) {
        .bash => std.fmt.bufPrint(buf, root.bash.HOOK_TEMPLATE, .{exe_name}) catch null,
        .zsh => std.fmt.bufPrint(buf, root.zsh.HOOK_TEMPLATE, .{exe_name}) catch null,
        .fish => std.fmt.bufPrint(buf, root.fish.HOOK_TEMPLATE, .{exe_name}) catch null,
        .powershell => std.fmt.bufPrint(buf, root.powershell.HOOK_TEMPLATE, .{exe_name}) catch null,
        .generic => null,
    };
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

    var hook_buf: [256]u8 = undefined;
    const hook_cmd = getHookSnippet(shell, exe_name, &hook_buf) orelse return false;

    // Check if configuration file exists
    var existing_content_buf: [128 * 1024]u8 = undefined;
    var existing_len: usize = 0;
    var file_exists = false;

    const file_res = if (std.fs.path.isAbsolute(config_path))
        std.Io.Dir.openFileAbsolute(io, config_path, .{})
    else
        std.Io.Dir.cwd().openFile(io, config_path, .{});

    if (file_res) |f| {
        var file = f;
        defer file.close(io);
        file_exists = true;

        var stream_buf: [4096]u8 = undefined;
        var reader = file.reader(io, &stream_buf);
        existing_len = reader.interface.readSliceShort(&existing_content_buf) catch 0;

        const existing_content = existing_content_buf[0..existing_len];

        // Check for existing hook (idempotency)
        var search_pattern_buf: [64]u8 = undefined;
        const search_pattern = std.fmt.bufPrint(&search_pattern_buf, "init {s}", .{@tagName(shell)}) catch @tagName(shell);

        if (std.mem.indexOf(u8, existing_content, hook_cmd) != null or
            std.mem.indexOf(u8, existing_content, search_pattern) != null)
        {
            try writer.print("ℹ Zap hook is already installed in '{s}'.\n", .{config_path});
            return true;
        }
    } else |_| {}

    // Create backup if the file already exists and has content
    var backup_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (file_exists and existing_len > 0) {
        const backup_path = (std.fmt.bufPrint(&backup_path_buf, "{s}.zap.bak", .{config_path}) catch null) orelse {
            try writer.print("✖ Error: failed to generate backup path.\n", .{});
            return false;
        };

        const backup_file_res = if (std.fs.path.isAbsolute(backup_path))
            std.Io.Dir.createFileAbsolute(io, backup_path, .{})
        else
            std.Io.Dir.cwd().createFile(io, backup_path, .{});

        if (backup_file_res) |bf| {
            var backup_file = bf;
            defer backup_file.close(io);
            try backup_file.writeStreamingAll(io, existing_content_buf[0..existing_len]);
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
    var append_buf: [512]u8 = undefined;
    const append_snippet = std.fmt.bufPrint(&append_buf, "\n# Zap prompt hook\n{s}\n", .{hook_cmd}) catch return false;

    // Write / append to configuration file
    const write_file_res = if (std.fs.path.isAbsolute(config_path))
        std.Io.Dir.createFileAbsolute(io, config_path, .{})
    else
        std.Io.Dir.cwd().createFile(io, config_path, .{});

    if (write_file_res) |wf| {
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
}
