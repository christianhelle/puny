const std = @import("std");

pub const version = "0.1.0";

pub const Options = struct {
    url: []const u8 = "http://127.0.0.1:1234",
    model: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
};

pub fn parseArgs(args: []const [:0]const u8) !Options {
    var opts = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            printVersion();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--url") or std.mem.eql(u8, arg, "-u")) {
            i += 1;
            if (i >= args.len) return error.MissingUrlValue;
            opts.url = args[i];
        } else if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i >= args.len) return error.MissingModelValue;
            opts.model = args[i];
        } else if (std.mem.eql(u8, arg, "--prompt") or std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i >= args.len) return error.MissingPromptValue;
            opts.prompt = args[i];
        } else {
            return error.UnknownArgument;
        }
    }
    return opts;
}

pub fn printHelp() void {
    const out = std.io.getStdOut().writer();
    out.print(
        \\Usage: puny [options]
        \\
        \\Options:
        \\  -u, --url <url>        LM Studio endpoint URL (default: http://127.0.0.1:1234)
        \\  -m, --model <id>       Model identifier (skip picker if found in running models)
        \\  -p, --prompt <text>    Pre-fill prompt as first user message
        \\  -h, --help             Show this help text
        \\  -V, --version          Print version
        \\
    , .{}) catch {};
}

pub fn printVersion() void {
    const out = std.io.getStdOut().writer();
    out.print("puny {s}\n", .{version}) catch {};
}
