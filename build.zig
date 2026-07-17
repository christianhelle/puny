const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const docker = b.option(bool, "docker", "Build for Docker container") orelse false;

    const build_options = createBuildInfoOptions(b);
    build_options.addOption(bool, "docker", docker);

    const exe = b.addExecutable(.{
        .name = "puny",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", build_options);

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

    const docker_step = b.step("docker", "Build Linux binary for Docker");
    const docker_build = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "-Ddocker",
        "-Doptimize=ReleaseSmall",
        "-Dtarget=x86_64-linux",
    });
    docker_step.dependOn(&docker_build.step);

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

fn createBuildInfoOptions(b: *std.Build) *std.Build.Step.Options {
    const options = b.addOptions();
    const io = b.graph.io;
    const package_version = getPackageVersion(b.allocator, io) orelse "unknown";
    const git_tag = getGitOutput(b.allocator, io, &.{ "git", "describe", "--tags", "--abbrev=0" }) orelse b.fmt("v{s}", .{package_version});
    const git_commit = getGitOutput(b.allocator, io, &.{ "git", "rev-parse", "--short", "HEAD" }) orelse "unknown";
    const dirty = isGitDirty(b.allocator, io);
    const version = if (std.mem.startsWith(u8, git_tag, "v")) git_tag[1..] else git_tag;

    options.addOption([]const u8, "VERSION", version);
    options.addOption([]const u8, "GIT_COMMIT", git_commit);
    options.addOption(bool, "DIRTY", dirty);

    return options;
}

fn getPackageVersion(allocator: std.mem.Allocator, io: std.Io) ?[]const u8 {
    const content = std.Io.Dir.cwd().readFileAlloc(io, "build.zig.zon", allocator, .limited(64 * 1024)) catch return null;
    const marker = ".version = \"";
    const start = std.mem.indexOf(u8, content, marker) orelse return null;
    const version_start = start + marker.len;
    const version_end = std.mem.indexOfScalarPos(u8, content, version_start, '"') orelse return null;
    return content[version_start..version_end];
}

fn isGitDirty(allocator: std.mem.Allocator, io: std.Io) bool {
    const output = getGitOutput(allocator, io, &.{ "git", "status", "--porcelain" }) orelse return false;
    return output.len > 0;
}

fn getGitOutput(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) ?[]const u8 {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(16 * 1024),
    }) catch return null;
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code == 0) {
                return std.mem.trim(u8, result.stdout, " \t\n\r");
            } else {
                allocator.free(result.stdout);
                return null;
            }
        },
        else => {
            allocator.free(result.stdout);
            return null;
        },
    }
}
