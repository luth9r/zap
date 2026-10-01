const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");
const Shell = @import("../init/root.zig").Shell;
const Fixture = @import("fixture.zig").Fixture;
const git_utils = @import("../utils/git_utils.zig");

/// Integration test harness for Zap prompt modules.
///
/// Spawns the real `zap` binary as a subprocess with an isolated environment
/// (tmpdir, git repo, custom config), then validates the rendered output.
/// Tests the full pipeline: TOML parsing → module bitmask → git discovery →
/// module rendering → ANSI wrapping → shell-specific escapes.
///
/// ## Usage in any module file
///
/// ```zig
/// const Harness = @import("../tests/harness.zig").Harness;
///
/// test "integration: git branch shows name" {
///     var h = try Harness.create(testing.allocator);
///     defer h.destroy();
///
///     try h.setupGit();
///     try h.git(&.{"checkout", "-b", "my-feature"});
///     try h.setConfig(
///         \\format = "$git_branch"
///         \\add_newline = false
///     );
///
///     const out = try h.collect(.bash);
///     try Harness.expectContains(out, "my-feature");
///     try Harness.expectAnsi(out, .bash);
/// }
/// ```
///
/// ## What this tests (vs direct unit tests)
///
/// - Real TOML file loading from disk (`$ZAP_CONFIG`)
/// - Real git directory discovery (traversing parent dirs)
/// - Real `.git/HEAD` file parsing via `std.Io`
/// - Real `git status --porcelain=v2` subprocess
/// - Shell-specific zero-width ANSI wrapping
/// - Full `zap prompt` CLI argument parsing
/// - Correct `$HOME` / `$PWD` / `$ZAP_CONFIG` env resolution
///
pub const Harness = struct {
    arena: std.heap.ArenaAllocator,
    tmp_dir: []const u8,
    zap_bin: []const u8,
    custom_cwd: ?[]const u8,
    custom_home: ?[]const u8,
    has_git: bool,
    has_config: bool,
    status_code: u8,
    cmd_duration: u64,

    const relative_zap_bin = "zig-out/bin/zap";

    /// Create an isolated test environment with a fresh temporary directory.
    /// The zap binary must be pre-built (`zig build` runs before `zig build test`
    /// thanks to the build.zig dependency).
    pub fn create(backing_allocator: std.mem.Allocator) !Harness {
        var arena = std.heap.ArenaAllocator.init(backing_allocator);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        const io = std.testing.io;

        // Verify zap binary exists and resolve its absolute path
        var bin_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd: std.Io.Dir = .cwd();
        const bin_file = cwd.openFile(io, relative_zap_bin, .{}) catch {
            std.debug.print(
                \\
                \\[HARNESS] Cannot find {s}
                \\[HARNESS] The binary must be built before running integration tests.
                \\[HARNESS] Run: zig build && zig build test
                \\
            , .{relative_zap_bin});
            return error.ZapBinaryNotFound;
        };
        const abs_len = try bin_file.realPath(io, &bin_buf);
        bin_file.close(io);
        const zap_bin_abs = try alloc.dupe(u8, bin_buf[0..abs_len]);

        // Create temp directory with random suffix
        const random: std.Random.IoSource = .{ .io = io };
        const tmp_dir = try std.fmt.allocPrint(alloc, "/tmp/zap-test-{x}", .{random.interface().int(u64)});
        try std.Io.Dir.cwd().createDirPath(io, tmp_dir);

        return .{
            .arena = arena,
            .tmp_dir = tmp_dir,
            .zap_bin = zap_bin_abs,
            .custom_cwd = null,
            .custom_home = null,
            .has_git = false,
            .has_config = false,
            .status_code = 0,
            .cmd_duration = 0,
        };
    }

    /// Clean up: remove temp directory and free all memory.
    pub fn destroy(self: *Harness) void {
        const io = std.testing.io;
        std.Io.Dir.cwd().deleteTree(io, self.tmp_dir) catch {};
        self.arena.deinit();
    }

    // ─── Setup Helpers ────────────────────────────────────────

    /// Initialize a real git repository in the temp directory.
    pub fn setupGit(self: *Harness) !void {
        try self.run(&.{ "git", "init", "--initial-branch=master", self.tmp_dir });
        try self.run(&.{ "git", "-C", self.tmp_dir, "config", "user.email", "test@zap.dev" });
        try self.run(&.{ "git", "-C", self.tmp_dir, "config", "user.name", "Zap Test" });
        try self.writeFile(".gitignore", "config.toml\n");
        try self.run(&.{ "git", "-C", self.tmp_dir, "add", ".gitignore" });
        try self.run(&.{ "git", "-C", self.tmp_dir, "commit", "-m", "initial" });
        self.has_git = true;
    }

    /// Run a git command in the test repo.
    ///
    /// ```zig
    /// try h.git(&.{"checkout", "-b", "feature-x"});
    /// try h.git(&.{"add", "."});
    /// try h.git(&.{"commit", "-m", "add files"});
    /// ```
    pub fn git(self: *Harness, args: []const []const u8) !void {
        const full_args = try self.arena.allocator().alloc([]const u8, 3 + args.len);
        full_args[0] = "git";
        full_args[1] = "-C";
        full_args[2] = self.tmp_dir;
        @memcpy(full_args[3..], args);
        try self.run(full_args);
    }

    /// Run a git command in the test repo allowing non-zero exit (e.g. merge conflict).
    pub fn gitAllowFail(self: *Harness, args: []const []const u8) !u8 {
        const full_args = try self.arena.allocator().alloc([]const u8, 3 + args.len);
        full_args[0] = "git";
        full_args[1] = "-C";
        full_args[2] = self.tmp_dir;
        @memcpy(full_args[3..], args);
        return self.runAllowFail(full_args);
    }

    /// Write a TOML configuration file for this test.
    /// The content is written exactly as a user would write `~/.config/zap/config.toml`.
    ///
    /// ```zig
    /// try h.setConfig(
    ///     \\format = "$directory$git_branch$character"
    ///     \\add_newline = false
    ///     \\
    ///     \\[git_branch]
    ///     \\style = "bold magenta"
    /// );
    /// ```
    pub fn setConfig(self: *Harness, toml_content: []const u8) !void {
        try self.writeFile("config.toml", toml_content);
        self.has_config = true;
    }

    /// Write an arbitrary file into the test directory.
    ///
    /// ```zig
    /// try h.writeFile("src/main.zig", "pub fn main() {}");
    /// ```
    pub fn writeFile(self: *Harness, rel_path: []const u8, content: []const u8) !void {
        const full_path = try std.fmt.allocPrint(self.arena.allocator(), "{s}/{s}", .{ self.tmp_dir, rel_path });
        try git_utils.writeFileAbsolute(std.testing.io, full_path, content);
    }

    /// Set a custom working directory relative to tmp_dir (or absolute) for this test.
    pub fn setCwd(self: *Harness, rel_or_abs: []const u8) !*Harness {
        if (std.fs.path.isAbsolute(rel_or_abs)) {
            self.custom_cwd = rel_or_abs;
        } else {
            const full_path = try std.fmt.allocPrint(self.arena.allocator(), "{s}/{s}", .{ self.tmp_dir, rel_or_abs });
            try std.Io.Dir.cwd().createDirPath(std.testing.io, full_path);
            self.custom_cwd = full_path;
        }
        return self;
    }

    /// Set a custom HOME directory relative to tmp_dir (or absolute) for this test.
    pub fn setHome(self: *Harness, rel_or_abs: []const u8) !*Harness {
        if (std.fs.path.isAbsolute(rel_or_abs)) {
            self.custom_home = rel_or_abs;
        } else {
            const full_path = try std.fmt.allocPrint(self.arena.allocator(), "{s}/{s}", .{ self.tmp_dir, rel_or_abs });
            try std.Io.Dir.cwd().createDirPath(std.testing.io, full_path);
            self.custom_home = full_path;
        }
        return self;
    }

    /// Set the exit code that will be passed to `zap prompt --status`.
    pub fn setStatus(self: *Harness, code: u8) *Harness {
        self.status_code = code;
        return self;
    }

    /// Set the command duration (ms) that will be passed to `zap prompt --duration`.
    pub fn setDuration(self: *Harness, ms: u64) *Harness {
        self.cmd_duration = ms;
        return self;
    }

    // ─── Execution ────────────────────────────────────────────

    /// Run `zap prompt` with the configured environment and return the raw output.
    /// The output is valid until `destroy()` is called.
    ///
    /// This is the core E2E function — it spawns the real `zap` binary with:
    /// - `HOME` and `PWD` pointing to the tmpdir (or custom_home / custom_cwd)
    /// - `ZAP_CONFIG` pointing to the config file (if `setConfig()` was called)
    pub fn collect(self: *Harness, shell: Shell) ![]const u8 {
        const alloc = self.arena.allocator();
        const current_home = self.custom_home orelse self.tmp_dir;
        const current_pwd = self.custom_cwd orelse self.tmp_dir;

        // Format numeric args on stack
        var status_buf: [4]u8 = undefined;
        var duration_buf: [20]u8 = undefined;
        const status_str = std.fmt.bufPrint(&status_buf, "{d}", .{self.status_code}) catch "0";
        const duration_str = std.fmt.bufPrint(&duration_buf, "{d}", .{self.cmd_duration}) catch "0";
        const shell_str: []const u8 = switch (shell) {
            .bash => "bash",
            .zsh => "zsh",
            .fish => "fish",
            .powershell => "powershell",
            .generic => "generic",
        };

        // Build env vars for `env` command to ensure 100% hermetic isolation from host environment
        const home_env = try std.fmt.allocPrint(alloc, "HOME={s}", .{current_home});
        const userprofile_env = try std.fmt.allocPrint(alloc, "USERPROFILE={s}", .{current_home});
        const pwd_env = try std.fmt.allocPrint(alloc, "PWD={s}", .{current_pwd});
        const xdg_env = try std.fmt.allocPrint(alloc, "XDG_CONFIG_HOME={s}/.config", .{current_home});
        const appdata_env = try std.fmt.allocPrint(alloc, "APPDATA={s}/AppData", .{current_home});

        // Build argv: env KEY=VALUE... zap prompt --status N --duration N --shell S
        var argv_buf: [24][]const u8 = undefined;
        var argc: usize = 0;

        argv_buf[argc] = "env";
        argc += 1;
        argv_buf[argc] = home_env;
        argc += 1;
        argv_buf[argc] = userprofile_env;
        argc += 1;
        argv_buf[argc] = pwd_env;
        argc += 1;
        argv_buf[argc] = xdg_env;
        argc += 1;
        argv_buf[argc] = appdata_env;
        argc += 1;

        if (self.has_config) {
            const config_env = try std.fmt.allocPrint(alloc, "ZAP_CONFIG={s}/config.toml", .{self.tmp_dir});
            argv_buf[argc] = config_env;
            argc += 1;
        } else {
            // Explicitly clear ZAP_CONFIG in case host environment has it exported
            argv_buf[argc] = "ZAP_CONFIG=";
            argc += 1;
        }

        argv_buf[argc] = self.zap_bin;
        argc += 1;
        argv_buf[argc] = "prompt";
        argc += 1;
        argv_buf[argc] = "--status";
        argc += 1;
        argv_buf[argc] = status_str;
        argc += 1;
        argv_buf[argc] = "--duration";
        argc += 1;
        argv_buf[argc] = duration_str;
        argc += 1;
        argv_buf[argc] = "--shell";
        argc += 1;
        argv_buf[argc] = shell_str;
        argc += 1;

        const io = std.testing.io;
        var child = std.process.spawn(io, .{
            .argv = argv_buf[0..argc],
            .cwd = .{ .path = current_pwd },
            .stdout = .pipe,
            .stderr = .pipe,
            .stdin = .ignore,
        }) catch |err| {
            std.debug.print("[HARNESS] Failed to spawn: {any}\n", .{err});
            return err;
        };

        var stream_buf: [512]u8 = undefined;
        var reader = child.stdout.?.reader(io, &stream_buf);
        var out_buf: [65536]u8 = undefined;
        var total_read: usize = 0;

        while (total_read < out_buf.len) {
            const n = reader.interface.readSliceShort(out_buf[total_read..]) catch |err| {
                std.debug.print("[HARNESS] Stdout read error: {any}\n", .{err});
                return err;
            };
            if (n == 0) break;
            total_read += n;
        }

        var err_stream_buf: [256]u8 = undefined;
        var err_reader = child.stderr.?.reader(io, &err_stream_buf);
        var err_buf: [4096]u8 = undefined;
        var err_read: usize = 0;
        while (err_read < err_buf.len) {
            const n = err_reader.interface.readSliceShort(err_buf[err_read..]) catch |err| {
                std.debug.print("[HARNESS] Stderr read error: {any}\n", .{err});
                return err;
            };
            if (n == 0) break;
            err_read += n;
        }

        const term = child.wait(io) catch return error.ZapCrashed;
        switch (term) {
            .exited => |code| {
                if (code != 0) {
                    std.debug.print(
                        \\
                        \\[HARNESS ERROR] zap prompt exited with code {d}
                        \\[HARNESS ERROR] Stderr: {s}
                        \\
                    , .{ code, err_buf[0..err_read] });
                    return error.ZapExitedWithError;
                }
            },
            else => {
                std.debug.print(
                    \\
                    \\[HARNESS ERROR] zap prompt terminated abnormally
                    \\[HARNESS ERROR] Stderr: {s}
                    \\
                , .{err_buf[0..err_read]});
                return error.ZapCrashed;
            },
        }

        const out_copy = try alloc.dupe(u8, out_buf[0..total_read]);
        return out_copy;
    }

    pub const ExecResult = struct {
        stdout: []const u8,
        stderr: []const u8,
        exit_code: u8,
    };

    /// Spawns the zap binary with custom CLI arguments and returns stdout on success.
    pub fn execZap(self: *Harness, args: []const []const u8) ![]const u8 {
        const res = try self.execZapAllowFail(args);
        if (res.exit_code != 0) {
            std.debug.print(
                \\
                \\[HARNESS ERROR] zap exited with code {d}
                \\[HARNESS ERROR] Stderr: {s}
                \\[HARNESS ERROR] Stdout: {s}
                \\
            , .{ res.exit_code, res.stderr, res.stdout });
            return error.ZapExitedWithError;
        }
        return res.stdout;
    }

    /// Spawns the zap binary with custom CLI arguments and returns ExecResult.
    pub fn execZapAllowFail(self: *Harness, args: []const []const u8) !ExecResult {
        const alloc = self.arena.allocator();
        const current_home = self.custom_home orelse self.tmp_dir;
        const current_pwd = self.custom_cwd orelse self.tmp_dir;

        const home_env = try std.fmt.allocPrint(alloc, "HOME={s}", .{current_home});
        const userprofile_env = try std.fmt.allocPrint(alloc, "USERPROFILE={s}", .{current_home});
        const pwd_env = try std.fmt.allocPrint(alloc, "PWD={s}", .{current_pwd});
        const xdg_env = try std.fmt.allocPrint(alloc, "XDG_CONFIG_HOME={s}/.config", .{current_home});
        const appdata_env = try std.fmt.allocPrint(alloc, "APPDATA={s}/AppData", .{current_home});

        const full_argv = try alloc.alloc([]const u8, 7 + args.len);
        var argc: usize = 0;
        full_argv[argc] = "env"; argc += 1;
        full_argv[argc] = home_env; argc += 1;
        full_argv[argc] = userprofile_env; argc += 1;
        full_argv[argc] = pwd_env; argc += 1;
        full_argv[argc] = xdg_env; argc += 1;
        full_argv[argc] = appdata_env; argc += 1;
        full_argv[argc] = self.zap_bin; argc += 1;
        @memcpy(full_argv[argc .. argc + args.len], args);
        argc += args.len;

        const io = std.testing.io;
        var child = try std.process.spawn(io, .{
            .argv = full_argv[0..argc],
            .cwd = .{ .path = current_pwd },
            .stdout = .pipe,
            .stderr = .pipe,
            .stdin = .ignore,
        });

        var stream_buf: [512]u8 = undefined;
        var reader = child.stdout.?.reader(io, &stream_buf);
        var out_buf: [65536]u8 = undefined;
        var total_read: usize = 0;
        while (total_read < out_buf.len) {
            const n = reader.interface.readSliceShort(out_buf[total_read..]) catch break;
            if (n == 0) break;
            total_read += n;
        }

        var err_stream_buf: [256]u8 = undefined;
        var err_reader = child.stderr.?.reader(io, &err_stream_buf);
        var err_buf: [4096]u8 = undefined;
        var err_read: usize = 0;
        while (err_read < err_buf.len) {
            const n = err_reader.interface.readSliceShort(err_buf[err_read..]) catch break;
            if (n == 0) break;
            err_read += n;
        }

        const term = child.wait(io) catch return error.ZapCrashed;
        const code: u8 = switch (term) {
            .exited => |c| c,
            else => return error.ZapCrashed,
        };

        return ExecResult{
            .stdout = try alloc.dupe(u8, out_buf[0..total_read]),
            .stderr = try alloc.dupe(u8, err_buf[0..err_read]),
            .exit_code = code,
        };
    }


    /// Run `zap prompt`, then pipe the output through a real shell to validate
    /// it doesn't crash or produce syntax errors in that shell.
    /// Returns the shell's stdout (the prompt as the shell interprets it).
    pub fn collectViaShell(self: *Harness, shell: Shell) !?[]const u8 {
        const raw = try self.collect(shell);
        var shell_buf: [4096]u8 = undefined;
        const res = try Fixture.execInShell(std.testing.io, shell, raw, &shell_buf);
        if (res) |r| {
            return try self.arena.allocator().dupe(u8, r);
        }
        return null;
    }

    /// Collect and validate across ALL shells. For each shell:
    /// 1. Renders prompt with shell-specific ANSI wrapping
    /// 2. Validates ANSI escape correctness
    /// 3. Pipes through real shell binary (if available)
    ///
    /// Returns the generic (no shell wrapping) output for content assertions.
    pub fn collectAllShells(self: *Harness) ![]const u8 {
        const shells = [_]Shell{ .bash, .zsh, .fish, .powershell };
        var shell_buf: [4096]u8 = undefined;

        for (shells) |shell| {
            const out = try self.collect(shell);
            try Fixture.assertValidShellAnsi(out, shell);

            // Pipe through real shell (skips if binary not found, fails test if shell errors)
            _ = try Fixture.execInShell(std.testing.io, shell, out, &shell_buf);
        }

        // Return generic output for content assertions
        return try self.collect(.generic);
    }

    // ─── Assertions ───────────────────────────────────────────

    /// Assert the output contains the expected substring.
    pub fn expectContains(haystack: []const u8, needle: []const u8) !void {
        if (std.mem.indexOf(u8, haystack, needle) == null) {
            std.debug.print(
                \\
                \\[ASSERT FAIL] Expected output to contain: "{s}"
                \\[ASSERT FAIL] Actual output ({d} bytes):
                \\──────────────────
                \\{s}
                \\──────────────────
                \\
            , .{ needle, haystack.len, haystack });
            return error.TestExpectedContains;
        }
    }

    /// Assert the output does NOT contain the substring.
    pub fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
        if (std.mem.indexOf(u8, haystack, needle) != null) {
            std.debug.print(
                \\
                \\[ASSERT FAIL] Expected output to NOT contain: "{s}"
                \\[ASSERT FAIL] Actual output: {s}
                \\
            , .{ needle, haystack });
            return error.TestExpectedNotContains;
        }
    }

    /// Assert the output is not empty.
    pub fn expectNotEmpty(output: []const u8) !void {
        if (output.len == 0) {
            std.debug.print("\n[ASSERT FAIL] Expected non-empty output\n", .{});
            return error.TestExpectedNotEmpty;
        }
    }

    /// Assert ANSI escape sequences are correctly wrapped for the given shell.
    /// Delegates to the existing Fixture validator.
    pub fn expectAnsi(output: []const u8, shell: Shell) !void {
        Fixture.assertValidShellAnsi(output, shell) catch |err| {
            std.debug.print(
                \\
                \\[ASSERT FAIL] Invalid ANSI escapes for shell {s}: {any}
                \\[ASSERT FAIL] Output: {s}
                \\
            , .{ @tagName(shell), err, output });
            return err;
        };
    }

    /// Strip ANSI escape sequences and zero-width markers for raw text comparisons.
    pub fn stripAnsi(alloc: std.mem.Allocator, text: []const u8) ![]const u8 {
        return Fixture.stripAnsi(alloc, text);
    }

    /// Assert the rendered prompt contains visible text (strips ANSI escapes first).
    pub fn expectVisibleText(output: []const u8, expected: []const u8) !void {
        var stack_buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&stack_buf);
        const stripped = Fixture.stripAnsi(fba.allocator(), output) catch output;
        try expectContains(stripped, expected);
    }

    /// Helper: asserts that ALL 4 shells (Bash, Zsh, Fish, PowerShell) produce
    /// valid ANSI wrapping AND contain the expected substring.
    pub fn expectAllShellsContains(self: *Harness, expected: []const u8) !void {
        const shells = [_]Shell{ .bash, .zsh, .fish, .powershell };
        var shell_buf: [4096]u8 = undefined;

        for (shells) |shell| {
            const out = try self.collect(shell);
            try Fixture.assertValidShellAnsi(out, shell);
            try expectContains(out, expected);
            _ = try Fixture.execInShell(std.testing.io, shell, out, &shell_buf);
        }
    }

    /// Helper: asserts that ALL 4 shells produce output that does NOT contain the needle.
    pub fn expectAllShellsNotContains(self: *Harness, needle: []const u8) !void {
        const shells = [_]Shell{ .bash, .zsh, .fish, .powershell };

        for (shells) |shell| {
            const out = try self.collect(shell);
            try Fixture.assertValidShellAnsi(out, shell);
            try expectNotContains(out, needle);
        }
    }

    // ─── Internal ─────────────────────────────────────────────

    /// Run a command silently, consuming stdout/stderr. Fails on non-zero exit.
    pub fn run(self: *Harness, argv: []const []const u8) !void {
        _ = self;
        const io = std.testing.io;
        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdout = .ignore,
            .stderr = .pipe,
            .stdin = .ignore,
        }) catch |err| {
            std.debug.print("[HARNESS] Failed to spawn: {s} — {any}\n", .{ argv[0], err });
            return err;
        };

        var err_stream_buf: [256]u8 = undefined;
        var err_reader = child.stderr.?.reader(io, &err_stream_buf);
        var err_buf: [4096]u8 = undefined;
        var err_read: usize = 0;
        while (err_read < err_buf.len) {
            const n = err_reader.interface.readSliceShort(err_buf[err_read..]) catch |err| {
                std.debug.print("[HARNESS] Stderr read error: {any}\n", .{err});
                return err;
            };
            if (n == 0) break;
            err_read += n;
        }

        const term = child.wait(io) catch return error.CommandFailed;
        switch (term) {
            .exited => |code| {
                if (code != 0) {
                    std.debug.print(
                        \\
                        \\[HARNESS ERROR] Command failed with code {d}:
                        \\[HARNESS ERROR] Command:
                    , .{code});
                    for (argv) |arg| std.debug.print(" {s}", .{arg});
                    std.debug.print(
                        \\
                        \\[HARNESS ERROR] Stderr: {s}
                        \\
                    , .{err_buf[0..err_read]});
                    return error.CommandFailed;
                }
            },
            else => return error.CommandFailed,
        }
    }

    /// Run a command silently, returning its exit code without failing on non-zero.
    fn runAllowFail(self: *Harness, argv: []const []const u8) !u8 {
        _ = self;
        const io = std.testing.io;
        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdout = .ignore,
            .stderr = .ignore,
            .stdin = .ignore,
        }) catch |err| return err;

        const term = child.wait(io) catch return error.CommandFailed;
        return switch (term) {
            .exited => |code| code,
            else => return error.CommandFailed,
        };
    }
};

// ═══════════════════════════════════════════════════════════════
//  Built-in integration tests — validate the harness itself
//  and serve as examples for module authors
// ═══════════════════════════════════════════════════════════════

test "integration: harness: basic prompt renders non-empty output" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    const out = try h.collect(.generic);
    try Harness.expectNotEmpty(out);
}

test "integration: harness: default prompt with bash ANSI wrapping" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    const out = try h.collect(.bash);
    try Harness.expectNotEmpty(out);
    try Harness.expectAnsi(out, .bash);
}

test "integration: harness: default prompt with zsh ANSI wrapping" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    const out = try h.collect(.zsh);
    try Harness.expectNotEmpty(out);
    try Harness.expectAnsi(out, .zsh);
}

test "integration: harness: error status shows error symbol" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    _ = h.setStatus(1);
    try h.setConfig(
        \\format = "$character"
        \\add_newline = false
        \\
        \\[character]
        \\error_symbol = "[ERR](bold red)"
    );

    const out = try h.collect(.generic);
    try Harness.expectContains(out, "ERR");
}

test "integration: harness: custom config format isolates single module" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.setConfig(
        \\format = "$directory"
        \\add_newline = false
        \\
        \\[directory]
        \\style = "cyan"
        \\truncation_length = 0
    );

    const out = try h.collect(.generic);
    try Harness.expectNotEmpty(out);
}

test "integration: harness: git branch detection in real repo" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.git(&.{ "checkout", "-b", "feature-amazing" });
    try h.setConfig(
        \\format = "$git_branch"
        \\add_newline = false
    );

    const out = try h.collect(.generic);
    try Harness.expectContains(out, "feature-amazing");
}

test "integration: harness: git branch with ANSI validation across shells" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.git(&.{ "checkout", "-b", "test-branch" });
    try h.setConfig(
        \\format = "$git_branch"
        \\add_newline = false
    );

    // Validate shell-specific ANSI wrapping
    const bash_out = try h.collect(.bash);
    try Harness.expectContains(bash_out, "test-branch");
    try Harness.expectAnsi(bash_out, .bash);

    const zsh_out = try h.collect(.zsh);
    try Harness.expectContains(zsh_out, "test-branch");
    try Harness.expectAnsi(zsh_out, .zsh);

    const fish_out = try h.collect(.fish);
    try Harness.expectContains(fish_out, "test-branch");
    try Harness.expectAnsi(fish_out, .fish);
}

test "integration: harness: git dirty status with modified file" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("dirty.txt", "uncommitted changes");
    try h.setConfig(
        \\format = "$git_status"
        \\add_newline = false
    );

    const out = try h.collect(.generic);
    try Harness.expectNotEmpty(out);
    // git_status should show untracked indicator
    try Harness.expectContains(out, "?");
}

test "integration: harness: cmd_duration appears above threshold" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    _ = h.setDuration(5000);
    try h.setConfig(
        \\format = "$cmd_duration"
        \\add_newline = false
        \\
        \\[cmd_duration]
        \\min_time = 2000
    );

    const out = try h.collect(.generic);
    try Harness.expectContains(out, "5s");
}

test "integration: harness: cmd_duration hidden below threshold" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    _ = h.setDuration(500);
    try h.setConfig(
        \\format = "$cmd_duration"
        \\add_newline = false
        \\
        \\[cmd_duration]
        \\min_time = 2000
    );

    const out = try h.collect(.generic);
    // Duration below threshold — should produce empty output
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "integration: harness: full prompt with all modules" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.setupGit();
    _ = h.setStatus(0).setDuration(3000);
    try h.setConfig(
        \\format = "$directory$git_branch$cmd_duration$character"
        \\add_newline = false
        \\
        \\[cmd_duration]
        \\min_time = 1000
    );

    const out = try h.collect(.generic);
    try Harness.expectNotEmpty(out);
    // Should contain duration since 3000 > 1000
    try Harness.expectContains(out, "3s");
}

test "integration: harness: collectAllShells validates every shell" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.setConfig(
        \\format = "$directory$git_branch$character"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectNotEmpty(out);
}

test "integration: harness: empty format produces empty prompt" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.setConfig(
        \\format = ""
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "integration: harness: invalid toml config falls back safely without crashing" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.setConfig(
        \\this is not valid [[ toml syntax = {{{{
    );

    const out = try h.collectAllShells();
    try Harness.expectNotEmpty(out);
}

test "integration: harness: deep nested path does not crash" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    _ = try h.setCwd("a/b/c/d/e/f/g/h/i/j");
    try h.setConfig(
        \\format = "$directory"
        \\add_newline = false
        \\
        \\[directory]
        \\truncation_length = 3
    );

    const out = try h.collectAllShells();
    try Harness.expectNotEmpty(out);
    try Harness.expectContains(out, "h/i/j");
}
