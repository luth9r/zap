const std = @import("std");
const registry = @import("../../../modules/registry.zig");
const context = @import("../../../engine/context.zig");
const config_mod = @import("../../../config/config.zig");
const toml_parser = @import("../../../config/toml_parser.zig");
const prompt_engine = @import("../../../engine/prompt.zig");
const formatter = @import("../../../engine/formatter.zig");
const git_utils = @import("../../../utils/git_utils.zig");
const BufferWriter = @import("../../../utils/buffer_writer.zig").BufferWriter;
const DebugContext = context.DebugContext;

/// Calculates visible Unicode codepoint width of a rendered prompt string, skipping ANSI escape sequences and shell markers.
pub fn computeVisibleWidth(str: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < str.len) {
        if (str[i] == '\x01' or str[i] == '\x02') {
            i += 1;
            continue;
        }
        if (i + 1 < str.len and str[i] == '%' and (str[i + 1] == '{' or str[i + 1] == '}')) {
            i += 2;
            continue;
        }
        if (str[i] == '\x1b' and i + 1 < str.len and str[i + 1] == '[') {
            i += 2;
            while (i < str.len and str[i] != 'm') : (i += 1) {}
            if (i < str.len) i += 1;
            continue;
        }
        if (str[i] == '\n' or str[i] == '\r') {
            i += 1;
            continue;
        }
        const cp_len = std.unicode.utf8ByteSequenceLength(str[i]) catch 1;
        if (i + cp_len > str.len) break;
        i += cp_len;
        width += 1;
    }
    return width;
}

/// Writes string with ANSI escape sequences escaped as literal `\x1b` and `\n` as `\n`.
pub fn writeEscapedAnsi(writer: anytype, str: []const u8, for_json: bool) !void {
    for (str) |c| {
        switch (c) {
            '\x1b' => try writer.writeAll(if (for_json) "\\\\x1b" else "\\x1b"),
            '\x01' => try writer.writeAll(if (for_json) "\\\\x01" else "\\x01"),
            '\x02' => try writer.writeAll(if (for_json) "\\\\x02" else "\\x02"),
            '\n' => try writer.writeAll(if (for_json) "\\\\n" else "\\n"),
            '\r' => try writer.writeAll(if (for_json) "\\\\r" else "\\r"),
            '"' => if (for_json) try writer.writeAll("\\\"") else try writer.writeByte('"'),
            '\\' => if (for_json) try writer.writeAll("\\\\") else try writer.writeByte('\\'),
            else => try writer.writeByte(c),
        }
    }
}

pub fn printPromptInspectorDebug(init: std.process.Init, writer: anytype, dctx: DebugContext) !void {
    const io = dctx.prompt.io orelse return;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const config_path_opt = toml_parser.resolveExistingConfigPath(init.io, &path_buf, init.environ_map);

    var config = config_mod.defaultConfig();
    var config_file_buf: [64 * 1024]u8 = undefined;

    if (config_path_opt) |config_path| {
        const file = if (std.fs.path.isAbsolute(config_path))
            std.Io.Dir.openFileAbsolute(init.io, config_path, .{}) catch null
        else
            std.Io.Dir.cwd().openFile(init.io, config_path, .{}) catch null;

        if (file) |f| {
            var handle = f;
            defer handle.close(init.io);
            var stream_buf: [4096]u8 = undefined;
            var reader = handle.reader(init.io, &stream_buf);
            const bytes_read = reader.interface.readSliceShort(&config_file_buf) catch 0;
            if (bytes_read > 0) {
                toml_parser.parseToml(&config, config_file_buf[0..bytes_read]);
            }
        }
    }

    const active_mask = prompt_engine.computeActiveModulesMask(config.format) | prompt_engine.computeActiveModulesMask(config.right_format);
    const decls = @typeInfo(registry).@"struct".decls;

    var git_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    var resolved_ctx = dctx.prompt;
    if (resolved_ctx.git_dir == null) {
        resolved_ctx.git_dir = git_utils.findGitDir(io, resolved_ctx.cwd, &git_dir_buf);
    }

    var vars: [decls.len]formatter.Variable(prompt_engine.ModuleVar) = undefined;
    var var_buffers: [decls.len][512]u8 = undefined;

    inline for (decls, 0..) |decl, i| {
        const mod = @field(registry, decl.name);
        const is_active = (active_mask & (@as(u64, 1) << @as(u6, @intCast(i)))) != 0;
        var pos: usize = 0;

        if (is_active) {
            const is_git_mod = @hasDecl(mod, "is_git_dependent") and mod.is_git_dependent;
            if (!is_git_mod or resolved_ctx.git_dir != null) {
                const mod_writer = BufferWriter.init(&var_buffers[i], &pos);
                const mod_cfg = @field(config, decl.name);
                try mod.render(mod_writer, mod_cfg, resolved_ctx);
            }
        }

        vars[i] = .{
            .name = @field(prompt_engine.ModuleVar, decl.name),
            .value = var_buffers[i][0..pos],
        };
    }

    var left_buf: [4096]u8 = undefined;
    var left_pos: usize = 0;
    const left_writer = BufferWriter.init(&left_buf, &left_pos);
    try formatter.formatTemplateWriter(left_writer, config.format, formatter.FormatContext(prompt_engine.ModuleVar){
        .vars = &vars,
        .shell = resolved_ctx.shell,
    });
    const left_rendered = left_buf[0..left_pos];
    const left_visible = computeVisibleWidth(left_rendered);

    var right_buf: [2048]u8 = undefined;
    var right_pos: usize = 0;
    if (config.right_format.len > 0) {
        const right_writer = BufferWriter.init(&right_buf, &right_pos);
        try formatter.formatTemplateWriter(right_writer, config.right_format, formatter.FormatContext(prompt_engine.ModuleVar){
            .vars = &vars,
            .shell = resolved_ctx.shell,
        });
    }
    const right_rendered = right_buf[0..right_pos];
    const right_visible = computeVisibleWidth(right_rendered);

    if (dctx.json) {
        try writer.writeAll("{ \"target\": \"prompt\", \"format\": \"");
        try writeEscapedAnsi(writer, config.format, true);
        try writer.writeAll("\", \"right_format\": \"");
        try writeEscapedAnsi(writer, config.right_format, true);
        try writer.print("\", \"left_bytes\": {d}, \"left_visible_chars\": {d}, \"right_bytes\": {d}, \"right_visible_chars\": {d}, \"modules\": [", .{
            left_rendered.len,
            left_visible,
            right_rendered.len,
            right_visible,
        });

        var first = true;
        inline for (decls, 0..) |decl, i| {
            const is_active = (active_mask & (@as(u64, 1) << @as(u6, @intCast(i)))) != 0;
            if (is_active) {
                if (!first) try writer.writeAll(", ");
                const val = vars[i].value;
                try writer.print("{{ \"name\": \"{s}\", \"bytes\": {d}, \"visible_chars\": {d}, \"raw\": \"", .{
                    decl.name,
                    val.len,
                    computeVisibleWidth(val),
                });
                try writeEscapedAnsi(writer, val, true);
                try writer.writeAll("\" }");
                first = false;
            }
        }
        try writer.writeAll("], \"rendered_left\": \"");
        try writeEscapedAnsi(writer, left_rendered, true);
        try writer.writeAll("\", \"rendered_right\": \"");
        try writeEscapedAnsi(writer, right_rendered, true);
        try writer.writeAll("\" }\n");
    } else {
        try writer.print(
            \\⚡ Zap Prompt Render & AST Inspector
            \\
            \\Templates:
            \\  Format:           "{s}"
            \\  Right Format:     "{s}"
            \\  Target Shell:     {s}
            \\
            \\Active Module Outputs:
            \\
        , .{
            config.format,
            if (config.right_format.len > 0) config.right_format else "(not configured)",
            @tagName(resolved_ctx.shell),
        });

        inline for (decls, 0..) |decl, i| {
            const is_active = (active_mask & (@as(u64, 1) << @as(u6, @intCast(i)))) != 0;
            if (is_active) {
                const val = vars[i].value;
                const vis = computeVisibleWidth(val);
                if (val.len > 0) {
                    try writer.print("  ✔ ${s:<14} ({d:>2} bytes, {d:>2} chars): {s}\n", .{ decl.name, val.len, vis, val });
                    if (dctx.verbose) {
                        try writer.writeAll("    └─ ANSI Raw:    \"");
                        try writeEscapedAnsi(writer, val, false);
                        try writer.writeAll("\"\n");
                    }
                } else {
                    try writer.print("  · ${s:<14} (empty in current context)\n", .{decl.name});
                }
            }
        }

        try writer.print(
            \\
            \\Assembled Left Prompt ({d} bytes, {d} visible chars):
            \\  Visual Preview:   {s}
            \\  Escaped Raw:      "
        , .{ left_rendered.len, left_visible, left_rendered });
        try writeEscapedAnsi(writer, left_rendered, false);
        try writer.writeAll("\"\n");

        if (config.right_format.len > 0) {
            try writer.print(
                \\
                \\Assembled Right Prompt ({d} bytes, {d} visible chars):
                \\  Visual Preview:   {s}
                \\  Escaped Raw:      "
            , .{ right_rendered.len, right_visible, right_rendered });
            try writeEscapedAnsi(writer, right_rendered, false);
            try writer.writeAll("\"\n");
        }
    }
}
