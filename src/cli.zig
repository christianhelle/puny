const std = @import("std");

pub const version = "0.1.0";

pub const Options = struct {
    url: []const u8 = "http://127.0.0.1:1234",
    model: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    oneshot: bool = false,
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

pub fn parseArgs(io: std.Io, args: []const [:0]const u8) Options {
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
        } else if (std.mem.eql(u8, arg, "--url") or std.mem.eql(u8, arg, "-u")) {
            i += 1;
            if (i >= args.len) fatal(io, "Missing value for {s}\n\n", .{arg});
            opts.url = args[i];
        } else if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i >= args.len) fatal(io, "Missing value for {s}\n\n", .{arg});
            opts.model = args[i];
        } else if (std.mem.eql(u8, arg, "--oneshot") or std.mem.eql(u8, arg, "-1")) {
            opts.oneshot = true;
        } else if (std.mem.eql(u8, arg, "--prompt") or std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i >= args.len) fatal(io, "Missing value for {s}\n\n", .{arg});
            opts.prompt = args[i];
        } else {
            fatal(io, "Unknown argument: {s}\n\n", .{arg});
        }
    }
    return opts;
}

pub fn printHelp(io: std.Io) void {
    writeErr(io,
        \\Usage: puny [options]
        \\
        \\Options:
        \\  -u, --url <url>        LM Studio endpoint URL (default: http://127.0.0.1:1234)
        \\  -m, --model <id>       Model identifier (skip picker if found in running models)
        \\  -p, --prompt <text>    Pre-fill prompt as first user message
        \\  -1, --oneshot          Exit after processing the prompt (requires --prompt)
        \\  -h, --help             Show this help text
        \\  -V, --version          Print version
        \\
    , .{});
}

pub fn printVersion(io: std.Io) void {
    writeErr(io, "puny {s}\n", .{version});
}
