const std = @import("std");
const module = @import("../module.zig");

pub const NodejsModule = module.GenericLanguageModule(.{
    .name = "nodejs",
    .symbol = " ",
    .style = "bold green",
    .extensions = &.{ ".js", ".mjs", ".cjs", ".ts", ".mts", ".cts" },
    .files = &.{ "package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock", ".nvmrc", ".node-version" },
});

pub const Var = NodejsModule.Var;
pub const Config = NodejsModule.Config;
pub const NodejsConfig = Config;
pub const render = NodejsModule.render;
pub const buffer_size = NodejsModule.buffer_size;
pub const debug = NodejsModule.debug;

pub const Harness = @import("../../tests/harness.zig").Harness;

test "unit: nodejs satisfies module contract" {
    comptime module.validateModule(NodejsModule);
}

test "integration: nodejs renders symbol when package.json is present" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.writeFile("package.json", "{}\n");
    try h.setConfig(
        \\format = "$nodejs"
        \\add_newline = false
    );

    const out = try h.collect(.generic);
    try Harness.expectContains(out, "");
}
