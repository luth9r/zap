const std = @import("std");
const config_mod = @import("../../config/config.zig");
const toml_parser = @import("../../config/toml_parser.zig");
const prompt = @import("../../engine/prompt.zig");
const init_mod = @import("../../init/root.zig");
const BufferWriter = @import("../../utils/buffer_writer.zig").BufferWriter;

pub const Args = struct {
    status_code: u8 = 0,
    cmd_duration: u64 = 0,
    shell: init_mod.Shell = .generic,
    config_path: ?[]const u8 = null,
};

pub fn execute(init: std.process.Init, prompt_args: Args) !void {
    var config = config_mod.defaultConfig();
    var config_file_buf: [64 * 1024]u8 = undefined;

    if (prompt_args.config_path) |custom_path| {
        const file_res = if (std.fs.path.isAbsolute(custom_path))
            std.Io.Dir.openFileAbsolute(init.io, custom_path, .{})
        else
            std.Io.Dir.cwd().openFile(init.io, custom_path, .{});

        if (file_res) |f| {
            var file = f;
            defer file.close(init.io);
            var stream_buf: [4096]u8 = undefined;
            var reader = file.reader(init.io, &stream_buf);
            const bytes_read = reader.interface.readSliceShort(&config_file_buf) catch 0;
            if (bytes_read > 0) {
                toml_parser.parseToml(&config, config_file_buf[0..bytes_read]);
            }
        } else |_| {}
    } else {
        toml_parser.loadConfigFile(init.io, init.environ_map, &config, &config_file_buf);
    }

    const home_path = resolveHomePath(init);
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = resolveCwdPath(init, &cwd_buf);

    var prompt_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&prompt_buf, &pos);

    try prompt.render(writer, config, .{
        .cwd = cwd_path,
        .home = home_path,
        .status_code = prompt_args.status_code,
        .cmd_duration = prompt_args.cmd_duration,
        .shell = prompt_args.shell,
        .io = init.io,
    });

    try std.Io.File.stdout().writeStreamingAll(init.io, prompt_buf[0..pos]);
}

pub fn resolveHomePath(init: std.process.Init) []const u8 {
    return init.environ_map.get("HOME") orelse init.environ_map.get("USERPROFILE") orelse ".";
}

pub fn resolveCwdPath(init: std.process.Init, buf: *[std.fs.max_path_bytes]u8) []const u8 {
    if (init.environ_map.get("PWD")) |pwd| {
        return pwd;
    }

    const cwd: std.Io.Dir = .cwd();
    const pwd_file = cwd.openFile(init.io, ".", .{}) catch return ".";
    defer pwd_file.close(init.io);

    const len = pwd_file.realPath(init.io, buf) catch return ".";
    return buf[0..len];
}

const testing = std.testing;
const Harness = @import("../../tests/harness.zig").Harness;

test "integration: zap prompt CLI flags support" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.writeFile("custom.toml",
        \\format = "$character"
        \\add_newline = false
        \\
        \\[character]
        \\success_symbol = "[OK](bold green)"
        \\error_symbol = "[ERR](bold red)"
    );

    // Test --status 1 and --config custom.toml
    const res_err = try h.execZap(&.{ "prompt", "--status", "1", "--config", "custom.toml" });
    try Harness.expectContains(res_err, "ERR");

    // Test --status 0
    const res_ok = try h.execZap(&.{ "prompt", "--status", "0", "--config", "custom.toml" });
    try Harness.expectContains(res_ok, "OK");
}

test "integration: zap prompt respects CMD_DURATION environment variable" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.writeFile(".config/zap/zap.toml",
        \\format = "$cmd_duration"
        \\add_newline = false
        \\
        \\[cmd_duration]
        \\min_time = 1000
        \\show_milliseconds = false
    );

    const alloc = h.arena.allocator();
    const env_home = try std.fmt.allocPrint(alloc, "HOME={s}", .{h.tmp_dir});
    const env_xdg = try std.fmt.allocPrint(alloc, "XDG_CONFIG_HOME={s}/.config", .{h.tmp_dir});
    const env_dur = "CMD_DURATION=3500";

    const argv = [_][]const u8{
        "env",
        env_home,
        env_xdg,
        env_dur,
        h.zap_bin,
        "prompt",
    };

    var child = try std.process.spawn(std.testing.io, .{
        .argv = &argv,
        .cwd = .{ .path = h.tmp_dir },
        .stdout = .pipe,
        .stderr = .pipe,
        .stdin = .ignore,
    });

    var stream_buf: [512]u8 = undefined;
    var reader = child.stdout.?.reader(std.testing.io, &stream_buf);
    var out_buf: [1024]u8 = undefined;
    const n = try reader.interface.readSliceShort(&out_buf);
    _ = try child.wait(std.testing.io);

    const out = out_buf[0..n];
    try Harness.expectContains(out, "3s");
}
