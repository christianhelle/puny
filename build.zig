const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const is_small = optimize == .ReleaseSmall;
    const exe = b.addExecutable(.{
        .name = "puny",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = is_small,
            .unwind_tables = if (is_small) .none else null,
            .stack_check = if (is_small) false else null,
            .stack_protector = if (is_small) false else null,
            .error_tracing = if (is_small) false else null,
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    const zigzag = b.dependency("zigzag", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zigzag", zigzag.module("zigzag"));
    exe.root_module.addImport("tools", b.createModule(.{
        .root_source_file = b.path("src/tools/root.zig"),
        .target = target,
        .optimize = optimize,
    }));
}
