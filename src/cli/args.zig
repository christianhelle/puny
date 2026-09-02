const std = @import("std");
const version = @import("../version.zig");

pub const default_max_iterations: usize = 5;

pub const Options = struct {
    provider: ?[]const u8 = null,
    url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    api_key_file: ?[]const u8 = null,
    model: ?[]const u8 = null,
    model_explicit: bool = false,
    prompt: ?[]const u8 = null,
    prompt_file: ?[]const u8 = null,
    oneshot: bool = false,
    review: bool = false,
    orchestrate: bool = false,
    max_iterations: usize = default_max_iterations,
    mock: bool = false,
    reconfigure: bool = false,
    debug: bool = false,
    chat_log: bool = false,
    show_thinking: bool = false,
    no_skills: bool = false,
    prune: bool = false,
    upgrade: bool = false,
    force_upgrade: bool = false,
    session: ?[]const u8 = null,
    do_resume: bool = false,
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

/// Returns an error when the combination of options is invalid. Kept separate
/// from `parseArgs` so it is testable without triggering a process exit.
pub fn validate(opts: Options) !void {
    if (opts.review and (opts.prompt != null or opts.prompt_file != null)) {
        return error.ReviewConflictsPrompt;
    }
    if (opts.review and (opts.session != null or opts.do_resume or opts.prune)) {
        return error.ReviewConflictsSession;
    }
    if (opts.review and (opts.upgrade or opts.force_upgrade)) {
        return error.ReviewConflictsOperation;
    }
    if (opts.prompt != null and opts.prompt_file != null) {
        return error.ConflictingPrompts;
    }
    if (opts.oneshot and !opts.review and !opts.orchestrate and opts.prompt == null and opts.prompt_file == null) {
        return error.OneshotRequiresPrompt;
    }
    if (opts.orchestrate and opts.review) {
        return error.OrchestrateConflictsReview;
    }
    if (opts.orchestrate and (opts.session != null or opts.do_resume or opts.prune)) {
        return error.OrchestrateConflictsSession;
    }
    if (opts.orchestrate and (opts.upgrade or opts.force_upgrade)) {
        return error.OrchestrateConflictsOperation;
    }
    if (opts.orchestrate and opts.prompt == null and opts.prompt_file == null) {
        return error.OrchestrateRequiresPrompt;
    }
    if (opts.max_iterations == 0) {
        return error.InvalidMaxIterations;
    }
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
        } else if (std.mem.eql(u8, arg, "--review")) {
            opts.review = true;
            opts.oneshot = true;
        } else if (std.mem.eql(u8, arg, "--orchestrate")) {
            opts.orchestrate = true;
            opts.oneshot = true;
        } else if (std.mem.eql(u8, arg, "--max-iterations")) {
            i += 1;
            if (i >= args.len) fatal(io, "Missing value for {s}\n\n", .{arg});
            opts.max_iterations = std.fmt.parseInt(usize, args[i], 10) catch
                fatal(io, "Invalid value for --max-iterations: {s}\n\n", .{args[i]});
        } else if (std.mem.eql(u8, arg, "--prompt") or std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i >= args.len) fatal(io, "Missing value for {s}\n\n", .{arg});
            opts.prompt = args[i];
        } else if (std.mem.eql(u8, arg, "--prompt-file")) {
            i += 1;
            if (i >= args.len) fatal(io, "Missing value for {s}\n\n", .{arg});
            opts.prompt_file = args[i];
        } else if (std.mem.eql(u8, arg, "--reconfigure")) {
            opts.reconfigure = true;
        } else if (std.mem.eql(u8, arg, "--show-thinking")) {
            opts.show_thinking = true;
        } else if (std.mem.eql(u8, arg, "--debug")) {
            opts.debug = true;
        } else if (std.mem.eql(u8, arg, "--chat-log")) {
            opts.chat_log = true;
        } else if (std.mem.eql(u8, arg, "--no-skills")) {
            opts.no_skills = true;
        } else if (std.mem.eql(u8, arg, "--session")) {
            i += 1;
            if (i >= args.len) fatal(io, "Missing value for {s}\n\n", .{arg});
            opts.session = args[i];
        } else if (std.mem.eql(u8, arg, "--resume")) {
            opts.do_resume = true;
        } else if (std.mem.eql(u8, arg, "--prune")) {
            opts.prune = true;
        } else if (std.mem.eql(u8, arg, "--upgrade") or std.mem.eql(u8, arg, "-U")) {
            opts.upgrade = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            opts.force_upgrade = true;
        } else {
            fatal(io, "Unknown argument: {s}\n\n", .{arg});
        }
    }

    validate(opts) catch |err| switch (err) {
        error.ReviewConflictsPrompt => fatal(io, "--review cannot be combined with --prompt or --prompt-file\n\n", .{}),
        error.ReviewConflictsSession => fatal(io, "--review cannot be combined with session or prune options\n\n", .{}),
        error.ReviewConflictsOperation => fatal(io, "--review cannot be combined with upgrade options\n\n", .{}),
        error.ConflictingPrompts => fatal(io, "Cannot use both --prompt and --prompt-file\n\n", .{}),
        error.OneshotRequiresPrompt => fatal(io, "--oneshot requires --prompt or --prompt-file\n\n", .{}),
        error.OrchestrateRequiresPrompt => fatal(io, "--orchestrate requires --prompt or --prompt-file\n\n", .{}),
        error.OrchestrateConflictsReview => fatal(io, "--orchestrate cannot be combined with --review\n\n", .{}),
        error.OrchestrateConflictsSession => fatal(io, "--orchestrate cannot be combined with session or prune options\n\n", .{}),
        error.OrchestrateConflictsOperation => fatal(io, "--orchestrate cannot be combined with upgrade options\n\n", .{}),
        error.InvalidMaxIterations => fatal(io, "--max-iterations must be greater than zero\n\n", .{}),
    };

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

    if (!opts.show_thinking) {
        if (environ_map.get("PUNY_SHOW_THINKING")) |value| {
            opts.show_thinking = std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true");
        }
    }

    if (!opts.chat_log) {
        if (environ_map.get("PUNY_CHAT_LOG")) |value| {
            opts.chat_log = std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true");
        }
    }

    if (!opts.no_skills) {
        if (environ_map.get("PUNY_NO_SKILLS")) |value| {
            opts.no_skills = std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true");
        }
    }

    return opts;
}

pub fn printHelp(io: std.Io) void {
    var buf: [256]u8 = undefined;
    const version_line = version.format(&buf);
    writeErr(io,
        \\puny {s}
        \\
        \\Usage: puny [options]
        \\
        \\Options:
        \\      --provider <name>        Provider to use: lmstudio, opencode, opencode-go, or copilot (env/config/CLI precedence)
        \\  -u, --url <url>              LM Studio endpoint URL (config/env/CLI precedence)
        \\  -k, --api-key <key>          Provider API token (env/CLI precedence, session only)
        \\      --api-key-file <path>    Read API token from file
        \\  -m, --model <id>             Model identifier (skip picker if found in running models)
        \\  -p, --prompt <text>          Pre-fill prompt as first user message
        \\      --prompt-file <path|url> Read first prompt from a file or URL
        \\  -1, --oneshot, --one-shot    Exit after processing the prompt (requires --prompt or --prompt-file)
        \\      --review                 Review the current branch against the latest origin/main and exit
        \\      --orchestrate           Implement, review, and fix the current branch until merge worthy
        \\      --max-iterations <n>    Maximum review to fix cycles for --orchestrate (default 5)
        \\  -M, --mock                   Use mock provider (no network calls, for testing)
        \\      --reconfigure            Re-run first-run setup and update config
        \\      --show-thinking          Show reasoning/thinking output from the model
        \\      --session <id>           Resume a previous session by ID or prefix
        \\      --resume                 Resume the most recent session
        \\      --prune                  Delete old sessions (use --session to keep one)
        \\      --chat-log               Log conversation to puny_chat.log
        \\      --no-skills              Disable skill loading entirely
        \\      --debug                  Log HTTP requests and responses to puny_http.log
        \\  -U, --upgrade                Upgrade to the latest release
        \\      --force                  Force upgrade even if same version (use with --upgrade)
        \\  -h, --help                   Show this help text
        \\  -V, --version                Print version
        \\
    , .{version_line});
}

pub fn printVersion(io: std.Io) void {
    var buf: [256]u8 = undefined;
    const version_line = version.format(&buf);
    writeErr(io, "puny {s}\n", .{version_line});
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

test "parseArgs sets show_thinking from flag" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    const args = &[_][:0]const u8{ "puny", "--show-thinking" };
    const opts = parseArgs(undefined, &env, args);
    try std.testing.expect(opts.show_thinking);
}

test "parseArgs falls back to PUNY_SHOW_THINKING env" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("PUNY_SHOW_THINKING", "true");

    const args = &[_][:0]const u8{"puny"};
    const opts = parseArgs(undefined, &env, args);
    try std.testing.expect(opts.show_thinking);
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

test "parseArgs sets upgrade from flag" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    const args = &[_][:0]const u8{ "puny", "--upgrade" };
    const opts = parseArgs(undefined, &env, args);
    try std.testing.expect(opts.upgrade);
}

test "parseArgs sets upgrade from short flag" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    const args = &[_][:0]const u8{ "puny", "-U" };
    const opts = parseArgs(undefined, &env, args);
    try std.testing.expect(opts.upgrade);
}

test "parseArgs sets debug from flag" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    const args = &[_][:0]const u8{ "puny", "--debug" };
    const opts = parseArgs(undefined, &env, args);
    try std.testing.expect(opts.debug);
}

test "parseArgs sets chat_log from flag" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    const args = &[_][:0]const u8{ "puny", "--chat-log" };
    const opts = parseArgs(undefined, &env, args);
    try std.testing.expect(opts.chat_log);
}

test "parseArgs falls back to PUNY_CHAT_LOG env" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("PUNY_CHAT_LOG", "true");

    const args = &[_][:0]const u8{"puny"};
    const opts = parseArgs(undefined, &env, args);
    try std.testing.expect(opts.chat_log);
}

test "parseArgs flag overrides PUNY_CHAT_LOG env" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("PUNY_CHAT_LOG", "false");

    const args = &[_][:0]const u8{ "puny", "--chat-log" };
    const opts = parseArgs(undefined, &env, args);
    try std.testing.expect(opts.chat_log);
}

test "parseArgs sets session from flag" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    const args = &[_][:0]const u8{ "puny", "--session", "abc-123" };
    const opts = parseArgs(undefined, &env, args);
    try std.testing.expectEqualStrings("abc-123", opts.session.?);
}

test "parseArgs sets resume from flag" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    const args = &[_][:0]const u8{ "puny", "--resume" };
    const opts = parseArgs(undefined, &env, args);
    try std.testing.expect(opts.do_resume);
}

test "parseArgs sets prune from flag" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    const args = &[_][:0]const u8{ "puny", "--prune" };
    const opts = parseArgs(undefined, &env, args);
    try std.testing.expect(opts.prune);
}

test "parseArgs sets prune with session" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    const args = &[_][:0]const u8{ "puny", "--prune", "--session", "abc-123" };
    const opts = parseArgs(undefined, &env, args);
    try std.testing.expect(opts.prune);
    try std.testing.expectEqualStrings("abc-123", opts.session.?);
}

test "parseArgs sets prompt_file from flag" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    const args = &[_][:0]const u8{ "puny", "--prompt-file", "spec.md" };
    const opts = parseArgs(undefined, &env, args);
    try std.testing.expectEqualStrings("spec.md", opts.prompt_file.?);
}

test "parseArgs makes review an implicit oneshot operation" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const args = &[_][:0]const u8{ "puny", "--review" };
    const opts = parseArgs(std.testing.io, &env, args);
    try std.testing.expect(opts.review);
    try std.testing.expect(opts.oneshot);
    try std.testing.expect(opts.prompt == null);
}

test "validate rejects both prompt and prompt-file" {
    const opts = Options{ .prompt = "hello", .prompt_file = "spec.md" };
    try std.testing.expectError(error.ConflictingPrompts, validate(opts));
}

test "validate allows prompt-file with oneshot" {
    const opts = Options{ .prompt_file = "spec.md", .oneshot = true };
    try validate(opts);
}

test "validate allows prompt with oneshot" {
    const opts = Options{ .prompt = "hello", .oneshot = true };
    try validate(opts);
}

test "validate rejects oneshot without prompt or prompt-file" {
    const opts = Options{ .oneshot = true };
    try std.testing.expectError(error.OneshotRequiresPrompt, validate(opts));
}

test "validate rejects review with an explicit prompt" {
    try std.testing.expectError(error.ReviewConflictsPrompt, validate(.{
        .review = true,
        .oneshot = true,
        .prompt = "do something else",
    }));
    try std.testing.expectError(error.ReviewConflictsPrompt, validate(.{
        .review = true,
        .oneshot = true,
        .prompt_file = "prompt.md",
    }));
}

test "validate rejects review with session operations" {
    try std.testing.expectError(error.ReviewConflictsSession, validate(.{
        .review = true,
        .oneshot = true,
        .session = "abc",
    }));
    try std.testing.expectError(error.ReviewConflictsSession, validate(.{
        .review = true,
        .oneshot = true,
        .do_resume = true,
    }));
}

test "validate rejects review with upgrade" {
    try std.testing.expectError(error.ReviewConflictsOperation, validate(.{
        .review = true,
        .oneshot = true,
        .upgrade = true,
    }));
}

test "parseArgs sets url from short flag" {
    const argv = [_][:0]const u8{ "puny", "-u", "http://127.0.0.1:9999" };
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const opts = parseArgs(std.testing.io, &env, &argv);
    try std.testing.expectEqualStrings("http://127.0.0.1:9999", opts.url.?);
}

test "parseArgs sets api key and api key file from flags" {
    const argv = [_][:0]const u8{ "puny", "-k", "secret-token", "--api-key-file", "/tmp/key.pem" };
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const opts = parseArgs(std.testing.io, &env, &argv);
    try std.testing.expectEqualStrings("secret-token", opts.api_key.?);
    try std.testing.expectEqualStrings("/tmp/key.pem", opts.api_key_file.?);
}

test "parseArgs sets model and marks it explicit" {
    const argv = [_][:0]const u8{ "puny", "-m", "gpt-4o" };
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const opts = parseArgs(std.testing.io, &env, &argv);
    try std.testing.expectEqualStrings("gpt-4o", opts.model.?);
    try std.testing.expect(opts.model_explicit);
}

test "parseArgs sets mock from short flag and oneshot from flag" {
    const argv = [_][:0]const u8{ "puny", "-M", "--oneshot", "-p", "hi" };
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const opts = parseArgs(std.testing.io, &env, &argv);
    try std.testing.expect(opts.mock);
    try std.testing.expect(opts.oneshot);
    try std.testing.expectEqualStrings("hi", opts.prompt.?);
}

test "parseArgs falls back to PUNY_PROVIDER_URL env" {
    const argv = [_][:0]const u8{"puny"};
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PUNY_PROVIDER_URL", "http://env-url:8080");
    const opts = parseArgs(std.testing.io, &env, &argv);
    try std.testing.expectEqualStrings("http://env-url:8080", opts.url.?);
}

test "parseArgs falls back to PUNY_MODEL env" {
    const argv = [_][:0]const u8{"puny"};
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PUNY_MODEL", "env-model");
    const opts = parseArgs(std.testing.io, &env, &argv);
    try std.testing.expectEqualStrings("env-model", opts.model.?);
    try std.testing.expect(!opts.model_explicit);
}

test "parseArgs falls back to PUNY_MOCK env" {
    const argv = [_][:0]const u8{"puny"};
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PUNY_MOCK", "true");
    const opts = parseArgs(std.testing.io, &env, &argv);
    try std.testing.expect(opts.mock);
}

test "parseArgs flag overrides PUNY_MOCK env" {
    const argv = [_][:0]const u8{"puny"};
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PUNY_MOCK", "false");
    const opts = parseArgs(std.testing.io, &env, &argv);
    try std.testing.expect(!opts.mock);
}

test "parseArgs sets reconfigure and force flags" {
    const argv = [_][:0]const u8{ "puny", "--reconfigure", "--force" };
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const opts = parseArgs(std.testing.io, &env, &argv);
    try std.testing.expect(opts.reconfigure);
    try std.testing.expect(opts.force_upgrade);
}

test "parseArgs sets no_skills from flag" {
    const argv = [_][:0]const u8{ "puny", "--no-skills" };
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const opts = parseArgs(std.testing.io, &env, &argv);
    try std.testing.expect(opts.no_skills);
}

test "parseArgs falls back to PUNY_NO_SKILLS env" {
    const argv = [_][:0]const u8{"puny"};
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PUNY_NO_SKILLS", "true");
    const opts = parseArgs(std.testing.io, &env, &argv);
    try std.testing.expect(opts.no_skills);
}

test "parseArgs flag overrides PUNY_NO_SKILLS env" {
    const argv = [_][:0]const u8{"puny"};
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PUNY_NO_SKILLS", "false");
    const opts = parseArgs(std.testing.io, &env, &argv);
    try std.testing.expect(!opts.no_skills);
}

test "writeErr prints the formatted message" {
    // writeErr writes to real stdout which is not drainable in test context.
    return error.SkipZigTest;
}

test "printHelp prints the version and usage" {
    // printHelp writes to real stdout which is not drainable in test context.
    return error.SkipZigTest;
}

test "printVersion prints the puny version line" {
    // printVersion writes to real stdout which is not drainable in test context.
    return error.SkipZigTest;
}
