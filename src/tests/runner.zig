const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const Mode = enum { all, unit_only, integration_only };

pub fn main(init: std.process.Init.Minimal) void {
    @disableInstrumentation();

    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = init.args.toSlice(alloc) catch |err| {
        std.debug.print("runner: failed to read args: {t}\n", .{err});
        std.process.exit(1);
    };

    var mode: Mode = .all;
    var shard_idx: ?usize = null;
    var shard_count: usize = 1;
    var filter: ?[]const u8 = null;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--unit-only")) {
            mode = .unit_only;
        } else if (std.mem.eql(u8, arg, "--integration-only")) {
            mode = .integration_only;
        } else if (std.mem.startsWith(u8, arg, "--shard=")) {
            const spec = arg["--shard=".len..];
            const slash = std.mem.indexOfScalar(u8, spec, '/') orelse {
                std.debug.print("runner: invalid --shard spec: {s}\n", .{spec});
                std.process.exit(1);
            };
            shard_idx = std.fmt.parseUnsigned(usize, spec[0..slash], 10) catch 0;
            shard_count = std.fmt.parseUnsigned(usize, spec[slash + 1 ..], 10) catch 1;
            if (shard_count == 0) shard_count = 1;
        } else if (std.mem.startsWith(u8, arg, "--filter=")) {
            filter = arg["--filter=".len..];
        }
    }

    const total_matching = countMatching(mode, filter);

    // Parallel sharded execution when running integration/all tests in top-level mode.
    if (shard_idx == null and mode != .unit_only and total_matching > 16) {
        const cpu_count = std.Thread.getCpuCount() catch 4;
        const workers = @min(cpu_count, 8);
        if (workers > 1) {
            runSharded(io, alloc, args[0], mode, filter, workers);
            return;
        }
    }

    runLocal(init, mode, filter, shard_idx, shard_count);
}

fn matches(name: []const u8, mode: Mode, filter: ?[]const u8) bool {
    if (std.mem.endsWith(u8, name, "internal: cleanup git template")) return false;
    const is_integration = std.mem.indexOf(u8, name, "integration:") != null;
    switch (mode) {
        .all => {},
        .unit_only => if (is_integration) return false,
        .integration_only => if (!is_integration) return false,
    }
    if (filter) |f| {
        if (std.mem.indexOf(u8, name, f) == null) return false;
    }
    return true;
}

fn countMatching(mode: Mode, filter: ?[]const u8) usize {
    var count: usize = 0;
    for (builtin.test_functions) |t| {
        if (matches(t.name, mode, filter)) count += 1;
    }
    return count;
}

fn runLocal(init: std.process.Init.Minimal, mode: Mode, filter: ?[]const u8, shard_idx: ?usize, shard_count: usize) void {
    defer {
        for (builtin.test_functions) |t| {
            if (std.mem.endsWith(u8, t.name, "internal: cleanup git template")) {
                testing.environ = init.environ;
                testing.allocator_instance = .{};
                testing.io_instance = .init(testing.allocator, .{
                    .argv0 = .init(init.args),
                    .environ = init.environ,
                });
                _ = t.func() catch {};
                testing.io_instance.deinit();
                _ = testing.allocator_instance.deinit();
                break;
            }
        }
    }
    var passed: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;
    var match_idx: usize = 0;

    for (builtin.test_functions) |t| {
        if (!matches(t.name, mode, filter)) continue;
        const my_idx = match_idx;
        match_idx += 1;
        if (shard_idx) |si| {
            if (my_idx % shard_count != si) continue;
        }

        testing.environ = init.environ;
        testing.allocator_instance = .{};
        testing.io_instance = .init(testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        const res = t.func();
        testing.io_instance.deinit();
        const leak_status = testing.allocator_instance.deinit();

        if (res) |_| {
            if (leak_status == .leak) {
                std.debug.print("FAIL (leak): {s}\n", .{t.name});
                failed += 1;
            } else {
                passed += 1;
            }
        } else |err| {
            if (err == error.SkipZigTest) {
                skipped += 1;
            } else {
                std.debug.print("FAIL ({t}): {s}\n", .{ err, t.name });
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpErrorReturnTrace(trace);
                }
                failed += 1;
            }
        }
    }

    if (shard_idx != null) {
        std.debug.print("ZAP_SHARD:{d}:{d}:{d}\n", .{ passed, failed, skipped });
    } else {
        std.debug.print("{d}/{d} tests passed ({d} failed, {d} skipped)\n", .{
            passed,
            passed + failed + skipped,
            failed,
            skipped,
        });
    }

    if (failed > 0) std.process.exit(1);
}

fn runSharded(
    io: std.Io,
    alloc: std.mem.Allocator,
    exe_path: []const u8,
    mode: Mode,
    filter: ?[]const u8,
    workers: usize,
) void {
    const WorkerProc = struct {
        child: std.process.Child,
        stderr_buf: [65536]u8 = undefined,
        stderr_len: usize = 0,
    };

    const procs = alloc.alloc(WorkerProc, workers) catch @panic("oom");
    var spawned: usize = 0;

    for (0..workers) |i| {
        var argv_list: std.ArrayList([]const u8) = .empty;
        argv_list.append(alloc, exe_path) catch @panic("oom");
        switch (mode) {
            .all => {},
            .unit_only => argv_list.append(alloc, "--unit-only") catch @panic("oom"),
            .integration_only => argv_list.append(alloc, "--integration-only") catch @panic("oom"),
        }
        if (filter) |f| {
            const f_arg = std.fmt.allocPrint(alloc, "--filter={s}", .{f}) catch @panic("oom");
            argv_list.append(alloc, f_arg) catch @panic("oom");
        }
        const shard_arg = std.fmt.allocPrint(alloc, "--shard={d}/{d}", .{ i, workers }) catch @panic("oom");
        argv_list.append(alloc, shard_arg) catch @panic("oom");

        procs[i] = .{
            .child = std.process.spawn(io, .{
                .argv = argv_list.items,
                .stdout = .ignore,
                .stderr = .pipe,
                .stdin = .ignore,
            }) catch |err| {
                std.debug.print("runner: failed to spawn worker {d}: {t}\n", .{ i, err });
                std.process.exit(1);
            },
        };
        spawned += 1;
    }

    var total_passed: usize = 0;
    var total_failed: usize = 0;
    var total_skipped: usize = 0;
    var any_nonzero = false;

    for (0..spawned) |i| {
        var p = &procs[i];
        var stream_buf: [1024]u8 = undefined;
        var reader = p.child.stderr.?.reader(io, &stream_buf);
        while (p.stderr_len < p.stderr_buf.len) {
            const n = reader.interface.readSliceShort(p.stderr_buf[p.stderr_len..]) catch break;
            if (n == 0) break;
            p.stderr_len += n;
        }
        const term = p.child.wait(io) catch {
            any_nonzero = true;
            continue;
        };
        const code: u8 = switch (term) {
            .exited => |c| c,
            else => 1,
        };
        if (code != 0) any_nonzero = true;

        const out = p.stderr_buf[0..p.stderr_len];
        var found_summary = false;
        var lines = std.mem.splitScalar(u8, out, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            if (std.mem.startsWith(u8, line, "ZAP_SHARD:")) {
                found_summary = true;
                var parts = std.mem.splitScalar(u8, line["ZAP_SHARD:".len..], ':');
                const p_str = parts.next() orelse "0";
                const f_str = parts.next() orelse "0";
                const s_str = parts.next() orelse "0";
                total_passed += std.fmt.parseUnsigned(usize, p_str, 10) catch 0;
                total_failed += std.fmt.parseUnsigned(usize, f_str, 10) catch 0;
                total_skipped += std.fmt.parseUnsigned(usize, s_str, 10) catch 0;
            } else if (line.len > 0) {
                std.debug.print("{s}\n", .{line});
            }
        }
        if (!found_summary and code != 0) {
            any_nonzero = true;
        }
    }

    std.debug.print("{d}/{d} tests passed ({d} failed, {d} skipped) across {d} workers\n", .{
        total_passed,
        total_passed + total_failed + total_skipped,
        total_failed,
        total_skipped,
        workers,
    });

    if (total_failed > 0 or any_nonzero) {
        std.process.exit(1);
    }
}
