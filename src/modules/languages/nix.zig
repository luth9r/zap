const std = @import("std");
const module = @import("../module.zig");

pub const NixModule = module.GenericLanguageModule(.{
    .name = "nix",
    .symbol = " ",
    .style = "bold blue",
    .extensions = &.{".nix"},
    .files = &.{ "flake.nix", "flake.lock", "shell.nix", "default.nix" },
});

pub const Var = NixModule.Var;
pub const Config = NixModule.Config;
pub const NixConfig = Config;
pub const render = NixModule.render;
pub const buffer_size = NixModule.buffer_size;
pub const debug = NixModule.debug;

pub const Harness = @import("../../tests/harness.zig").Harness;

test "unit: nix satisfies module contract" {
    comptime module.validateModule(NixModule);
}

test "integration: nix renders symbol when flake.nix is present" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.writeFile("flake.nix", "{}\n");
    try h.setConfig(
        \\format = "$nix"
        \\add_newline = false
    );

    const out = try h.collect(.generic);
    try Harness.expectContains(out, "");
}
