const std = @import("std");

pub fn build(b: *std.Build) void {
    var target = b.standardTargetOptions(.{});
    target.result.os.tag = .windows;

    const optimize = b.standardOptimizeOption(.{});

    const syscall_dep = b.dependency("syscall_manager", .{ .target = target, .optimize = optimize });
    const syscall_module = syscall_dep.module("syscall_manager");
    const lib_mod = b.addModule("sys_logger", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("syscall_manager", syscall_module);

    const lib = b.addLibrary(.{
        // .linkage = .static,
        .name = "sys_logger",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    const test_mod = b.createModule(
        .{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        },
    );
    test_mod.addImport("syscall_manager", syscall_module);
    test_mod.addImport("logger_lib", lib_mod);

    const lib_unit_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
