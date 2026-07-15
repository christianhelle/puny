const std = @import("std");

pub const version = "0.1.0";

pub const Options = struct {
    provider: ?[]const u8 = null,
    url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    api_key_file: ?[]const u8 = null,
    model: ?[]const u8 = null,
    model_explicit: bool = false,
    prompt: ?[]const u8 = null,
    oneshot: bool = false,
    mock: bool = false,
    reconfigure: bool = false,
};

fn writeErr(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    var w: std.Io.File.Writer = .init(.stdout(), io, &buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}

fn fatal(io: std.Io, comptime fmt: []const u8, args: anytype) noreturn {
    writeErr(io, fmt, args);
    printHelp(io);
    std.process.exit(1);
}

pub fn parseArgs(io: std.Io, environ_map: *const std.process.Environ.Map, args: []const [:0]const u8) Options {
    var opts = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp(io);
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            printVersion(io);
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--provider")) {
            i += 1;
            if (i >= args.len) fatal(io, "Missing value for {s}\n\n", .{arg});
            opts.provider = args[i];
        } else if (std.mem.eql(u8, arg, "--url") or std.mem.eql(u8, arg, "-u")) {
            i += 1;
            if (i >= args.len) fatal(io, "Missing value for {s}\n\n", .{arg});
            opts.url = args[i];
        } else if (std.mem.eql(u8, arg, "--api-key") or std.mem.eql(u8, arg, "-k")) {
            i += 1;
            if (i >= args.len) fatal(io, "Missing value for {s}\n\n", .{arg});
            opts.api_key = args[i];
        } else if (std.mem.eql(u8, arg, "--api-key-file")) {
            i += 1;
            if (i >= args.len) fatal(io, "Missing value for {s}\n\n", .{arg});
            opts.api_key_file = args[i];
        } else if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i >= args.len) fatal(io, "Missing value for {s}\n\n", .{arg});
            opts.model = args[i];
            opts.model_explicit = true;
        } else if (std.mem.eql(u8, arg, "--mock") or std.mem.eql(u8, arg, "-M")) {
            opts.mock = true;
        } else if (std.mem.eql(u8, arg, "--oneshot") or std.mem.eql(u8, arg, "--one-shot") or std.mem.eql(u8, arg, "-1")) {
            opts.oneshot = true;
        } else if (std.mem.eql(u8, arg, "--prompt") or std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i >= args.len) fatal(io, "Missing value for {s}\n\n", .{arg});
            opts.prompt = args[i];
        } else if (std.mem.eql(u8, arg, "--reconfigure")) {
            opts.reconfigure = true;
        } else {
            fatal(io, "Unknown argument: {s}\n\n", .{arg});
        }
    }
    if (opts.oneshot and opts.prompt == null) {
        fatal(io, "--oneshot requires --prompt\n\n", .{});
    }

    if (opts.provider == null) {
        if (environ_map.get("PUNY_PROVIDER")) |value| {
            opts.provider = value;
        }
    }
    if (opts.url == null) {
        if (environ_map.get("PUNY_PROVIDER_URL")) |value| {
            opts.url = value;
        }
    }
    if (opts.model == null) {
        if (environ_map.get("PUNY_MODEL")) |value| {
            opts.model = value;
        }
    }
    if (!opts.mock) {
        if (environ_map.get("PUNY_MOCK")) |value| {
            opts.mock = std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true");
        }
    }

    return opts;
}

pub fn printHelp(io: std.Io) void {
    writeErr(io,
        \\Usage: puny [options]
        \\
        \\Options:
        \\      --provider <name>    Provider to use: lmstudio or opencode (env/config/CLI precedence)
        \\  -u, --url <url>        Provider endpoint URL (config/env/CLI precedence)
        \\  -k, --api-key <key>    Provider API token (env/CLI precedence, session only)
        \\      --api-key-file <path>  Read API token from file
        \\  -m, --model <id>       Model identifier (skip picker if found in running models)
        \\  -p, --prompt <text>    Pre-fill prompt as first user message
        \\  -1, --oneshot, --one-shot  Exit after processing the prompt (requires --prompt)
        \\  -M, --mock             Use mock provider (no LM Studio required)
        \\      --reconfigure      Re-run first-run setup and update config
        \\  -h, --help             Show this help text
        \\  -V, --version          Print version
        \\
    , .{});
}

pub fn printVersion(io: std.Io) void {
    writeErr(io, "puny {s}\n", .{version});
}

test "parseArgs sets provider from flag" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    const args = &[_][:0]const u8{ "puny", "--provider", "opencode" };
    const opts = parseArgs(undefined, &env, args);
    try std.testing.expectEqualStrings("opencode", opts.provider.?);
}

test "parseArgs falls back to PUNY_PROVIDER env" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("PUNY_PROVIDER", "opencode");

    const args = &[_][:0]const u8{"puny"};
    const opts = parseArgs(undefined, &env, args);
    try std.testing.expectEqualStrings("opencode", opts.provider.?);
}

test "parseArgs flag overrides PUNY_PROVIDER env" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("PUNY_PROVIDER", "lmstudio");

    const args = &[_][:0]const u8{ "puny", "--provider", "opencode" };
    const opts = parseArgs(undefined, &env, args);
    try std.testing.expectEqualStrings("opencode", opts.provider.?);
}
