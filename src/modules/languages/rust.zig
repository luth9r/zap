const std = @import("std");
const module = @import("../module.zig");

pub const RustModule = module.GenericLanguageModule(.{
    .name = "rust",
    .symbol = "󱘗 ",
    .style = "bold red",
    .extensions = &.{".rs"},
    .files = &.{ "Cargo.toml", "Cargo.lock", "rust-toolchain.toml", "rust-toolchain" },
});

pub const Var = RustModule.Var;
pub const Config = RustModule.Config;
pub const RustConfig = Config;
pub const render = RustModule.render;
pub const buffer_size = RustModule.buffer_size;
pub const debug = RustModule.debug;

pub const Harness = @import("../../tests/harness.zig").Harness;

test "unit: rust satisfies module contract" {
    comptime module.validateModule(RustModule);
}

test "integration: rust renders symbol when Cargo.toml is present" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.writeFile("Cargo.toml", "[package]\nname = \"app\"\n");
    try h.setConfig(
        \\format = "$rust"
        \\add_newline = false
    );

    const out = try h.collect(.generic);
    try Harness.expectContains(out, "󱘗");
}
