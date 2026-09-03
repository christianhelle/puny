//! Regenerates the provider clients from the OpenAPI specs under
//! src/providers/openapi. Run it with `zig build regenerate-providers`.
//!
//! openapi2zig is linked in as a library, so generation uses the exact
//! generator the CLI runs without needing the CLI installed.

const std = @import("std");
const openapi2zig = @import("openapi2zig");

/// Output directories that are wiped before regenerating, so files that a
/// spec no longer produces do not linger.
const generated_dirs = [_][]const u8{
    "src/providers/openai",
    "src/providers/lmstudio",
    "src/providers/anthropic",
    "src/providers/google",
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    for (generated_dirs) |dir| {
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

    // 1. The shared runtime every provider client imports. No spec is read
    //    for this one, hence the empty input path.
    try openapi2zig.generateFromSpec(allocator, io, .{
        .input_path = "",
        .output_path = "src/providers/runtime.zig",
        .runtime_only = true,
    });

    // Streaming clients must consume non-success response bodies before
    // notifying observers; provider regression tests guard this behavior.
    // 2. openai – Chat + Models + Responses are used (provider.zig, openai_shim.zig, responses transport)
    try openapi2zig.generateFromSpec(allocator, io, .{
        .input_path = "src/providers/openapi/openai.json",
        .output_path = "src/providers/openai/",
        .multiple_files = true,
        .file_names = .{ .models = "contracts.zig" },
        .runtime_module = "../runtime.zig",
        .tags = &.{ "Chat", "Models", "Responses" },
    });

    // 3. lmstudio – only Models is used via lmstudio_shim.zig
    try openapi2zig.generateFromSpec(allocator, io, .{
        .input_path = "src/providers/openapi/lmstudio.json",
        .output_path = "src/providers/lmstudio",
        .multiple_files = true,
        .file_names = .{ .models = "contracts.zig" },
        .runtime_module = "../runtime.zig",
        .tags = &.{"Models"},
    });

    // 4. anthropic – only Messages is used (anthropic.zig + provider.zig)
    try openapi2zig.generateFromSpec(allocator, io, .{
        .input_path = "src/providers/openapi/anthropic.json",
        .output_path = "src/providers/anthropic/",
        .multiple_files = true,
        .file_names = .{ .models = "contracts.zig" },
        .runtime_module = "../runtime.zig",
        .tags = &.{"Messages"},
    });

    // 5. google – only models is used (google.zig)
    try openapi2zig.generateFromSpec(allocator, io, .{
        .input_path = "src/providers/openapi/google.json",
        .output_path = "src/providers/google/",
        .multiple_files = true,
        .file_names = .{ .models = "contracts.zig" },
        .runtime_module = "../runtime.zig",
        .tags = &.{"models"},
    });

    try patchGoogleGeneratedFiles(allocator, io, cwd);

    std.log.info("regenerate-providers: done", .{});
}

fn patchGoogleGeneratedFiles(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir) !void {
    // Fix client: /v1beta/ss/ -> /v1beta/models/ and Bearer -> x-goog-api-key
    {
        const path = "src/providers/google/client.zig";
        const content = cwd.readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024)) catch |err| {
            if (err == error.FileNotFound) {
                std.log.warn("google client not found for patching: {s}", .{path});
                return;
            }
            return err;
        };
        defer allocator.free(content);
        const patched = try std.mem.replaceOwned(u8, allocator, content, "/v1beta/ss/", "/v1beta/models/");
        defer allocator.free(patched);
        const patched2 = try std.mem.replaceOwned(u8, allocator, patched, "\"Bearer {s}\"", "\"{s}\"");
        defer allocator.free(patched2);
        const patched3 = try std.mem.replaceOwned(u8, allocator, patched2, "\"Authorization\"", "\"x-goog-api-key\"");
        defer allocator.free(patched3);
        try cwd.writeFile(io, .{ .sub_path = path, .data = patched3 });
        std.log.info("patched {s} for Google auth and path", .{path});
    }
    // Fix contracts: Schema.items ?Schema -> ?*Schema to avoid infinite size recursion
    {
        const path = "src/providers/google/contracts.zig";
        const content = cwd.readFileAlloc(io, path, allocator, .limited(2 * 1024 * 1024)) catch |err| {
            if (err == error.FileNotFound) {
                std.log.warn("google contracts not found for patching: {s}", .{path});
                return;
            }
            return err;
        };
        defer allocator.free(content);
        // Only patch the specific line: items: ?Schema -> items: ?*Schema
        const search = "    items: ?Schema = null,";
        const replace = "    items: ?*Schema = null,";
        if (std.mem.indexOf(u8, content, search) != null) {
            const patched = try std.mem.replaceOwned(u8, allocator, content, search, replace);
            defer allocator.free(patched);
            try cwd.writeFile(io, .{ .sub_path = path, .data = patched });
            std.log.info("patched {s} Schema.items recursion", .{path});
        }
    }
}
