const std = @import("std");
const registry = @import("../../modules/registry.zig");
const module_pkg = @import("../../modules/module.zig");
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
        const category = if (@hasDecl(mod, "Config") and @hasDecl(mod, "Var") and @typeInfo(mod.Var).@"enum".fields.len == 3) "languages" else if (std.mem.startsWith(u8, @typeName(mod), "modules.languages.") or std.mem.eql(u8, name, "zig_lang") or std.mem.eql(u8, name, "python") or std.mem.eql(u8, name, "golang") or std.mem.eql(u8, name, "rust") or std.mem.eql(u8, name, "nodejs") or std.mem.eql(u8, name, "dotnet") or std.mem.eql(u8, name, "java") or std.mem.eql(u8, name, "c") or std.mem.eql(u8, name, "lua") or std.mem.eql(u8, name, "nix") or std.mem.eql(u8, name, "docker")) "languages" else "core";

        const cfg = if (module_pkg.resolveConfigType(mod)) |CfgT| CfgT{} else struct {}{};
        const symbol = if (@hasField(@TypeOf(cfg), "symbol")) @field(cfg, "symbol") else "-";
        const style = if (@hasField(@TypeOf(cfg), "style")) @field(cfg, "style") else "-";
        const desc = getModuleDescription(decl.name);

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

fn getModuleDescription(comptime name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "directory")) return "Current working directory with smart truncation";
    if (std.mem.eql(u8, name, "git_branch")) return "Active Git branch name and remote tracking";
    if (std.mem.eql(u8, name, "git_commit")) return "Git commit SHA hash and active tag";
    if (std.mem.eql(u8, name, "git_state")) return "Git operational state (rebase, merge, bisect)";
    if (std.mem.eql(u8, name, "git_status")) return "Git working tree status indicators";
    if (std.mem.eql(u8, name, "cmd_duration")) return "Execution duration of previous command";
    if (std.mem.eql(u8, name, "character")) return "Prompt status character";
    if (std.mem.eql(u8, name, "os")) return "Operating system indicator symbol";
    if (std.mem.eql(u8, name, "time")) return "Current local time";
    if (std.mem.eql(u8, name, "zig_lang")) return "Zig compiler toolchain and project indicator";
    if (std.mem.eql(u8, name, "python")) return "Python virtual environment and project indicator";
    if (std.mem.eql(u8, name, "golang")) return "Go module and workspace indicator";
    if (std.mem.eql(u8, name, "rust")) return "Rust Cargo project and toolchain indicator";
    if (std.mem.eql(u8, name, "nodejs")) return "Node.js / TypeScript / Bun project indicator";
    if (std.mem.eql(u8, name, "dotnet")) return ".NET SDK, C# / F# solution and project indicator";
    if (std.mem.eql(u8, name, "java")) return "Java / Maven / Gradle / JVM project indicator";
    if (std.mem.eql(u8, name, "c")) return "C / C++ CMake, Makefile, and Meson project indicator";
    if (std.mem.eql(u8, name, "lua")) return "Lua script and project configuration indicator";
    if (std.mem.eql(u8, name, "nix")) return "Nix flake and declarative shell indicator";
    if (std.mem.eql(u8, name, "docker")) return "Docker and Compose container context indicator";
    return "Prompt module";
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
