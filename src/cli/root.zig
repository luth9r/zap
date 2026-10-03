const std = @import("std");

pub const args = @import("args.zig");
pub const version_cmd = @import("commands/version.zig");
pub const help_cmd = @import("commands/help.zig");
pub const list_modules_cmd = @import("commands/list_modules.zig");
pub const validate_cmd = @import("commands/validate.zig");
pub const init_cmd = @import("commands/init.zig");
pub const prompt_cmd = @import("commands/prompt.zig");
pub const debug_cmd = @import("commands/debug.zig");

pub const Command = args.Command;
pub const parseCommand = args.parseCommand;
pub const printHelp = help_cmd.printHelp;
pub const printModuleList = list_modules_cmd.printModuleList;

pub fn run(init: std.process.Init) !void {
    const cmd = parseCommand(init, init.arena.allocator()) catch |err| {
        if (err == error.InvalidArgs) {
            std.process.exit(1);
        }
        return err;
    };

    switch (cmd) {
        .help => try help_cmd.executeHelp(init.io),
        .version => try version_cmd.executeVersion(init.io),
        .list_modules => try list_modules_cmd.execute(init.io),
        .validate => |v_args| try validate_cmd.execute(init, v_args),
        .init => |init_args| try init_cmd.execute(init, init_args),
        .debug => |debug_args| try debug_cmd.execute(init, debug_args),
        .prompt => |prompt_args| try prompt_cmd.execute(init, prompt_args),
    }
}

test "unit: cli refAllDecls" {
    std.testing.refAllDecls(@This());
}
