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

fn getTimestampNs(io: std.Io) u64 {
    const ts = std.Io.Clock.awake.now(io);
    return @intCast(@max(0, ts.toNanoseconds()));
}

fn writeBar(writer: anytype, percent: usize, comptime max_width: usize) !void {
    try writer.writeByte('[');
    const filled = if (percent >= 100)
        max_width
    else if (percent > 0)
        @max(@as(usize, 1), (percent * max_width) / 100)
    else
        0;

    var i: usize = 0;
    while (i < filled) : (i += 1) {
        try writer.writeAll("■");
    }
    while (i < max_width) : (i += 1) {
        try writer.writeAll("·");
    }
    try writer.writeByte(']');
}

pub fn printTimingsDebug(init: std.process.Init, writer: anytype, dctx: DebugContext) !void {
    try runProfilerAndBenchmark(init, writer, dctx, false, 0);
}

pub fn printPromptProfileDebug(init: std.process.Init, writer: anytype, dctx: DebugContext, iterations: usize) !void {
    try runProfilerAndBenchmark(init, writer, dctx, true, iterations);
}

fn runProfilerAndBenchmark(
    init: std.process.Init,
    writer: anytype,
    dctx: DebugContext,
    run_bench: bool,
    requested_iterations: usize,
) !void {
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

    const active_mask = prompt_engine.computeActiveModulesMask(config.format);
    const decls = @typeInfo(registry).@"struct".decls;

    const git_modules_mask = comptime blk: {
        const d = @typeInfo(registry).@"struct".decls;
        var m: u64 = 0;
        for (d, 0..) |decl, idx| {
            const m_mod = @field(registry, decl.name);
            if (@hasDecl(m_mod, "is_git_dependent") and m_mod.is_git_dependent) {
                m |= @as(u64, 1) << @as(u6, @intCast(idx));
            }
        }
        break :blk m;
    };
    const dir_needs_git = config.directory.truncate_to_repo and (active_mask & prompt_engine.computeActiveModulesMask("$directory")) != 0;
    const should_check_git = ((active_mask & git_modules_mask) != 0 or dir_needs_git) and dctx.prompt.git_dir == null;

    var git_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    var resolved_ctx = dctx.prompt;
    var git_dur_ns: u64 = 0;
    if (should_check_git) {
        const t0 = getTimestampNs(io);
        resolved_ctx.git_dir = git_utils.findGitDir(io, resolved_ctx.cwd, &git_dir_buf);
        const t1 = getTimestampNs(io);
        git_dur_ns = if (t1 > t0) t1 - t0 else 0;
    }

    const ModuleProfile = struct {
        name: []const u8,
        active: bool,
        duration_ns: u64,
        bytes: usize,
    };

    var profiles: [decls.len]ModuleProfile = undefined;
    var vars: [decls.len]formatter.Variable(prompt_engine.ModuleVar) = undefined;
    var var_buffers: [decls.len][512]u8 = undefined;

    const single_run_t0 = getTimestampNs(io);

    inline for (decls, 0..) |decl, i| {
        const mod = @field(registry, decl.name);
        const is_active = (active_mask & (@as(u64, 1) << @as(u6, @intCast(i)))) != 0;
        var pos: usize = 0;
        var mod_dur_ns: u64 = 0;

        if (is_active) {
            const is_git_mod = (git_modules_mask & (@as(u64, 1) << @as(u6, @intCast(i)))) != 0;
            if (!is_git_mod or resolved_ctx.git_dir != null) {
                const mod_writer = BufferWriter.init(&var_buffers[i], &pos);
                const mod_cfg = @field(config, decl.name);
                const m_t0 = getTimestampNs(io);
                try mod.render(mod_writer, mod_cfg, resolved_ctx);
                const m_t1 = getTimestampNs(io);
                mod_dur_ns = if (m_t1 > m_t0) m_t1 - m_t0 else 0;
            }
        }

        vars[i] = .{
            .name = @field(prompt_engine.ModuleVar, decl.name),
            .value = var_buffers[i][0..pos],
        };

        profiles[i] = .{
            .name = decl.name,
            .active = is_active,
            .duration_ns = mod_dur_ns,
            .bytes = pos,
        };
    }

    var rendered_prompt_buf: [4096]u8 = undefined;
    var rendered_pos: usize = 0;
    const prompt_writer = BufferWriter.init(&rendered_prompt_buf, &rendered_pos);
    if (config.add_newline) {
        try prompt_writer.writeByte('\n');
    }
    const fmt_t0 = getTimestampNs(io);
    try formatter.formatTemplateWriter(prompt_writer, config.format, formatter.FormatContext(prompt_engine.ModuleVar){
        .vars = &vars,
        .shell = resolved_ctx.shell,
    });
    const fmt_t1 = getTimestampNs(io);
    const fmt_dur_ns = if (fmt_t1 > fmt_t0) fmt_t1 - fmt_t0 else 0;
    const single_run_t1 = getTimestampNs(io);
    const single_run_total_ns = if (single_run_t1 > single_run_t0) single_run_t1 - single_run_t0 else 0;

    if (!run_bench) {
        if (dctx.json) {
            try writer.print(
                \\{{ "target": "timings", "total_render_us": {d}, "format_duration_us": {d}, "git_discovery_us": {d}, "buffer_used_bytes": {d}, "buffer_capacity_bytes": {d}, "modules": [
            , .{
                @divTrunc(single_run_total_ns, 1000),
                @divTrunc(fmt_dur_ns, 1000),
                @divTrunc(git_dur_ns, 1000),
                rendered_pos,
                rendered_prompt_buf.len,
            });
            for (profiles, 0..) |p, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print(
                    \\{{ "name": "{s}", "active": {}, "duration_us": {d}, "bytes": {d} }}
                , .{
                    p.name,
                    p.active,
                    @divTrunc(p.duration_ns, 1000),
                    p.bytes,
                });
            }
            try writer.writeAll(" ] }\n");
        } else {
            try writer.print(
                \\⚡ Zap Single-Pass Timing Profiler
                \\
                \\Configuration:
                \\  Add Newline:      {}
                \\  Buffer Usage:     {d} / {d} bytes ({d}.{d}% utilized)
                \\
                \\Per-Module Execution Breakdown (Single Pass):
                \\
            , .{
                config.add_newline,
                rendered_pos,
                rendered_prompt_buf.len,
                (rendered_pos * 100) / rendered_prompt_buf.len,
                ((rendered_pos * 1000) / rendered_prompt_buf.len) % 10,
            });

            for (profiles) |p| {
                if (p.active) {
                    const mod_us = @divTrunc(p.duration_ns, 1000);
                    const percent = if (single_run_total_ns > 0) (p.duration_ns * 100) / single_run_total_ns else 0;
                    try writer.print("  ✔ {s:<15} {d:>6} µs  [{d:>3}%]  ({d:>2} bytes)  ", .{ p.name, mod_us, percent, p.bytes });
                    try writeBar(writer, percent, 20);
                    try writer.writeByte('\n');
                } else {
                    try writer.print("  · {s:<15}      0 µs  (inactive)\n", .{p.name});
                }
            }

            const modules_dur_ns = if (single_run_total_ns > (git_dur_ns + fmt_dur_ns))
                single_run_total_ns - (git_dur_ns + fmt_dur_ns)
            else
                0;
            const git_pct = if (single_run_total_ns > 0) (git_dur_ns * 100) / single_run_total_ns else 0;
            const mod_pct = if (single_run_total_ns > 0) (modules_dur_ns * 100) / single_run_total_ns else 0;
            const fmt_pct = if (single_run_total_ns > 0) (fmt_dur_ns * 100) / single_run_total_ns else 0;

            try writer.print(
                \\
                \\Pipeline Stages:
                \\  Git Resolution:   {d:>6} µs  [{d:>3}%]  
            , .{ @divTrunc(git_dur_ns, 1000), git_pct });
            try writeBar(writer, git_pct, 20);
            try writer.print(
                \\
                \\  Render Modules:   {d:>6} µs  [{d:>3}%]  
            , .{ @divTrunc(modules_dur_ns, 1000), mod_pct });
            try writeBar(writer, mod_pct, 20);
            try writer.print(
                \\
                \\  Template Format:  {d:>6} µs  [{d:>3}%]  
            , .{ @divTrunc(fmt_dur_ns, 1000), fmt_pct });
            try writeBar(writer, fmt_pct, 20);

            try writer.print(
                \\
                \\  Total Single-Run: {d:>6} µs ({d}.{d:0>3} ms)
                \\
            , .{
                @divTrunc(single_run_total_ns, 1000),
                @divTrunc(single_run_total_ns, 1_000_000),
                @divTrunc(@mod(single_run_total_ns, 1_000_000), 1000),
            });
        }
        return;
    }

    // Multi-pass benchmark (default 100 iterations, capped at 2000 on stack)
    const MaxStackIters: usize = 2000;
    const bench_iters: usize = if (requested_iterations == 0) 100 else @min(requested_iterations, MaxStackIters);
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;
    var total_ns: u64 = 0;

    var iter_durations_buf: [MaxStackIters]u64 = undefined;
    const iter_durations = iter_durations_buf[0..bench_iters];
    var bench_iter: usize = 0;
    while (bench_iter < bench_iters) : (bench_iter += 1) {
        var dummy_buf: [4096]u8 = undefined;
        var dummy_pos: usize = 0;
        const dummy_writer = BufferWriter.init(&dummy_buf, &dummy_pos);

        const b_t0 = getTimestampNs(io);
        try prompt_engine.render(dummy_writer, config, resolved_ctx);
        const b_t1 = getTimestampNs(io);
        const b_dur = if (b_t1 > b_t0) b_t1 - b_t0 else 0;

        iter_durations[bench_iter] = b_dur;
        if (b_dur < min_ns) min_ns = b_dur;
        if (b_dur > max_ns) max_ns = b_dur;
        total_ns += b_dur;
    }

    std.mem.sort(u64, iter_durations, {}, std.sort.asc(u64));
    const p50_ns = iter_durations[bench_iters / 2];
    const p95_ns = iter_durations[@min(bench_iters - 1, (bench_iters * 95) / 100)];
    const p99_ns = iter_durations[@min(bench_iters - 1, (bench_iters * 99) / 100)];

    if (min_ns == std.math.maxInt(u64)) min_ns = 0;
    const mean_ns = if (bench_iters > 0) total_ns / bench_iters else 0;
    const throughput = if (mean_ns > 0) (1_000_000_000 / mean_ns) else 0;

    if (dctx.json) {
        try writer.print(
            \\{{ "target": "prompt_profiler", "total_render_us": {d}, "format_duration_us": {d}, "git_discovery_us": {d}, "buffer_used_bytes": {d}, "buffer_capacity_bytes": {d}, "modules": [
        , .{
            @divTrunc(single_run_total_ns, 1000),
            @divTrunc(fmt_dur_ns, 1000),
            @divTrunc(git_dur_ns, 1000),
            rendered_pos,
            rendered_prompt_buf.len,
        });

        for (profiles, 0..) |p, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print(
                \\{{ "name": "{s}", "active": {}, "duration_us": {d}, "bytes": {d} }}
            , .{
                p.name,
                p.active,
                @divTrunc(p.duration_ns, 1000),
                p.bytes,
            });
        }

        try writer.print(
            \\ ], "benchmark": {{ "iterations": {d}, "min_us": {d}, "p50_us": {d}, "p95_us": {d}, "p99_us": {d}, "mean_us": {d}, "max_us": {d}, "throughput_renders_per_sec": {d} }} }}
            \\
        , .{
            bench_iters,
            @divTrunc(min_ns, 1000),
            @divTrunc(p50_ns, 1000),
            @divTrunc(p95_ns, 1000),
            @divTrunc(p99_ns, 1000),
            @divTrunc(mean_ns, 1000),
            @divTrunc(max_ns, 1000),
            throughput,
        });
    } else {
        try writer.print(
            \\⚡ Zap Prompt Engine Profiler & Benchmark
            \\
            \\Configuration:
            \\  Add Newline:      {}
            \\  Buffer Usage:     {d} / {d} bytes ({d}.{d}% utilized)
            \\
            \\Per-Module Execution Breakdown (Single Pass):
            \\
        , .{
            config.add_newline,
            rendered_pos,
            rendered_prompt_buf.len,
            (rendered_pos * 100) / rendered_prompt_buf.len,
            ((rendered_pos * 1000) / rendered_prompt_buf.len) % 10,
        });

        for (profiles) |p| {
            if (p.active) {
                const mod_us = @divTrunc(p.duration_ns, 1000);
                const percent = if (single_run_total_ns > 0) (p.duration_ns * 100) / single_run_total_ns else 0;
                try writer.print("  ✔ {s:<15} {d:>6} µs  [{d:>3}%]  ({d:>2} bytes)  ", .{ p.name, mod_us, percent, p.bytes });
                try writeBar(writer, percent, 20);
                try writer.writeByte('\n');
            } else {
                try writer.print("  · {s:<15}      0 µs  (inactive)\n", .{p.name});
            }
        }

        const modules_dur_ns = if (single_run_total_ns > (git_dur_ns + fmt_dur_ns))
            single_run_total_ns - (git_dur_ns + fmt_dur_ns)
        else
            0;
        const git_pct = if (single_run_total_ns > 0) (git_dur_ns * 100) / single_run_total_ns else 0;
        const mod_pct = if (single_run_total_ns > 0) (modules_dur_ns * 100) / single_run_total_ns else 0;
        const fmt_pct = if (single_run_total_ns > 0) (fmt_dur_ns * 100) / single_run_total_ns else 0;

        try writer.print(
            \\
            \\Pipeline Stages:
            \\  Git Resolution:   {d:>6} µs  [{d:>3}%]  
        , .{ @divTrunc(git_dur_ns, 1000), git_pct });
        try writeBar(writer, git_pct, 20);
        try writer.print(
            \\
            \\  Render Modules:   {d:>6} µs  [{d:>3}%]  
        , .{ @divTrunc(modules_dur_ns, 1000), mod_pct });
        try writeBar(writer, mod_pct, 20);
        try writer.print(
            \\
            \\  Template Format:  {d:>6} µs  [{d:>3}%]  
        , .{ @divTrunc(fmt_dur_ns, 1000), fmt_pct });
        try writeBar(writer, fmt_pct, 20);

        try writer.print(
            \\
            \\  Total Single-Run: {d:>6} µs ({d}.{d:0>3} ms)
            \\
            \\Multi-Pass Benchmark ({d} iterations):
            \\  Fastest (Min):    {d:>6} µs ({d}.{d:0>3} ms)
            \\  Median (p50):     {d:>6} µs ({d}.{d:0>3} ms)
            \\  Average (Mean):   {d:>6} µs ({d}.{d:0>3} ms)
            \\  p95 Latency:      {d:>6} µs ({d}.{d:0>3} ms)
            \\  p99 Latency:      {d:>6} µs ({d}.{d:0>3} ms)
            \\  Slowest (Max):    {d:>6} µs ({d}.{d:0>3} ms)
            \\  Throughput:       {d} renders/sec
            \\
        , .{
            @divTrunc(single_run_total_ns, 1000),
            @divTrunc(single_run_total_ns, 1_000_000),
            @divTrunc(@mod(single_run_total_ns, 1_000_000), 1000),
            bench_iters,
            @divTrunc(min_ns, 1000),
            @divTrunc(min_ns, 1_000_000),
            @divTrunc(@mod(min_ns, 1_000_000), 1000),
            @divTrunc(p50_ns, 1000),
            @divTrunc(p50_ns, 1_000_000),
            @divTrunc(@mod(p50_ns, 1_000_000), 1000),
            @divTrunc(mean_ns, 1000),
            @divTrunc(mean_ns, 1_000_000),
            @divTrunc(@mod(mean_ns, 1_000_000), 1000),
            @divTrunc(p95_ns, 1000),
            @divTrunc(p95_ns, 1_000_000),
            @divTrunc(@mod(p95_ns, 1_000_000), 1000),
            @divTrunc(p99_ns, 1000),
            @divTrunc(p99_ns, 1_000_000),
            @divTrunc(@mod(p99_ns, 1_000_000), 1000),
            @divTrunc(max_ns, 1000),
            @divTrunc(max_ns, 1_000_000),
            @divTrunc(@mod(max_ns, 1_000_000), 1000),
            throughput,
        });

        var buckets: [5]usize = .{ 0, 0, 0, 0, 0 };
        const span = if (max_ns > min_ns) max_ns - min_ns else 1;
        const step = (span + 4) / 5;
        for (iter_durations) |dur| {
            const rel = if (dur >= min_ns) dur - min_ns else 0;
            const b_idx = @min(@as(usize, 4), rel / step);
            buckets[b_idx] += 1;
        }

        try writer.print("\nLatency Distribution ({d} runs):\n", .{bench_iters});
        for (0..5) |b| {
            const low_us = @divTrunc(min_ns + b * step, 1000);
            const high_us = @divTrunc(@min(max_ns, min_ns + (b + 1) * step), 1000);
            const count = buckets[b];
            const pct = (count * 100) / bench_iters;
            try writer.print("  {d:>5} - {d:<5} µs:  [{d:>3} runs]  ", .{ low_us, high_us, count });
            try writeBar(writer, pct, 24);
            try writer.writeByte('\n');
        }
    }
}
