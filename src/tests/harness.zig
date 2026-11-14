const std = @import("std");
const testing = std.testing;
const Shell = @import("../init/root.zig").Shell;
const Fixture = @import("fixture.zig").Fixture;
const assertions = @import("assertions.zig");
const git_utils = @import("../utils/git_utils.zig");
const platform = @import("../utils/platform.zig");

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

    const relative_zap_bin = "zig-out/bin/zap" ++ platform.exe_ext;

    pub const getEnvWindows = platform.getEnvWindows;
    pub const setEnvWindows = platform.setEnvWindows;

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

        // Create temp directory with random suffix outside the repository
        const random: std.Random.IoSource = .{ .io = io };
        const rand_id = random.interface().int(u64);
        var tmp_name_buf: [64]u8 = undefined;
        const tmp_name = try std.fmt.bufPrint(&tmp_name_buf, "zap-test-{x}", .{rand_id});
        var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp_dir = try alloc.dupe(u8, try platform.testTempSubdir(&tmp_path_buf, tmp_name));
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
        setEnvWindows("ZAP_CONFIG", null);
        const io = std.testing.io;
        std.Io.Dir.cwd().deleteTree(io, self.tmp_dir) catch {};
        self.arena.deinit();
    }

    // ─── Setup Helpers ────────────────────────────────────────

    var git_template_buf: [std.fs.max_path_bytes]u8 = undefined;
    var git_template_len: usize = 0;

    fn copyDirRecursive(io: std.Io, src: std.Io.Dir, dst: std.Io.Dir) !void {
        var it = src.iterateAssumeFirstIteration();
        while (try it.next(io)) |entry| {
            switch (entry.kind) {
                .directory => {
                    var sub_dst = try dst.createDirPathOpen(io, entry.name, .{});
                    defer sub_dst.close(io);
                    var sub_src = try src.openDir(io, entry.name, .{ .iterate = true });
                    defer sub_src.close(io);
                    try copyDirRecursive(io, sub_src, sub_dst);
                },
                .file => {
                    try src.copyFile(entry.name, dst, entry.name, io, .{});
                },
                else => {},
            }
        }
    }

    fn ensureGitTemplate(self: *Harness) ![]const u8 {
        if (git_template_len != 0) return git_template_buf[0..git_template_len];

        const io = std.testing.io;
        const random: std.Random.IoSource = .{ .io = io };
        const rand_id = random.interface().int(u64);
        var tpl_name_buf: [64]u8 = undefined;
        const tpl_name = try std.fmt.bufPrint(&tpl_name_buf, "zap-git-tpl-{x}", .{rand_id});
        const tpl_path = try platform.testTempSubdir(&git_template_buf, tpl_name);

        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io, tpl_path);
        errdefer cwd.deleteTree(io, tpl_path) catch {};

        try self.run(&.{ "git", "init", "--initial-branch=master", tpl_path });
        try self.run(&.{ "git", "-C", tpl_path, "config", "user.email", "test@zap.dev" });
        try self.run(&.{ "git", "-C", tpl_path, "config", "user.name", "Zap Test" });

        var exclude_buf: [std.fs.max_path_bytes]u8 = undefined;
        const exclude_path = platform.joinPath(&exclude_buf, tpl_path, ".git/info/exclude") orelse return error.NameTooLong;
        try git_utils.writeFileAbsolute(io, exclude_path, "config.toml\n");

        try self.run(&.{ "git", "-C", tpl_path, "commit", "--allow-empty", "-m", "initial" });

        var hooks_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (platform.joinPath(&hooks_buf, tpl_path, ".git/hooks")) |hooks_path| {
            cwd.deleteTree(io, hooks_path) catch {};
        }

        git_template_len = tpl_path.len;
        return git_template_buf[0..git_template_len];
    }

    /// Remove the cached template git repository if created by this process.
    pub fn cleanupGitTemplate(io: std.Io) void {
        if (git_template_len == 0) return;
        std.Io.Dir.cwd().deleteTree(io, git_template_buf[0..git_template_len]) catch {};
        git_template_len = 0;
    }

    /// Initialize a real git repository in the temp directory from a cached template repo.
    pub fn setupGit(self: *Harness) !void {
        const io = std.testing.io;
        const tpl_path = try self.ensureGitTemplate();
        const cwd = std.Io.Dir.cwd();

        var src_dir = try cwd.openDir(io, tpl_path, .{ .iterate = true });
        defer src_dir.close(io);
        var dst_dir = try cwd.openDir(io, self.tmp_dir, .{});
        defer dst_dir.close(io);

        try copyDirRecursive(io, src_dir, dst_dir);
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

    /// Delete a file inside the test directory.
    pub fn deleteFile(self: *Harness, rel_path: []const u8) !void {
        const full_path = try std.fmt.allocPrint(self.arena.allocator(), "{s}/{s}", .{ self.tmp_dir, rel_path });
        try std.Io.Dir.deleteFileAbsolute(std.testing.io, full_path);
    }

    pub fn makeDir(self: *Harness, rel_path: []const u8) ![]const u8 {
        const full_path = try std.fmt.allocPrint(self.arena.allocator(), "{s}/{s}", .{ self.tmp_dir, rel_path });
        try std.Io.Dir.cwd().createDirPath(std.testing.io, full_path);
        return full_path;
    }

    pub fn makeSymlink(self: *Harness, target: []const u8, rel_link_path: []const u8) !?[]const u8 {
        const link_path = try std.fmt.allocPrint(self.arena.allocator(), "{s}/{s}", .{ self.tmp_dir, rel_link_path });
        if (!platform.createSymlink(std.testing.io, target, link_path)) return null;
        return link_path;
    }

    pub fn makeReadOnly(self: *Harness, dir_path: []const u8) !bool {
        _ = self;
        return platform.setDirReadOnly(std.testing.io, dir_path);
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
    pub fn setCwdRoot(self: *Harness) []const u8 {
        self.custom_cwd = platform.fs_root;
        return platform.fs_root;
    }

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
        var status_buf: [4]u8 = undefined;
        var duration_buf: [20]u8 = undefined;
        const status_str = std.fmt.bufPrint(&status_buf, "{d}", .{self.status_code}) catch "0";
        const duration_str = std.fmt.bufPrint(&duration_buf, "{d}", .{self.cmd_duration}) catch "0";

        const args = [_][]const u8{
            "prompt",
            "--status",
            status_str,
            "--duration",
            duration_str,
            "--shell",
            @tagName(shell),
        };
        const res = try self.spawnZap(&args, self.has_config);
        if (res.exit_code != 0) {
            std.debug.print(
                \\
                \\[HARNESS ERROR] zap prompt exited with code {d}
                \\[HARNESS ERROR] Stderr: {s}
                \\
            , .{ res.exit_code, res.stderr });
            return error.ZapExitedWithError;
        }
        return res.stdout;
    }

    pub const ExecResult = struct {
        stdout: []const u8,
        stderr: []const u8,
        exit_code: u8,
    };

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

    pub fn execZapAllowFail(self: *Harness, args: []const []const u8) !ExecResult {
        return self.spawnZap(args, false);
    }

    pub fn runShellScript(self: *Harness, argv: []const []const u8) !?[]const u8 {
        if (platform.is_windows and !std.mem.eql(u8, argv[0], platform.powershell_bin)) return null;

        const alloc = self.arena.allocator();
        const io = std.testing.io;

        var xdg_buf: [std.fs.max_path_bytes]u8 = undefined;
        const xdg_val = platform.joinPath(&xdg_buf, self.tmp_dir, ".config");
        const zap_dir = std.fs.path.dirname(self.zap_bin) orelse ".";
        const path_val = try platform.buildPathWithPrependedDir(alloc, zap_dir);

        var orig_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const orig_path = if (platform.is_windows) platform.getEnvWindows("PATH", &orig_path_buf) else null;
        defer if (platform.is_windows) platform.setEnvWindows("PATH", orig_path);

        const env_vars = [_]platform.EnvEntry{
            .{ .key = "HOME", .value = self.tmp_dir },
            .{ .key = "USERPROFILE", .value = self.tmp_dir },
            .{ .key = "XDG_CONFIG_HOME", .value = xdg_val },
            .{ .key = "ZAP_CONFIG", .value = null },
            .{ .key = "PATH", .value = path_val },
        };

        var child = platform.spawnWithEnv(io, alloc, self.tmp_dir, &env_vars, argv) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };

        var out_buf: [4096]u8 = undefined;
        const total = platform.readStreamToBuf(io, child.stdout.?, &out_buf);
        const term = try child.wait(io);
        if (term == .exited and term.exited == 127) return null;

        return try alloc.dupe(u8, out_buf[0..total]);
    }

    fn spawnZap(self: *Harness, args: []const []const u8, use_harness_config: bool) !ExecResult {
        const alloc = self.arena.allocator();
        const current_home = self.custom_home orelse self.tmp_dir;
        const current_pwd = self.custom_cwd orelse self.tmp_dir;

        var xdg_buf: [std.fs.max_path_bytes]u8 = undefined;
        const xdg_val = platform.joinPath(&xdg_buf, current_home, ".config");
        var appdata_buf: [std.fs.max_path_bytes]u8 = undefined;
        const appdata_val = platform.joinPath(&appdata_buf, current_home, "AppData");
        var cfg_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cfg_val = if (use_harness_config) platform.joinPath(&cfg_buf, self.tmp_dir, "config.toml") else null;

        const env_vars = [_]platform.EnvEntry{
            .{ .key = platform.env.home, .value = current_home },
            .{ .key = platform.env.userprofile, .value = current_home },
            .{ .key = platform.env.pwd, .value = current_pwd },
            .{ .key = platform.env.xdg_config_home, .value = xdg_val },
            .{ .key = platform.env.appdata, .value = appdata_val },
            .{ .key = platform.env.zap_config, .value = cfg_val },
        };

        var saved_env_bufs: [env_vars.len][std.fs.max_path_bytes]u8 = undefined;
        var saved_env_vals: [env_vars.len]?[]const u8 = @splat(null);
        if (platform.is_windows) {
            for (env_vars, 0..) |entry, i| {
                saved_env_vals[i] = platform.getEnvWindows(entry.key, &saved_env_bufs[i]);
            }
        }
        defer if (platform.is_windows) {
            for (env_vars, 0..) |entry, i| {
                platform.setEnvWindows(entry.key, saved_env_vals[i]);
            }
        };

        const full_argv = try alloc.alloc([]const u8, 1 + args.len);
        full_argv[0] = self.zap_bin;
        @memcpy(full_argv[1..], args);

        const io = std.testing.io;
        var child = try platform.spawnWithEnv(io, alloc, current_pwd, &env_vars, full_argv);
        var out_buf: [65536]u8 = undefined;
        const total_read = platform.readStreamToBuf(io, child.stdout.?, &out_buf);

        var err_buf: [4096]u8 = undefined;
        const err_read = platform.readStreamToBuf(io, child.stderr.?, &err_buf);

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
        const shells = [_]Shell{ .bash, .zsh, .fish, .powershell, .cmd };
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

    pub const expectContains = assertions.expectContains;
    pub const expectNotContains = assertions.expectNotContains;
    pub const expectNotEmpty = assertions.expectNotEmpty;
    pub const expectAnsi = assertions.expectAnsi;
    pub const stripAnsi = assertions.stripAnsi;
    pub const expectVisibleText = assertions.expectVisibleText;

    /// Helper: asserts that ALL 4 shells (Bash, Zsh, Fish, PowerShell) produce
    /// valid ANSI wrapping AND contain the expected substring.
    pub fn expectAllShellsContains(self: *Harness, expected: []const u8) !void {
        const shells = [_]Shell{ .bash, .zsh, .fish, .powershell, .cmd };
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
        const shells = [_]Shell{ .bash, .zsh, .fish, .powershell, .cmd };

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
    try Harness.expectContains(out, "❯");
}

test "integration: harness: default prompt with bash ANSI wrapping" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    const out = try h.collect(.bash);
    try Harness.expectNotEmpty(out);
    try Harness.expectAnsi(out, .bash);
    try Harness.expectContains(out, "❯");
}

test "integration: harness: default prompt with zsh ANSI wrapping" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    const out = try h.collect(.zsh);
    try Harness.expectNotEmpty(out);
    try Harness.expectAnsi(out, .zsh);
    try Harness.expectContains(out, "❯");
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
    try Harness.expectContains(out, "❯");
    try Harness.expectContains(out, "master");
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
    try Harness.expectContains(out, "❯");
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

test "internal: cleanup git template" {
    Harness.cleanupGitTemplate(std.testing.io);
}
