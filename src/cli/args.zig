const std = @import("std");
const init_mod = @import("../init/root.zig");
const validate_cmd = @import("commands/validate.zig");
const init_cmd = @import("commands/init.zig");
const prompt_cmd = @import("commands/prompt.zig");
const debug_cmd = @import("commands/debug.zig");

pub const Command = union(enum) {
    help,
    version,
    list_modules,
    validate: validate_cmd.Args,
    init: init_cmd.Args,
    prompt: prompt_cmd.Args,
    debug: debug_cmd.Args,
};

pub const Subcommand = enum {
    help,
    version,
    @"list-modules",
    validate,
    init,
    debug,
    prompt,
    flag_or_unknown,

    pub fn fromArg(arg: []const u8) Subcommand {
        if (std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return .help;
        if (std.mem.eql(u8, arg, "version") or std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) return .version;
        if (std.mem.eql(u8, arg, "list-modules")) return .@"list-modules";
        if (std.mem.eql(u8, arg, "validate")) return .validate;
        if (std.mem.eql(u8, arg, "init")) return .init;
        if (std.mem.eql(u8, arg, "debug")) return .debug;
        if (std.mem.eql(u8, arg, "prompt")) return .prompt;
        return .flag_or_unknown;
    }
};

const PromptFlag = enum {
    help,
    version,
    status,
    duration,
    shell,
    config,

    pub fn parse(flag: []const u8) ?PromptFlag {
        if (std.mem.eql(u8, flag, "--help") or std.mem.eql(u8, flag, "-h")) return .help;
        if (std.mem.eql(u8, flag, "--version") or std.mem.eql(u8, flag, "-v")) return .version;
        if (std.mem.eql(u8, flag, "--status") or std.mem.eql(u8, flag, "-s")) return .status;
        if (std.mem.eql(u8, flag, "--duration") or std.mem.eql(u8, flag, "-d") or std.mem.eql(u8, flag, "--cmd-duration")) return .duration;
        if (std.mem.eql(u8, flag, "--shell") or std.mem.eql(u8, flag, "-sh")) return .shell;
        if (std.mem.eql(u8, flag, "--config") or std.mem.eql(u8, flag, "-c")) return .config;
        return null;
    }
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

    const subcmd = Subcommand.fromArg(first_arg);
    return switch (subcmd) {
        .help => Command{ .help = {} },
        .version => Command{ .version = {} },
        .@"list-modules" => Command{ .list_modules = {} },
        .validate => try parseValidateArgs(&args),
        .init => try parseInitArgs(&args, exe_name),
        .debug => try parseDebugArgs(&args),
        .prompt => try parsePromptArgs(&args, init, null),
        .flag_or_unknown => {
            if (std.mem.startsWith(u8, first_arg, "-")) {
                return try parsePromptArgs(&args, init, first_arg);
            }
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "✖ Error: unknown command '{s}'. Run 'zap --help' for available commands.\n", .{first_arg}) catch "Error: unknown command.\n";
            _ = std.Io.File.stderr().writeStreamingAll(init.io, err_msg) catch {};
            return error.InvalidArgs;
        },
    };
}

fn parseValidateArgs(args: anytype) !Command {
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

fn parseInitArgs(args: anytype, exe_name: []const u8) !Command {
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

fn parseDebugArgs(args: anytype) !Command {
    var module_name: ?[]const u8 = null;
    var json_flag = false;
    var verbose_flag = false;
    var output_path: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_flag = true;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose_flag = true;
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            output_path = args.next();
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            module_name = arg;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return Command{ .help = {} };
        }
    }

    return Command{ .debug = .{
        .module_name = module_name,
        .json = json_flag,
        .verbose = verbose_flag,
        .output_path = output_path,
    } };
}

fn parsePromptArgs(
    args: anytype,
    init: std.process.Init,
    initial_arg: ?[]const u8,
) !Command {
    var res = Command{ .prompt = .{} };
    var positional_idx: usize = 0;

    var current_arg = initial_arg orelse args.next();

    while (current_arg) |arg| : (current_arg = args.next()) {
        if (PromptFlag.parse(arg)) |flag| {
            switch (flag) {
                .help => return Command{ .help = {} },
                .version => return Command{ .version = {} },
                .status => {
                    if (args.next()) |val| {
                        res.prompt.status_code = std.fmt.parseInt(u8, val, 10) catch {
                            printInvalidIntError(init.io, "--status", val);
                            return error.InvalidArgs;
                        };
                    }
                },
                .duration => {
                    if (args.next()) |val| {
                        res.prompt.cmd_duration = std.fmt.parseInt(u64, val, 10) catch {
                            printInvalidIntError(init.io, "--duration", val);
                            return error.InvalidArgs;
                        };
                    }
                },
                .shell => {
                    if (args.next()) |val| {
                        res.prompt.shell = init_mod.Shell.parse(val) orelse .generic;
                    }
                },
                .config => {
                    if (args.next()) |val| {
                        res.prompt.config_path = val;
                    }
                },
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (positional_idx == 0) {
                res.prompt.status_code = std.fmt.parseInt(u8, arg, 10) catch {
                    printInvalidIntError(init.io, "status code", arg);
                    return error.InvalidArgs;
                };
                positional_idx += 1;
            } else if (positional_idx == 1) {
                res.prompt.cmd_duration = std.fmt.parseInt(u64, arg, 10) catch {
                    printInvalidIntError(init.io, "duration", arg);
                    return error.InvalidArgs;
                };
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

fn printInvalidIntError(io: std.Io, name: []const u8, val: []const u8) void {
    var err_buf: [256]u8 = undefined;
    const err_msg = std.fmt.bufPrint(&err_buf, "✖ Error: invalid integer for {s} '{s}'.\n", .{ name, val }) catch "Error: invalid integer argument.\n";
    _ = std.Io.File.stderr().writeStreamingAll(io, err_msg) catch {};
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

test "integration: invalid integer argument produces error and non-zero exit" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    const res = try h.execZapAllowFail(&.{ "prompt", "--status", "not_a_number" });
    try testing.expectEqual(@as(u8, 1), res.exit_code);
    try Harness.expectContains(res.stderr, "invalid integer for --status 'not_a_number'");
}
