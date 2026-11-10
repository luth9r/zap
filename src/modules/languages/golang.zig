const std = @import("std");
const module = @import("../module.zig");

pub const GolangModule = module.GenericLanguageModule(.{
    .name = "golang",
    .symbol = " ",
    .style = "bold cyan",
    .extensions = &.{".go"},
    .files = &.{ "go.mod", "go.sum", "go.work", "glide.yaml", "Gopkg.yml", "Gopkg.lock" },
});

pub const Var = GolangModule.Var;
pub const Config = GolangModule.Config;
pub const GolangConfig = Config;
pub const render = GolangModule.render;
pub const buffer_size = GolangModule.buffer_size;
pub const debug = GolangModule.debug;

pub const Harness = @import("../../tests/harness.zig").Harness;

test "unit: golang satisfies module contract" {
    comptime module.validateModule(GolangModule);
}

test "integration: golang renders symbol when go.mod is present" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.writeFile("go.mod", "module example.com/app\n");
    try h.setConfig(
        \\format = "$golang"
        \\add_newline = false
    );

    const out = try h.collect(.generic);
    try Harness.expectContains(out, "");
}
