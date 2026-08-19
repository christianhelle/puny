const std = @import("std");
const ansi = @import("../tui/ansi.zig");
const config = @import("../config/config.zig");
const context = @import("context.zig");
const debug_log = @import("debug_log.zig");
const effort_picker = @import("../tui/effort_picker.zig");
const input = @import("../tui/input.zig");
const openai = @import("../providers/openai.zig");
const model_selection = @import("../models/select.zig");
const provider = @import("../providers/provider.zig");
const provider_picker = @import("../tui/provider_picker.zig");
const resolver = @import("../providers/resolver.zig");
const sigint = @import("../core/sigint.zig");
const welcome = @import("../tui/welcome.zig");

const ModelProvider = provider.ModelProvider;
const ChatLoopContext = context.ChatLoopContext;

pub fn handleSwitchEffortCommand(ctx: *ChatLoopContext, effort_arg: ?[]const u8) !void {
    const effort = if (effort_arg) |text| blk: {
        const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
        if (effort_picker.parseEffort(trimmed)) |e| {
            break :blk e;
        }
        try ctx.stdout_writer.print("\nUnknown reasoning effort '{s}'. Valid levels: default, none, minimal, low, medium, high, xhigh.\n", .{trimmed});
        try ctx.stdout_writer.flush();
        return;
    } else (try effort_picker.pickEffort(ctx.arena, ctx.io)) orelse {
        try ctx.stdout_writer.print("\n{s}Cancelled.{s}\n", .{ ansi.dim, ansi.reset });
        try ctx.stdout_writer.flush();
        return;
    };

    const current: openai.ReasoningEffort = ctx.reasoning_effort.* orelse .default;
    if (current == effort) {
        if (effort != .default) {
            try ctx.stdout_writer.print("\nAlready using reasoning effort {s}{s}{s}.\n", .{ ansi.bold_start, @tagName(effort), ansi.bold_end });
        } else {
            try ctx.stdout_writer.print("\nAlready using default reasoning effort.\n", .{});
        }
        try ctx.stdout_writer.flush();
        return;
    }

    ctx.reasoning_effort.* = effort;

    if (ctx.model_provider.* != .mock) {
        const effort_str = if (effort != .default) @tagName(effort) else null;
        ctx.cfg.providerEntry(ctx.model_provider.*).reasoning_effort = if (effort_str) |e| try ctx.arena.dupe(u8, e) else null;
        config.save(ctx.arena, ctx.io, ctx.cfg.*, ctx.init.environ_map) catch |err| {
            var stderr_buffer: [1024]u8 = undefined;
            var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), ctx.io, &stderr_buffer);
            const stderr_writer = &stderr_file_writer.interface;
            stderr_writer.print("Warning: failed to save reasoning effort to config: {s}\n", .{@errorName(err)}) catch {};
            stderr_writer.flush() catch {};
        };
    }

    if (effort != .default) {
        try ctx.stdout_writer.print("\nSwitched to reasoning effort {s}{s}{s}.\n", .{ ansi.bold_start, @tagName(effort), ansi.bold_end });
    } else {
        try ctx.stdout_writer.print("\nReasoning effort reset to default.\n", .{});
    }
    try ctx.stdout_writer.flush();
}

pub fn handleSwitchModelCommand(ctx: *ChatLoopContext, model_id: ?[]const u8) !void {
    const model_skip_validation = ctx.parsed.mock;
    if (try model_selection.switchModel(
        ctx.prov,
        model_id,
        ctx.model_key.*,
        ctx.reasoning_effort.*,
        ctx.arena,
        ctx.io,
        ctx.init,
        model_skip_validation,
        ctx.stdout_writer,
        ctx.cfg,
        ctx.model_provider.*,
        ctx.init.environ_map,
        ctx.random,
    )) |result| {
        ctx.model_key.* = result.model_key;
        ctx.context_window = result.context_length;
        if (result.reasoning_effort) |effort| {
            ctx.reasoning_effort.* = effort;
        }
    }
}

pub fn handleSwitchProviderCommand(ctx: *ChatLoopContext, provider_id: ?[]const u8) !void {
    const picked_provider = if (provider_id) |id| {
        try ctx.stdout_writer.print("\nUnknown provider '{s}'.\n", .{id});
        try ctx.stdout_writer.flush();
        return;
    } else blk: {
        const picked = try provider_picker.selectProviderInteractive(ctx.arena, ctx.io, ctx.init) orelse {
            try ctx.stdout_writer.print("\n{s}Cancelled.{s}\n", .{ ansi.dim, ansi.reset });
            try ctx.stdout_writer.flush();
            return;
        };
        break :blk picked;
    };

    const current_provider = ctx.model_provider.*;
    if (picked_provider == current_provider) {
        try ctx.stdout_writer.print("\nAlready using provider {s}.\n", .{provider.getProviderDisplayName(picked_provider)});
        try ctx.stdout_writer.flush();
        return;
    }

    ctx.cfg.provider = picked_provider;
    const new_provider_url = resolver.defaultProviderUrl(picked_provider);
    ctx.cfg.providerEntry(picked_provider).url = try ctx.arena.dupe(u8, new_provider_url);

    try config.save(ctx.arena, ctx.io, ctx.cfg.*, ctx.init.environ_map);

    const new_api_key = try resolver.resolveApiKey(ctx.arena, ctx.io, ctx.parsed, ctx.cfg.*, picked_provider, ctx.init.environ_map.get("PUNY_API_KEY"));
    ctx.prov.deinit();
    ctx.prov.* = resolver.createProvider(ctx.parsed.mock, picked_provider, new_provider_url, new_api_key, ctx.messages_arena.allocator(), ctx.io);
    if (ctx.debug_log) |log| debug_log.attachHttpDebugObserver(ctx.prov, log);
    if (!ctx.parsed.mock) try resolver.ensureCopilotAuth(ctx.arena, ctx.io, ctx.init, ctx.cfg, ctx.stdout_writer, ctx.prov);
    ctx.model_provider.* = picked_provider;
    ctx.provider_url.* = new_provider_url;

    const model_skip_validation = ctx.parsed.mock;
    const model_selection_result = try model_selection.select(
        ctx.prov,
        null,
        ctx.arena,
        ctx.io,
        ctx.init,
        model_skip_validation,
        ctx.cfg,
        picked_provider,
        ctx.init.environ_map,
        ctx.random,
    );

    if (model_selection_result) |sel| {
        ctx.model_key.* = sel.model_key;
        ctx.context_window = sel.context_length;
        if (sel.reasoning_effort) |effort| {
            ctx.reasoning_effort.* = effort;
        }
    }

    try welcome.printSummary(
        ctx.stdout_writer,
        .{
            .provider_name = if (ctx.parsed.mock) "Mock" else provider.getProviderDisplayName(ctx.model_provider.*),
            .provider_url = ctx.provider_url.*,
            .model_key = ctx.model_key.*,
            .reasoning_effort = ctx.reasoning_effort.*,
        },
    );

    try ctx.stdout_writer.print("Switched to provider {s}.\n", .{provider.getProviderDisplayName(picked_provider)});
    try ctx.stdout_writer.flush();
}

pub fn handleReconfigureCommand(ctx: *ChatLoopContext) !void {
    if (ctx.parsed.oneshot) {
        try ctx.stdout_writer.print("\n/config not available in oneshot mode.\n", .{});
        try ctx.stdout_writer.flush();
        return;
    }

    const old_provider_name = ctx.cfg.provider;
    const result = try promptReconfigure(ctx.arena, ctx.io, ctx.init, ctx.stdout_writer, ctx.cfg);
    if (result.cancelled) return;
    if (!result.changed) return;

    try config.save(ctx.arena, ctx.io, ctx.cfg.*, ctx.init.environ_map);
    const new_provider_name = ctx.cfg.provider;
    const new_provider_url = if (ctx.parsed.mock) "-" else resolver.baseUrlFor(new_provider_name, ctx.parsed, ctx.cfg.*);
    const new_api_key = try resolver.resolveApiKey(ctx.arena, ctx.io, ctx.parsed, ctx.cfg.*, new_provider_name, ctx.init.environ_map.get("PUNY_API_KEY"));

    if (!ctx.parsed.mock and old_provider_name != new_provider_name) {
        ctx.prov.deinit();
        ctx.prov.* = resolver.createProvider(ctx.parsed.mock, new_provider_name, new_provider_url, new_api_key, ctx.messages_arena.allocator(), ctx.io);
        if (ctx.debug_log) |log| debug_log.attachHttpDebugObserver(ctx.prov, log);
        if (!ctx.parsed.mock) try resolver.ensureCopilotAuth(ctx.arena, ctx.io, ctx.init, ctx.cfg, ctx.stdout_writer, ctx.prov);
        ctx.model_provider.* = new_provider_name;
        ctx.provider_url.* = new_provider_url;

        const model_skip_validation =
            ctx.parsed.mock or
            ctx.parsed.oneshot or
            !std.mem.eql(u8, new_provider_url, config.default_lm_studio_url);

        const model_selection_result = try model_selection.select(
            ctx.prov,
            null,
            ctx.arena,
            ctx.io,
            ctx.init,
            model_skip_validation,
            ctx.cfg,
            new_provider_name,
            ctx.init.environ_map,
            ctx.random,
        );

        if (model_selection_result) |sel| {
            ctx.model_key.* = sel.model_key;
            ctx.context_window = sel.context_length;
            if (sel.reasoning_effort) |effort| {
                ctx.reasoning_effort.* = effort;
            }
        }
    } else {
        ctx.prov.setConfig(.{ .base_url = new_provider_url, .api_key = new_api_key });
        ctx.provider_url.* = new_provider_url;
        if (!ctx.parsed.mock) try resolver.ensureCopilotAuth(ctx.arena, ctx.io, ctx.init, ctx.cfg, ctx.stdout_writer, ctx.prov);
    }

    try welcome.printSummary(
        ctx.stdout_writer,
        .{
            .provider_name = if (ctx.parsed.mock) "Mock" else provider.getProviderDisplayName(ctx.model_provider.*),
            .provider_url = ctx.provider_url.*,
            .model_key = ctx.model_key.*,
            .reasoning_effort = ctx.reasoning_effort.*,
        },
    );

    try ctx.stdout_writer.print("Configuration saved and provider updated.\n", .{});
    try ctx.stdout_writer.flush();
}

pub const ReconfigurePrompt = struct {
    changed: bool = false,
    cancelled: bool = false,
};

pub fn promptReconfigure(
    arena: std.mem.Allocator,
    io: std.Io,
    init: std.process.Init,
    stdout_writer: *std.Io.Writer,
    cfg: *config.Config,
) !ReconfigurePrompt {
    var line_alloc: std.Io.Writer.Allocating = .init(arena);
    defer line_alloc.deinit();
    var stdin_buffer: [4096]u8 = undefined;

    var result = ReconfigurePrompt{};

    try stdout_writer.print("Current provider: {s}\n", .{@tagName(cfg.provider)});
    try stdout_writer.flush();

    const picked_provider = try provider_picker.selectProviderInteractive(arena, io, init) orelse {
        try stdout_writer.print("\n{s}Cancelled.{s}\n", .{ ansi.dim, ansi.reset });
        try stdout_writer.flush();
        return .{ .cancelled = true };
    };

    var provider_name = cfg.provider;
    var provider_changed = false;
    if (picked_provider != cfg.provider) {
        cfg.provider = picked_provider;
        provider_name = cfg.provider;
        provider_changed = true;
        result.changed = true;
    }

    const entry = cfg.providerEntry(provider_name);
    const provider_url_is_fixed = resolver.providerHasFixedUrl(provider_name);
    if (provider_url_is_fixed) {
        const fixed_url = resolver.defaultProviderUrl(provider_name);
        entry.url = try arena.dupe(u8, fixed_url);
        result.changed = true;
        try stdout_writer.print("Provider URL is fixed at {s}\n", .{fixed_url});
        try stdout_writer.flush();
    } else {
        line_alloc.clearRetainingCapacity();
        try stdout_writer.print("Current provider URL: {s}\n", .{entry.url});
        try stdout_writer.print(
            "Enter new provider URL (default: {s}; press Enter for default): ",
            .{resolver.defaultProviderUrl(provider_name)},
        );
        try stdout_writer.flush();

        const new_url = input.readLineSimple(io, &line_alloc, &stdin_buffer) catch |err| {
            if (sigint.isTriggered()) return .{ .cancelled = true };
            return err;
        } orelse {
            try stdout_writer.print("\n{s}Cancelled.{s}\n", .{ ansi.dim, ansi.reset });
            try stdout_writer.flush();
            return .{ .cancelled = true };
        };

        const default_url = resolver.defaultProviderUrl(provider_name);
        if (new_url.len > 0) {
            entry.url = try arena.dupe(u8, new_url);
            result.changed = true;
        } else if (provider_changed) {
            entry.url = try arena.dupe(u8, default_url);
            result.changed = true;
        }
    }

    line_alloc.clearRetainingCapacity();
    const key_status = if (entry.apiKey) |_| "set" else "none";
    try stdout_writer.print("Current API key: ({s})\n", .{key_status});
    try stdout_writer.print("Enter new API key (press Enter to keep, '-' to clear): ", .{});
    try stdout_writer.flush();

    const new_key = input.readLineSimple(io, &line_alloc, &stdin_buffer) catch |err| {
        if (sigint.isTriggered()) return .{ .cancelled = true };
        return err;
    } orelse {
        try stdout_writer.print("\n{s}Cancelled.{s}\n", .{ ansi.dim, ansi.reset });
        try stdout_writer.flush();
        return .{ .cancelled = true };
    };

    if (std.mem.eql(u8, new_key, "-")) {
        entry.apiKey = null;
        entry.stored_blob = null;
        result.changed = true;
    } else if (new_key.len > 0) {
        entry.apiKey = try arena.dupe(u8, new_key);
        entry.stored_blob = null;
        result.changed = true;
    }

    return result;
}

fn testChatLoopContext(
    allocator: std.mem.Allocator,
    stdout_writer: *std.Io.Writer,
    reasoning_effort: *?openai.ReasoningEffort,
    model_provider: *ModelProvider,
    cfg: *config.Config,
) ChatLoopContext {
    const cli = @import("../cli/args.zig");
    return .{
        .arena = allocator,
        .messages_arena = undefined,
        .io = undefined,
        .init = undefined,
        .parsed = cli.Options{ .mock = true },
        .cfg = cfg,
        .stdout_writer = stdout_writer,
        .random = undefined,
        .history = undefined,
        .prov = undefined,
        .model_provider = model_provider,
        .provider_url = undefined,
        .model_key = undefined,
        .reasoning_effort = reasoning_effort,
        .full_tool_definitions = undefined,
        .planning_tool_definitions = undefined,
        .messages = undefined,
        .planning_mode = undefined,
        .session = undefined,
        .session_stats = undefined,
        .debug_log = null,
        .chat_log = null,
        .skill_registry = undefined,
    };
}

test "handleSwitchEffortCommand switches to the requested effort" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var reasoning_effort: ?openai.ReasoningEffort = null;
    var model_provider: ModelProvider = .mock;
    var cfg = config.Config.default();
    var ctx = testChatLoopContext(std.testing.allocator, &out.writer, &reasoning_effort, &model_provider, &cfg);

    try handleSwitchEffortCommand(&ctx, "high");

    try std.testing.expectEqual(@as(?openai.ReasoningEffort, .high), reasoning_effort);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Switched to reasoning effort") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "high") != null);
}

test "handleSwitchEffortCommand trims whitespace around the effort level" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var reasoning_effort: ?openai.ReasoningEffort = null;
    var model_provider: ModelProvider = .mock;
    var cfg = config.Config.default();
    var ctx = testChatLoopContext(std.testing.allocator, &out.writer, &reasoning_effort, &model_provider, &cfg);

    try handleSwitchEffortCommand(&ctx, "  medium  ");

    try std.testing.expectEqual(@as(?openai.ReasoningEffort, .medium), reasoning_effort);
}

test "handleSwitchEffortCommand resets to default" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var reasoning_effort: ?openai.ReasoningEffort = .high;
    var model_provider: ModelProvider = .mock;
    var cfg = config.Config.default();
    var ctx = testChatLoopContext(std.testing.allocator, &out.writer, &reasoning_effort, &model_provider, &cfg);

    try handleSwitchEffortCommand(&ctx, "default");

    try std.testing.expectEqual(@as(?openai.ReasoningEffort, .default), reasoning_effort);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Reasoning effort reset to default") != null);
}

test "handleSwitchEffortCommand reports already using the same effort" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var reasoning_effort: ?openai.ReasoningEffort = .high;
    var model_provider: ModelProvider = .mock;
    var cfg = config.Config.default();
    var ctx = testChatLoopContext(std.testing.allocator, &out.writer, &reasoning_effort, &model_provider, &cfg);

    try handleSwitchEffortCommand(&ctx, "high");

    try std.testing.expectEqual(@as(?openai.ReasoningEffort, .high), reasoning_effort);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Already using reasoning effort") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "high") != null);
}

test "handleSwitchEffortCommand rejects unknown effort levels" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var reasoning_effort: ?openai.ReasoningEffort = null;
    var model_provider: ModelProvider = .mock;
    var cfg = config.Config.default();
    var ctx = testChatLoopContext(std.testing.allocator, &out.writer, &reasoning_effort, &model_provider, &cfg);

    try handleSwitchEffortCommand(&ctx, "ultra");

    try std.testing.expectEqual(@as(?openai.ReasoningEffort, null), reasoning_effort);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Unknown reasoning effort") != null);
}

test "handleSwitchEffortCommand rejects whitespace-only arguments" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var reasoning_effort: ?openai.ReasoningEffort = null;
    var model_provider: ModelProvider = .mock;
    var cfg = config.Config.default();
    var ctx = testChatLoopContext(std.testing.allocator, &out.writer, &reasoning_effort, &model_provider, &cfg);

    try handleSwitchEffortCommand(&ctx, "   ");

    try std.testing.expectEqual(@as(?openai.ReasoningEffort, null), reasoning_effort);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Unknown reasoning effort ''") != null);
}

test "handleSwitchEffortCommand reports already using the default effort" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var reasoning_effort: ?openai.ReasoningEffort = .default;
    var model_provider: ModelProvider = .mock;
    var cfg = config.Config.default();
    var ctx = testChatLoopContext(std.testing.allocator, &out.writer, &reasoning_effort, &model_provider, &cfg);

    try handleSwitchEffortCommand(&ctx, "default");

    try std.testing.expectEqual(@as(?openai.ReasoningEffort, .default), reasoning_effort);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Already using default reasoning effort") != null);
}

test "handleSwitchProviderCommand rejects unknown provider ids" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var reasoning_effort: ?openai.ReasoningEffort = null;
    var model_provider: ModelProvider = .mock;
    var cfg = config.Config.default();
    var ctx = testChatLoopContext(std.testing.allocator, &out.writer, &reasoning_effort, &model_provider, &cfg);

    try handleSwitchProviderCommand(&ctx, "does-not-exist");

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Unknown provider 'does-not-exist'") != null);
    try std.testing.expectEqual(ModelProvider.mock, model_provider);
}

test "handleSwitchEffortCommand warns on stderr when the config cannot be saved" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var reasoning_effort: ?openai.ReasoningEffort = null;
    // A non-mock provider is required to reach the config.save call.
    var model_provider: ModelProvider = .lmstudio;
    var cfg = config.Config.default();
    // The switch path dupes the effort level into the config, so back the
    // context with an arena instead of the leaking debug allocator.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testChatLoopContext(arena_state.allocator(), &out.writer, &reasoning_effort, &model_provider, &cfg);

    // Without HOME or XDG_CONFIG_HOME the config path cannot be resolved, so
    // config.save fails and the warning path runs. A real io handle is
    // required: the warning path builds a stderr writer from ctx.io.
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    ctx.io = std.testing.io;
    ctx.init = .{
        .minimal = undefined,
        .arena = undefined,
        .gpa = undefined,
        .io = undefined,
        .environ_map = &env,
        .preopens = undefined,
    };

    try handleSwitchEffortCommand(&ctx, "high");

    try std.testing.expectEqual(@as(?openai.ReasoningEffort, .high), reasoning_effort);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Switched to reasoning effort") != null);
}

test "handleReconfigureCommand refuses oneshot mode" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var reasoning_effort: ?openai.ReasoningEffort = null;
    var model_provider: ModelProvider = .mock;
    var cfg = config.Config.default();
    var ctx = testChatLoopContext(std.testing.allocator, &out.writer, &reasoning_effort, &model_provider, &cfg);
    ctx.parsed.oneshot = true;

    try handleReconfigureCommand(&ctx);

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "/config not available in oneshot mode.") != null);
}
