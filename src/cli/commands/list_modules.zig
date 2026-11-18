const std = @import("std");
const registry = @import("../../modules/registry.zig");
const module_pkg = @import("../../modules/module.zig");
const prompt_engine = @import("../../engine/prompt.zig");
const BufferWriter = @import("../../utils/buffer_writer.zig").BufferWriter;

pub fn execute(io: std.Io) !void {
    var buf: [8192]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    try printModuleList(writer);
    try std.Io.File.stdout().writeStreamingAll(io, buf[0..pos]);
}

pub fn printModuleList(writer: anytype) !void {
    try writer.writeAll(
        \\Available Zap prompt modules:
        \\
        \\  NAME           CATEGORY     SYMBOL   DEFAULT STYLE    DESCRIPTION
        \\  ──────────────────────────────────────────────────────────────────────────────────
        \\
    );

    inline for (@typeInfo(registry).@"struct".decls) |decl| {
        const mod = @field(registry, decl.name);
        const name = decl.name;
        const category = if (@hasDecl(mod, "detect")) "languages" else "core";

        const cfg = if (module_pkg.resolveConfigType(mod)) |CfgT| CfgT{} else struct {}{};
        const symbol = if (@hasField(@TypeOf(cfg), "symbol")) @field(cfg, "symbol") else "-";
        const style = if (@hasField(@TypeOf(cfg), "style")) @field(cfg, "style") else "-";
        const desc = getModuleDescription(@field(prompt_engine.ModuleVar, decl.name));

        try writer.print("  {s:<14} {s:<12} {s:<8} {s:<16} {s}\n", .{
            name,
            category,
            if (symbol.len > 0) symbol else "-",
            style,
            desc,
        });
    }
    try writer.writeAll("\n");
}

fn getModuleDescription(mod_var: prompt_engine.ModuleVar) []const u8 {
    return switch (mod_var) {
        .directory => "Current working directory with smart truncation",
        .git_branch => "Active Git branch name and remote tracking",
        .git_commit => "Git commit SHA hash and active tag",
        .git_state => "Git operational state (rebase, merge, bisect)",
        .git_status => "Git working tree status indicators",
        .cmd_duration => "Execution duration of previous command",
        .character => "Prompt status character",
        .os => "Operating system indicator symbol",
        .time => "Current local time",
        .zig_lang => "Zig compiler toolchain and project indicator",
        .python => "Python virtual environment and project indicator",
        .golang => "Go module and workspace indicator",
        .rust => "Rust Cargo project and toolchain indicator",
        .nodejs => "Node.js / TypeScript / Bun project indicator",
        .dotnet => ".NET SDK, C# / F# solution and project indicator",
        .java => "Java / Maven / Gradle / JVM project indicator",
        .c => "C / C++ CMake, Makefile, and Meson project indicator",
        .lua => "Lua script and project configuration indicator",
        .nix => "Nix flake and declarative shell indicator",
        .docker => "Docker and Compose container context indicator",
    };
}

const testing = std.testing;
const Harness = @import("../../tests/harness.zig").Harness;

test "integration: zap list-modules" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    const out = try h.execZap(&.{"list-modules"});
    try Harness.expectContains(out, "Available Zap prompt modules:");
    try Harness.expectContains(out, "directory");
    try Harness.expectContains(out, "git_branch");
    try Harness.expectContains(out, "git_commit");
    try Harness.expectContains(out, "git_state");
    try Harness.expectContains(out, "git_status");
    try Harness.expectContains(out, "cmd_duration");
    try Harness.expectContains(out, "character");
    try Harness.expectContains(out, "os");
    try Harness.expectContains(out, "zig_lang");
}
