const std = @import("std");

pub const HOOK_TEMPLATE = "eval \"$({s} init bash)\"";

pub const SCRIPT =
    \\# Zap prompt integration for Bash
    \\
    \\_zap_start_time=""
    \\_zap_preexec_ready="true"
    \\_zap_first_prompt="1"
    \\
    \\_zap_preexec() {
    \\    if [ "$_zap_preexec_ready" = "true" ]; then
    \\        _zap_preexec_ready="false"
    \\        if [ -n "$EPOCHREALTIME" ]; then
    \\            _zap_start_time="$EPOCHREALTIME"
    \\        else
    \\            _zap_start_time="$(date +%s 2>/dev/null || echo 0)000"
    \\        fi
    \\    fi
    \\}
    \\
    \\_zap_prompt_command() {
    \\    local exit_code=$?
    \\    local duration=0
    \\
    \\    if [ -n "$_zap_start_time" ]; then
    \\        local end_time
    \\        if [ -n "$EPOCHREALTIME" ]; then
    \\            end_time="$EPOCHREALTIME"
    \\        else
    \\            end_time="$(date +%s 2>/dev/null || echo 0)000"
    \\        fi
    \\        if [[ "$_zap_start_time" == *"."* && "$end_time" == *"."* ]]; then
    \\            local start_s="${_zap_start_time%.*}"
    \\            local start_us="${_zap_start_time#*.}"
    \\            local end_s="${end_time%.*}"
    \\            local end_us="${end_time#*.}"
    \\            start_us=$(printf "%-6s" "$start_us" | tr ' ' '0')
    \\            end_us=$(printf "%-6s" "$end_us" | tr ' ' '0')
    \\            local diff_s=$(( 10#$end_s - 10#$start_s ))
    \\            local diff_us=$(( 10#$end_us - 10#$start_us ))
    \\            duration=$(( diff_s * 1000 + diff_us / 1000 ))
    \\        else
    \\            duration=$(( end_time - _zap_start_time ))
    \\        fi
    \\        _zap_start_time=""
    \\    fi
    \\    _zap_preexec_ready="true"
    \\
    \\    if [ "$_zap_first_prompt" = "1" ]; then
    \\        _zap_first_prompt="0"
    \\        PS1="$("{{EXE}}" prompt --status "$exit_code" --duration "${duration:-0}" --shell bash --no-newline)"
    \\    else
    \\        PS1="$("{{EXE}}" prompt --status "$exit_code" --duration "${duration:-0}" --shell bash)"
    \\    fi
    \\}
    \\
    \\if [[ ! "$PROMPT_COMMAND" =~ _zap_prompt_command ]]; then
    \\    PROMPT_COMMAND="_zap_prompt_command${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
    \\fi
    \\
    \\if ! type preexec >/dev/null 2>&1; then
    \\    trap '_zap_preexec' DEBUG
    \\fi
    \\
;

const testing = std.testing;
const init_mod = @import("root.zig");
const prompt = @import("../engine/prompt.zig");
const config_mod = @import("../config/config.zig");
const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;
const Harness = @import("../tests/harness.zig").Harness;

test "unit: init bash script generation" {
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    try init_mod.renderInitScript(writer, .bash, "zap");
    const script = buf[0..pos];

    try testing.expect(std.mem.indexOf(u8, script, "PROMPT_COMMAND") != null);
    try testing.expect(std.mem.indexOf(u8, script, "_zap_prompt_command") != null);
    try testing.expect(std.mem.indexOf(u8, script, "\"zap\" prompt --status") != null);
    try testing.expect(std.mem.indexOf(u8, script, "{{EXE}}") == null);
}

test "unit: prompt render with bash zero-width escapes" {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    var cfg = config_mod.defaultConfig();
    cfg.add_newline = false;

    try prompt.render(writer, cfg, .{
        .cwd = "/home/user/zap",
        .home = "/home/user",
        .status_code = 0,
        .shell = .bash,
    });

    const rendered = buf[0..pos];
    // Must contain bash zero-width markers \x01 and \x02
    try testing.expect(std.mem.indexOfScalar(u8, rendered, '\x01') != null);
    try testing.expect(std.mem.indexOfScalar(u8, rendered, '\x02') != null);
    // Must not contain zsh markers %{ or %}
    try testing.expect(std.mem.indexOf(u8, rendered, "%{") == null);
}

test "integration: real bash session with auto-installed zap hook and config" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    // 1. Setup git repo
    try h.setupGit();
    try h.git(&.{ "checkout", "-b", "feature-shell-test" });

    // 2. Generate zap config
    try h.writeFile(".config/zap/zap.toml",
        \\format = "$directory$git_branch$character"
        \\add_newline = false
        \\
        \\[directory]
        \\style = "bold cyan"
        \\
        \\[git_branch]
        \\style = "bold purple"
        \\
        \\[character]
        \\success_symbol = "[❯](bold green)"
        \\error_symbol = "[✗](bold red)"
    );

    // 3. Install hook into .bashrc via zap CLI
    const install_res = try h.execZapAllowFail(&.{ "init", "bash", "--install" });
    try testing.expectEqual(@as(u8, 0), install_res.exit_code);
    try Harness.expectContains(install_res.stdout, "Successfully installed");

    // 4. Run real bash subprocess sourcing the generated .bashrc
    const cmd = try std.fmt.allocPrint(h.arena.allocator(), "source \"{s}/.bashrc\" && _zap_prompt_command && echo -n \"$PS1\"", .{h.tmp_dir});
    const bash_prompt_out = (try h.runShellScript(&.{ "bash", "--noprofile", "--norc", "-c", cmd })) orelse return;
    try Harness.expectContains(bash_prompt_out, "feature-shell-test");
    try Harness.expectContains(bash_prompt_out, "❯");
    try Harness.expectAnsi(bash_prompt_out, .bash);
}
