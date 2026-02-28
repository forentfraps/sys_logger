const std = @import("std");
pub fn build(b: *std.Build) void {
    var target = b.standardTargetOptions(.{});
    target.result.os.tag = .windows;
    const optimize = b.standardOptimizeOption(.{});
    const lib_mod = b.addModule("sys_logger", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const syscall_dep = b.dependency("syscall_manager", .{});
    const syscall_module = syscall_dep.module("syscall_manager");
    lib_mod.addImport("syscall_manager", syscall_module);
    const zigwin32 = b.dependency("zigwin32", .{});
    lib_mod.addImport("zigwin32", zigwin32.module("win32"));
    const lib = b.addLibrary(.{
        .name = "sys_logger",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zigwin32", zigwin32.module("win32"));
    exe_mod.addImport("syscall_manager", syscall_module);
    exe_mod.addImport("root.zig", lib_mod);

    const exe = b.addExecutable(.{
        .name = "tests",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    const run_step = b.step("test", "Run the test binary");
    run_step.dependOn(&run.step);

    b.step("check", "zls step").dependOn(&exe.step);
}
