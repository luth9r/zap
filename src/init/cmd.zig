const std = @import("std");

pub const HOOK_TEMPLATE = "local h=io.popen('\"{s}\" init cmd');if h then local s=h:read('*a');h:close();local f=load(s);if f then f() end end";

pub const SCRIPT =
    \\-- Zap prompt integration for cmd.exe (via Clink)
    \\
    \\local _zap_start_time = nil
    \\local _zap_first_prompt = true
    \\
    \\if clink.onendedit then
    \\    clink.onendedit(function()
    \\        _zap_start_time = os.clock()
    \\    end)
    \\end
    \\
    \\local p = clink.promptfilter(1)
    \\function p:filter(prompt)
    \\    local status = os.geterrorlevel and os.geterrorlevel() or 0
    \\    local duration = 0
    \\    if _zap_start_time then
    \\        duration = math.floor((os.clock() - _zap_start_time) * 1000)
    \\        _zap_start_time = nil
    \\    end
    \\
    \\    local flags = "--status " .. status .. " --duration " .. duration .. " --shell cmd"
    \\    if _zap_first_prompt then
    \\        _zap_first_prompt = false
    \\        flags = flags .. " --no-newline"
    \\    end
    \\
    \\    local handle = io.popen('"{{EXE}}" prompt ' .. flags)
    \\    if not handle then return prompt end
    \\    local out = handle:read("*a")
    \\    handle:close()
    \\
    \\    if out and #out > 0 then
    \\        return out, false
    \\    end
    \\    return prompt
    \\end
    \\
;

const testing = std.testing;
const init_mod = @import("root.zig");
const prompt = @import("../engine/prompt.zig");
const config_mod = @import("../config/config.zig");
const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;

test "unit: init cmd script generation" {
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    try init_mod.renderInitScript(writer, .cmd, "zap");
    const script = buf[0..pos];

    try testing.expect(std.mem.indexOf(u8, script, "clink.promptfilter") != null);
    try testing.expect(std.mem.indexOf(u8, script, "\"zap\" prompt ") != null);
    try testing.expect(std.mem.indexOf(u8, script, "{{EXE}}") == null);
}

test "unit: prompt render with cmd raw escapes" {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    var cfg = config_mod.defaultConfig();
    cfg.add_newline = false;

    try prompt.render(writer, cfg, .{
        .cwd = "C:\\Users\\user\\zap",
        .home = "C:\\Users\\user",
        .status_code = 0,
        .shell = .cmd,
    });

    const rendered = buf[0..pos];
    try testing.expect(std.mem.indexOfScalar(u8, rendered, '\x01') == null);
    try testing.expect(std.mem.indexOfScalar(u8, rendered, '\x02') == null);
    try testing.expect(std.mem.indexOf(u8, rendered, "%{") == null);
    try testing.expect(std.mem.indexOf(u8, rendered, "%}") == null);
}
