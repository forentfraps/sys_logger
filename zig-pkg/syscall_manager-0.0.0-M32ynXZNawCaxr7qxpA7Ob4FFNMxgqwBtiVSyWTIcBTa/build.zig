const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.addModule("syscall_manager", .{
        .root_source_file = b.path("src/syscall_manager.zig"),
        .target = target,
        .optimize = optimize,
    });

    const nasm = b.addSystemCommand(&.{ "nasm", "-f", "win64" });
    nasm.addFileArg(b.path("src/syscall_wrapper.asm"));
    nasm.addArg("-o");
    const obj_lp = nasm.addOutputFileArg("syscall_wrapper.o");
    nasm.expectExitCode(0);
    _ = nasm.captureStdOut();

    lib_mod.addObjectFile(obj_lp);

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "syscall_manager",
        .root_module = lib_mod,
    });

    b.installArtifact(lib);

    const asm_step = b.step("asm", "Assemble syscall_wrapper.asm with nasm");
    asm_step.dependOn(&nasm.step);

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&nasm.step);
    test_step.dependOn(&run_lib_unit_tests.step);
}
