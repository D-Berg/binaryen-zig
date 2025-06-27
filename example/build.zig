const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const binaryen_dep = b.dependency("binaryen", .{
        .target = target,
        .optimize = optimize,
        .strip = true,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // option 1
    exe_mod.addImport("c", binaryen_dep.module("binaryen-c"));

    // option 2
    // const translate_c = b.addTranslateC(.{
    //     .root_source_file = b.path("c.h"),
    //     .target = target,
    //     .optimize = optimize,
    //     .link_libc = true,
    // });
    // translate_c.addIncludePath(binaryen_dep.namedLazyPath("binaryen-c.h"));
    // exe_mod.addImport("c", translate_c.createModule());
    // exe_mod.linkLibrary(binaryen_dep.artifact("binaryen"));

    const exe = b.addExecutable(.{
        .name = "binaryen_tests",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
