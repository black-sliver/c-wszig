const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // simple cwspp-like wrapper around websocket.zig
    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // cwspp-compatible c-bindings for root.zig
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // sample program using the c-bindings from a dll/so
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/sample.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // currently required for std.DynLib
    });

    const websocket_dep = b.dependency("websocket", .{});

    root_mod.addImport("websocket", websocket_dep.module("websocket"));
    lib_mod.addImport("ws", root_mod);

    const lib = b.addSharedLibrary(.{
        //.linkage = .dynamic,
        .name = "c-wspp",
        .root_module = lib_mod,
        .pic = true,
    });

    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "sample",
        .root_module = exe_mod,
        .pic = true,
    });

    exe.step.dependOn(&lib.step);

    b.installArtifact(exe);

    // run
    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // zig build run
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // unit tests
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // zig build test
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}
