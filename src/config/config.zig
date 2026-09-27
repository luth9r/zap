const std = @import("std");

pub const DirectoryConfig = struct {
    // Format string used to render the directory module.
    format: []const u8 = "[$path]($style)[$read_only]($read_only_style) ",
    // Style string for the directory path.
    style: []const u8 = "bold cyan",
    // Replacement symbol for the user home directory.
    home_symbol: []const u8 = "~",
    // Symbol shown when the directory is read-only (Nerd Font lock icon).
    read_only: []const u8 = "󰌾",
    // Style string for the read-only symbol.
    read_only_style: []const u8 = "bold red",
    // Whether the directory module is disabled.
    disabled: bool = false,
};

pub const CharacterConfig = struct {
    // Format string used to render the character module.
    format: []const u8 = "$symbol ",
    // Symbol rendered on exit code 0 (can contain styled blocks like [➜](bold green)).
    success_symbol: []const u8 = "[❯](bold green)",
    // Symbol rendered on non-zero exit code.
    error_symbol: []const u8 = "[❯](bold red)",
    // Whether the character module is disabled.
    disabled: bool = false,
};

pub const Config = struct {
    // Root prompt format string orchestrating module layout.
    format: []const u8 = "$directory$character",
    // Whether to insert a blank line before the prompt.
    add_newline: bool = true,
    // Directory module configuration.
    directory: DirectoryConfig = .{},
    // Character module configuration.
    character: CharacterConfig = .{},
};
