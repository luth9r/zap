const std = @import("std");
const module = @import("../module.zig");

pub const DockerModule = module.GenericLanguageModule(.{
    .name = "docker",
    .symbol = " ",
    .style = "bold blue",
    .extensions = &.{},
    .files = &.{ "Dockerfile", "Containerfile", "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml", ".dockerignore" },
});

pub const Var = DockerModule.Var;
pub const Config = DockerModule.Config;
pub const DockerConfig = Config;
pub const render = DockerModule.render;
pub const buffer_size = DockerModule.buffer_size;
pub const debug = DockerModule.debug;

pub const Harness = @import("../../tests/harness.zig").Harness;

test "unit: docker satisfies module contract" {
    comptime module.validateModule(DockerModule);
}

test "integration: docker renders symbol when Dockerfile is present" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.writeFile("Dockerfile", "FROM alpine\n");
    try h.setConfig(
        \\format = "$docker"
        \\add_newline = false
    );

    const out = try h.collect(.generic);
    try Harness.expectContains(out, "");
}
