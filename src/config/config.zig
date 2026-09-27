const std = @import("std");

pub const DirectoryConfig = @import("../modules/directory.zig").DirectoryConfig;
pub const CharacterConfig = @import("../modules/character.zig").CharacterConfig;
pub const CmdDurationConfig = @import("../modules/cmd_duration.zig").CmdDurationConfig;

pub const Config = struct {
    // Root prompt format string orchestrating module layout.
    format: []const u8 = "$directory$cmd_duration$character",
    // Whether to insert a blank line before the prompt.
    add_newline: bool = true,
    // Directory module configuration.
    directory: DirectoryConfig = .{},
    // Command duration module configuration.
    cmd_duration: CmdDurationConfig = .{},
    // Character module configuration.
    character: CharacterConfig = .{},
};
