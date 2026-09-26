const std = @import("std");

pub const PathConfig = struct {
    // The symbol to use when replacing the HOME prefix in paths.
    home_symbol: []const u8 = "~",
    // The color code to use for the HOME symbol in paths.
    home_color: []const u8 = "\x1b[36m",
};

pub const PromptCharConfig = struct {
    // The symbol to use for the prompt character.
    success_symbol: []const u8 = ">",
    // The symbol to use for the prompt character when an error occurs.
    error_symbol: []const u8 = "X",
    // The color code to use for the prompt character.
    success_color: []const u8 = "\x1b[1;32m",
    // The color code to use for the prompt character when an error occurs.
    error_color: []const u8 = "\x1b[1;31m",
};

pub const Config = struct {
    add_newline: bool = false,
    path: PathConfig = .{},
    prompt: PromptCharConfig = .{},
};
