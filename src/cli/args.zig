const std = @import("std");
const init_mod = @import("../init/root.zig");
const validate_cmd = @import("commands/validate.zig");
const init_cmd = @import("commands/init.zig");
const prompt_cmd = @import("commands/prompt.zig");

pub const Command = union(enum) {
    help,
    version,
    list_modules,
    validate: validate_cmd.Args,
    init: init_cmd.Args,
    prompt: prompt_cmd.Args,
};

pub fn parseCommand(init: std.process.Init, allocator: std.mem.Allocator) !Command {
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();

    const raw_exe = args.next() orelse "zap";
    const exe_basename = std.fs.path.basename(raw_exe);
    const exe_name = if (exe_basename.len > 0) exe_basename else "zap";

    const first_arg = args.next() orelse {
        var p = Command{ .prompt = .{} };
        if (init.environ_map.get("CMD_DURATION")) |cmd_dur_env| {
            p.prompt.cmd_duration = std.fmt.parseInt(u64, cmd_dur_env, 10) catch 0;
        }
        return p;
    };

    if (std.mem.eql(u8, first_arg, "--help") or std.mem.eql(u8, first_arg, "-h") or std.mem.eql(u8, first_arg, "help")) {
        return Command{ .help = {} };
    }

    if (std.mem.eql(u8, first_arg, "--version") or std.mem.eql(u8, first_arg, "-v") or std.mem.eql(u8, first_arg, "version")) {
        return Command{ .version = {} };
    }

    if (std.mem.eql(u8, first_arg, "list-modules")) {
        return Command{ .list_modules = {} };
    }

    if (std.mem.eql(u8, first_arg, "validate")) {
        var config_path: ?[]const u8 = null;
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
                config_path = args.next();
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                config_path = arg;
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                return Command{ .help = {} };
            }
        }
        return Command{ .validate = .{ .config_path = config_path } };
    }

    if (std.mem.eql(u8, first_arg, "init")) {
        var target_shell: init_mod.Shell = .generic;
        var install_flag = false;

        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--install") or std.mem.eql(u8, arg, "-i")) {
                install_flag = true;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                if (init_mod.Shell.parse(arg)) |sh| {
                    target_shell = sh;
                }
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                return Command{ .help = {} };
            }
        }

        return Command{ .init = .{
            .shell = target_shell,
            .exe_name = exe_name,
            .install = install_flag,
        } };
    }

    const is_prompt_command = std.mem.eql(u8, first_arg, "prompt");
    const is_flag = std.mem.startsWith(u8, first_arg, "-");

    if (!is_prompt_command and !is_flag) {
        var err_buf: [256]u8 = undefined;
        const err_msg = std.fmt.bufPrint(&err_buf, "✖ Error: unknown command '{s}'. Run 'zap --help' for available commands.\n", .{first_arg}) catch "Error: unknown command.\n";
        _ = std.Io.File.stderr().writeStreamingAll(init.io, err_msg) catch {};
        return error.InvalidArgs;
    }

    var res = Command{ .prompt = .{} };
    var positional_idx: usize = 0;

    var current_arg: ?[]const u8 = first_arg;
    if (is_prompt_command) {
        current_arg = args.next();
    }

    while (current_arg) |arg| : (current_arg = args.next()) {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return Command{ .help = {} };
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            return Command{ .version = {} };
        } else if (std.mem.eql(u8, arg, "--status") or std.mem.eql(u8, arg, "-s")) {
            if (args.next()) |val| {
                res.prompt.status_code = std.fmt.parseInt(u8, val, 10) catch 0;
            }
        } else if (std.mem.eql(u8, arg, "--duration") or std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--cmd-duration")) {
            if (args.next()) |val| {
                res.prompt.cmd_duration = std.fmt.parseInt(u64, val, 10) catch 0;
            }
        } else if (std.mem.eql(u8, arg, "--shell") or std.mem.eql(u8, arg, "-sh")) {
            if (args.next()) |val| {
                res.prompt.shell = init_mod.Shell.parse(val) orelse .generic;
            }
        } else if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
            if (args.next()) |val| {
                res.prompt.config_path = val;
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (positional_idx == 0) {
                res.prompt.status_code = std.fmt.parseInt(u8, arg, 10) catch 0;
                positional_idx += 1;
            } else if (positional_idx == 1) {
                res.prompt.cmd_duration = std.fmt.parseInt(u64, arg, 10) catch 0;
                positional_idx += 1;
            }
        } else {
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "✖ Error: unrecognized flag '{s}'. Run 'zap --help' for usage.\n", .{arg}) catch "Error: unrecognized flag.\n";
            _ = std.Io.File.stderr().writeStreamingAll(init.io, err_msg) catch {};
            return error.InvalidArgs;
        }
    }

    if (res.prompt.cmd_duration == 0) {
        if (init.environ_map.get("CMD_DURATION")) |cmd_dur_env| {
            res.prompt.cmd_duration = std.fmt.parseInt(u64, cmd_dur_env, 10) catch 0;
        }
    }

    return res;
}

const testing = std.testing;
const Harness = @import("../tests/harness.zig").Harness;

test "integration: unrecognized flag produces error and non-zero exit" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    const res = try h.execZapAllowFail(&.{"--invalid-flag-123"});
    try testing.expectEqual(@as(u8, 1), res.exit_code);
    try Harness.expectContains(res.stderr, "unrecognized flag");
}

test "integration: unknown command produces error and non-zero exit" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    const res = try h.execZapAllowFail(&.{"foobar_unknown_cmd"});
    try testing.expectEqual(@as(u8, 1), res.exit_code);
    try Harness.expectContains(res.stderr, "unknown command 'foobar_unknown_cmd'");
    try Harness.expectContains(res.stderr, "Run 'zap --help' for available commands");
}
