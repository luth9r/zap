const std = @import("std");
const builtin = @import("builtin");

pub const HOOK_TEMPLATE = "eval \"$({s} init zsh)\"";

pub const SCRIPT =
    \\# Zap prompt integration for Zsh
    \\
    \\_zap_start_time=""
    \\
    \\_zap_preexec() {
    \\    _zap_start_time="${EPOCHREALTIME:-$EPOCHSECONDS}"
    \\}
    \\
    \\_zap_precmd() {
    \\    local exit_code=$?
    \\    local duration=0
    \\
    \\    if [[ -n "$_zap_start_time" ]]; then
    \\        local end_time="${EPOCHREALTIME:-$EPOCHSECONDS}"
    \\        if [[ "$_zap_start_time" == *"."* && "$end_time" == *"."* ]]; then
    \\            local start_s="${_zap_start_time%.*}"
    \\            local start_us="${_zap_start_time#*.}"
    \\            local end_s="${end_time%.*}"
    \\            local end_us="${end_time#*.}"
    \\            start_us="${(r:6::0:)start_us}"
    \\            end_us="${(r:6::0:)end_us}"
    \\            local diff_s=$(( end_s - start_s ))
    \\            local diff_us=$(( end_us - start_us ))
    \\            duration=$(( diff_s * 1000 + diff_us / 1000 ))
    \\        else
    \\            duration=$(( (end_time - _zap_start_time) * 1000 ))
    \\        fi
    \\        _zap_start_time=""
    \\    fi
    \\
    \\    PROMPT="$("{{EXE}}" prompt --status "$exit_code" --duration "$duration" --shell zsh)"
    \\}
    \\
    \\autoload -Uz add-zsh-hook
    \\add-zsh-hook precmd _zap_precmd
    \\add-zsh-hook preexec _zap_preexec
    \\
;

const testing = std.testing;
const init_mod = @import("root.zig");
const prompt = @import("../engine/prompt.zig");
const config_mod = @import("../config/config.zig");
const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;
const Harness = @import("../tests/harness.zig").Harness;

test "unit: init zsh script generation" {
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    try init_mod.renderInitScript(writer, .zsh, "zap");
    const script = buf[0..pos];

    try testing.expect(std.mem.indexOf(u8, script, "add-zsh-hook precmd _zap_precmd") != null);
    try testing.expect(std.mem.indexOf(u8, script, "add-zsh-hook preexec _zap_preexec") != null);
    try testing.expect(std.mem.indexOf(u8, script, "\"zap\" prompt --status") != null);
    try testing.expect(std.mem.indexOf(u8, script, "{{EXE}}") == null);
}

test "unit: prompt render with zsh zero-width escapes" {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    var cfg = config_mod.defaultConfig();
    cfg.add_newline = false;

    try prompt.render(writer, cfg, .{
        .cwd = "/home/user/zap",
        .home = "/home/user",
        .status_code = 0,
        .shell = .zsh,
    });

    const rendered = buf[0..pos];
    // Must contain zsh zero-width markers %{ and %}
    try testing.expect(std.mem.indexOf(u8, rendered, "%{") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "%}") != null);
    // Must not contain bash markers \x01 or \x02
    try testing.expect(std.mem.indexOfScalar(u8, rendered, '\x01') == null);
    try testing.expect(std.mem.indexOfScalar(u8, rendered, '\x02') == null);
}

test "integration: real zsh session with auto-installed zap hook and config" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.git(&.{ "checkout", "-b", "zsh-branch" });

    try h.writeFile(".config/zap/zap.toml",
        \\format = "$directory$git_branch$character"
        \\add_newline = false
    );

    const install_res = try h.execZapAllowFail(&.{ "init", "zsh", "--install" });
    try testing.expectEqual(@as(u8, 0), install_res.exit_code);

    const alloc = h.arena.allocator();
    const cmd = try std.fmt.allocPrint(alloc, "source \"{s}/.zshrc\"; _zap_precmd; echo -n \"$PROMPT\"", .{h.tmp_dir});

    const home_env = try std.fmt.allocPrint(alloc, "HOME={s}", .{h.tmp_dir});
    const xdg_env = try std.fmt.allocPrint(alloc, "XDG_CONFIG_HOME={s}/.config", .{h.tmp_dir});
    const zap_dir = std.fs.path.dirname(h.zap_bin) orelse ".";
    const path_env = if (builtin.os.tag == .windows)
        try std.fmt.allocPrint(alloc, "PATH={s};C:\\Windows\\System32;C:\\Windows", .{zap_dir})
    else
        try std.fmt.allocPrint(alloc, "PATH={s}:/usr/bin:/bin:/usr/local/bin", .{zap_dir});

    const argv = [_][]const u8{
        "env",
        home_env,
        xdg_env,
        path_env,
        "zsh",
        "-f",
        "+Z",
        "-c",
        cmd,
    };

    var child = std.process.spawn(std.testing.io, .{
        .argv = &argv,
        .cwd = .{ .path = h.tmp_dir },
        .stdout = .pipe,
        .stderr = .pipe,
        .stdin = .ignore,
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };

    var stream_buf: [512]u8 = undefined;
    var reader = child.stdout.?.reader(std.testing.io, &stream_buf);
    var out_buf: [4096]u8 = undefined;
    const n = try reader.interface.readSliceShort(&out_buf);
    const term = try child.wait(std.testing.io);
    if (term == .exited and term.exited == 127) return;

    const zsh_prompt_out = out_buf[0..n];
    try Harness.expectContains(zsh_prompt_out, "zsh-branch");
    try Harness.expectContains(zsh_prompt_out, "❯");
    try Harness.expectAnsi(zsh_prompt_out, .zsh);
}
