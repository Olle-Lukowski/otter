const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("otter", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ecs_dep = b.dependency("ecs", .{});
    const ecs = ecs_dep.module("ecs");

    mod.addImport("ecs", ecs);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    unit_tests.root_module.addImport("ecs", ecs);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&unit_tests.step);
}
