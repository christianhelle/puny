const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const docker = b.option(bool, "docker", "Build for Docker container") orelse false;

    const build_options = createBuildInfoOptions(b);
    build_options.addOption(bool, "docker", docker);

    const exe = addPunyExecutable(b, "puny", target, optimize, build_options);

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
        .test_runner = .{ .path = b.path("src/custom_test_runner.zig"), .mode = .server },
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);

    const test_coverage_step = b.step("test-coverage", "Build test binary for coverage");
    const coverage_exe = b.addTest(.{
        .root_module = exe.root_module,
        .test_runner = .{ .path = b.path("src/custom_test_runner.zig"), .mode = .simple },
        .use_llvm = true,
    });
    b.installArtifact(coverage_exe);
    test_coverage_step.dependOn(b.getInstallStep());

    const docker_step = b.step("docker", "Build Docker image");
    const docker_build = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "-Ddocker",
        "-Doptimize=ReleaseSmall",
        "-Dtarget=x86_64-linux",
    });

    const dockerfile_step = b.step("generate-dockerfile", "Generate Dockerfile for container builds");
    const generate_dockerfile = b.addWriteFiles();
    _ = generate_dockerfile.add("Dockerfile",
        \\# Use a minimal base image
        \\FROM alpine:latest
        \\
        \\# Install necessary runtime dependencies
        \\RUN apk add --no-cache \
        \\    ca-certificates \
        \\    curl
        \\
        \\# Create a non-root user
        \\RUN addgroup -g 1001 -S puny && \
        \\    adduser -S -D -H -u 1001 -s /sbin/nologin puny -G puny
        \\
        \\# Copy the binary from the build artifacts
        \\COPY zig-out/bin/puny /usr/local/bin/puny
        \\
        \\# Make the binary executable
        \\RUN chmod +x /usr/local/bin/puny
        \\
        \\# Create a writable home/config directory for the non-root user.
        \\RUN mkdir -p /app && chown -R puny:puny /app
        \\ENV HOME=/app
        \\
        \\# Switch to non-root user
        \\USER puny
        \\
        \\# Set the working directory
        \\WORKDIR /app
        \\
        \\# Set the entrypoint
        \\ENTRYPOINT ["/usr/local/bin/puny"]
    );
    dockerfile_step.dependOn(&generate_dockerfile.step);

    const dockerfile_path = generate_dockerfile.getDirectory().path(b, "Dockerfile");
    const docker_build_image = b.addSystemCommand(&.{
        "docker", "build", "-t", "puny:local", "--file",
    });
    docker_build_image.addFileArg(dockerfile_path);
    docker_build_image.addArg(".");
    docker_build_image.step.dependOn(&docker_build.step);
    docker_build_image.step.dependOn(dockerfile_step);
    docker_step.dependOn(&docker_build_image.step);

    addInstallStep(b, target, build_options, "install-release", "Build ReleaseSmall and install to $HOME/.local/bin", .ReleaseSmall);
    addInstallStep(b, target, build_options, "install-release-safe", "Build ReleaseSafe and install to $HOME/.local/bin", .ReleaseSafe);
    addInstallStep(b, target, build_options, "install-release-fast", "Build ReleaseFast and install to $HOME/.local/bin", .ReleaseFast);
    addInstallStep(b, target, build_options, "install-debug", "Build Debug and install to $HOME/.local/bin", .Debug);

    const test_regression_step = b.step("test-regression", "Run cross-platform builds, unit tests, and regression tests");

    const cross_targets = [_][]const u8{
        "x86_64-linux",
        "aarch64-linux",
        "x86_64-macos",
        "aarch64-macos",
        "x86_64-windows-gnu",
        "aarch64-windows-gnu",
    };

    for (cross_targets) |triple| {
        const cross_query = try std.Target.Query.parse(.{ .arch_os_abi = triple });
        const cross_target = b.resolveTargetQuery(cross_query);
        const cross_exe = addPunyExecutable(b, b.fmt("puny-{s}", .{triple}), cross_target, optimize, build_options);
        const cross_step = b.step(b.fmt("build-{s}", .{triple}), b.fmt("Build for {s}", .{triple}));
        cross_step.dependOn(&cross_exe.step);
        test_regression_step.dependOn(cross_step);
    }

    const native_build_step = b.step("build-native", "Build native binary");
    native_build_step.dependOn(&exe.step);
    test_regression_step.dependOn(native_build_step);

    test_regression_step.dependOn(test_step);

    const slow_tests_root = b.createModule(.{
        .root_source_file = b.path("src/slow_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    slow_tests_root.addOptions("build_options", build_options);

    const slow_tests = b.addTest(.{
        .root_module = slow_tests_root,
        .test_runner = .{ .path = b.path("src/custom_test_runner.zig"), .mode = .server },
    });

    const run_slow_tests = b.addRunArtifact(slow_tests);
    test_regression_step.dependOn(&run_slow_tests.step);

    const regression_checker = b.addExecutable(.{
        .name = "regression_checker",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/regression_checker.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const run_regression = b.addRunArtifact(regression_checker);
    run_regression.addArtifactArg(exe);
    run_regression.addFileArg(b.path("tests/regression.json"));
    test_regression_step.dependOn(&run_regression.step);

    const integration_checker = b.addExecutable(.{
        .name = "integration_checker",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration_checker.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const run_integration = b.addRunArtifact(integration_checker);
    run_integration.addArtifactArg(exe);
    run_integration.addFileArg(b.path("tests/integration.json"));
    const test_integration_step = b.step("test-integration", "Run integration tests against all provider/model combos");
    test_integration_step.dependOn(&run_integration.step);

    const regenerate_step = b.step("re-generate-providers", "Re-generate provider clients from OpenAPI specs");
    const regenerate = RegenerateProvidersStep.create(b);
    regenerate_step.dependOn(&regenerate.step);
}

fn addPunyExecutable(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_options: *std.Build.Step.Options,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", build_options);

    if (target.result.os.tag == .windows) {
        exe.root_module.linkSystemLibrary("psapi", .{});
    }

    return exe;
}

fn addInstallStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    build_options: *std.Build.Step.Options,
    step_name: []const u8,
    description: []const u8,
    optimize: std.builtin.OptimizeMode,
) void {
    const exe = addPunyExecutable(b, "puny", target, optimize, build_options);
    const install_step = b.step(step_name, description);
    const install = InstallReleaseStep.create(b, @tagName(optimize), exe.getEmittedBin(), getInstallPrefix(b), exe.out_filename);
    install_step.dependOn(&install.step);
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

fn getInstallPrefix(b: *std.Build) []const u8 {
    // Honor an explicit `--prefix` flag.
    const default_prefix = b.build_root.join(b.allocator, &.{"zig-out"}) catch @panic("OOM");
    if (!std.mem.eql(u8, b.install_prefix, default_prefix)) {
        return b.install_prefix;
    }

    // Honor the INSTALL_DIR environment variable used by the install scripts.
    if (b.graph.environ_map.get("INSTALL_DIR")) |install_dir| {
        if (install_dir.len > 0) return install_dir;
    }

    // Default to $HOME/.local/bin, falling back to %USERPROFILE% on Windows.
    if (b.graph.environ_map.get("HOME")) |home| {
        if (home.len > 0) return b.pathJoin(&.{ home, ".local", "bin" });
    }
    if (b.graph.environ_map.get("USERPROFILE")) |home| {
        if (home.len > 0) return b.pathJoin(&.{ home, ".local", "bin" });
    }

    @panic("unable to determine install directory: set HOME, USERPROFILE, or INSTALL_DIR");
}

const InstallReleaseStep = struct {
    step: std.Build.Step,
    source: std.Build.LazyPath,
    dest_dir: []const u8,
    dest_name: []const u8,

    fn create(
        b: *std.Build,
        label: []const u8,
        source: std.Build.LazyPath,
        dest_dir: []const u8,
        dest_name: []const u8,
    ) *InstallReleaseStep {
        const self = b.allocator.create(InstallReleaseStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = b.fmt("install {s} ({s}) to {s}", .{ dest_name, label, dest_dir }),
                .owner = b,
                .makeFn = make,
            }),
            .source = source.dupe(b),
            .dest_dir = b.dupePath(dest_dir),
            .dest_name = b.dupePath(dest_name),
        };
        source.addStepDependencies(&self.step);
        return self;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        _ = options;
        const b = step.owner;
        const self: *InstallReleaseStep = @fieldParentPtr("step", step);
        const dest_path = b.pathResolve(&.{ self.dest_dir, self.dest_name });
        const p = try step.installFile(self.source, dest_path);
        step.result_cached = p == .fresh;
    }
};

const RegenerateProvidersStep = struct {
    step: std.Build.Step,

    fn create(b: *std.Build) *RegenerateProvidersStep {
        const self = b.allocator.create(RegenerateProvidersStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "re-generate providers",
                .owner = b,
                .makeFn = make,
            }),
        };
        return self;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        _ = options;
        const b = step.owner;
        const allocator = b.allocator;
        const io = b.graph.io;
        const cwd = std.Io.Dir.cwd();

        // Remove existing provider output directories (mirrors generate.ps1 Remove-Item)
        for ([_][]const u8{
            "src/providers/openai",
            "src/providers/lmstudio",
            "src/providers/anthropic",
        }) |dir| {
            cwd.deleteTree(io, dir) catch |err| {
                if (err == error.FileNotFound) {
                    std.log.info("skipping missing {s}", .{dir});
                    continue;
                }
                std.log.err("failed to remove {s}: {s}", .{ dir, @errorName(err) });
                return err;
            };
            std.log.info("removed {s}", .{dir});
        }

        const openapi2zig_exe = b.findProgram(&.{"openapi2zig"}, &.{}) catch |err| switch (err) {
            error.FileNotFound => blk: {
                std.log.warn("openapi2zig not found via build search, trying PATH", .{});
                break :blk "openapi2zig";
            },
        };
        std.log.info("using openapi2zig: {s}", .{openapi2zig_exe});

        // 1. Generate shared runtime (mirrors `openapi2zig generate -o ../runtime.zig --runtime-only` in generate.ps1)
        try runOpenApi2Zig(allocator, io, openapi2zig_exe, &.{
            "generate",
            "-o",
            "src/providers/runtime.zig",
            "--runtime-only",
        });

        // 2. Generate openai with shared runtime – only Chat + Models are used (provider.zig, openai_shim.zig)
        try runOpenApi2Zig(allocator, io, openapi2zig_exe, &.{
            "generate",
            "-i",
            "src/providers/openapi/openai.json",
            "-o",
            "src/providers/openai/",
            "--multiple-files",
            "--file-name",
            "models=contracts.zig",
            "--runtime-module",
            "../runtime.zig",
            "--tag",
            "Chat",
            "--tag",
            "Models",
        });

        // 3. Generate lmstudio with shared runtime – only Models is used via lmstudio_shim.zig
        try runOpenApi2Zig(allocator, io, openapi2zig_exe, &.{
            "generate",
            "-i",
            "src/providers/openapi/lmstudio.json",
            "-o",
            "src/providers/lmstudio",
            "--multiple-files",
            "--file-name",
            "models=contracts.zig",
            "--runtime-module",
            "../runtime.zig",
            "--tag",
            "Models",
        });

        // 4. Generate anthropic with shared runtime – only Messages is used (anthropic.zig + provider.zig)
        try runOpenApi2Zig(allocator, io, openapi2zig_exe, &.{
            "generate",
            "-i",
            "src/providers/openapi/anthropic.json",
            "-o",
            "src/providers/anthropic/",
            "--multiple-files",
            "--file-name",
            "models=contracts.zig",
            "--runtime-module",
            "../runtime.zig",
            "--tag",
            "Messages",
        });

        std.log.info("re-generate-providers: done", .{});
    }

    fn runOpenApi2Zig(
        allocator: std.mem.Allocator,
        io: std.Io,
        exe: []const u8,
        args: []const []const u8,
    ) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.append(allocator, exe);
        for (args) |a| try argv.append(allocator, a);

        const joined = try std.mem.join(allocator, " ", argv.items);
        defer allocator.free(joined);
        std.log.info("running: {s}", .{joined});

        const result = std.process.run(allocator, io, .{
            .argv = argv.items,
            .stdout_limit = .limited(4 * 1024 * 1024),
            .stderr_limit = .limited(4 * 1024 * 1024),
        }) catch |err| {
            std.log.err("failed to spawn openapi2zig: {s}", .{@errorName(err)});
            return err;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (result.stdout.len > 0) std.log.info("{s}", .{result.stdout});
        if (result.stderr.len > 0) std.log.info("{s}", .{result.stderr});

        switch (result.term) {
            .exited => |code| {
                if (code != 0) {
                    std.log.err("openapi2zig exited with code {d}", .{code});
                    if (result.stderr.len > 0) std.log.err("stderr: {s}", .{result.stderr});
                    return error.OpenApi2ZigFailed;
                }
            },
            else => {
                std.log.err("openapi2zig terminated abnormally: {any}", .{result.term});
                return error.OpenApi2ZigFailed;
            },
        }
    }
};

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
