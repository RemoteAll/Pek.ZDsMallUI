const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zzig_dep = b.dependency("zzig", .{ .target = target, .optimize = optimize });
    const zio_dep = b.dependency("zio", .{ .target = target, .optimize = optimize });

    const mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("zzig", zzig_dep.module("zzig"));
    mod.addImport("zio", zio_dep.module("zio"));

    const exe = b.addExecutable(.{ .name = "zbench", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    const step = b.step("run", "HTTP bench server (zzig + zio)");
    step.dependOn(&run.step);
}
