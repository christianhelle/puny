const std = @import("std");
const builtin = @import("builtin");
const ansi = @import("../tui/ansi.zig");
const config = @import("../config/config.zig");
const context = @import("context.zig");
const compact = @import("compact.zig");
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

/// `/context [tokens|off]`: shows how full the context is, or changes the
/// limit for the current conversation.
pub fn handleContextCommand(ctx: *ChatLoopContext, argument: ?[]const u8) !void {
    const budget = ctx.context_budget;
    const w = ctx.stdout_writer;
    switch (compact.parseContextArgument(argument)) {
        .show => {
            const used = budget.estimate(ctx.messages.items);
            if (budget.resolveLimit(ctx.prov, ctx.model_key.*)) |limit| {
                const percent = @divFloor(@as(u128, @intCast(@max(used, 0))) * 100, limit);
                try w.print("\nContext: ~{d} of {d} tokens ({d}%); compacts at {d}%.\n", .{ used, limit, percent, compact.threshold_percent });
            } else {
                try w.print("\nContext: ~{d} tokens. No limit is set, so auto compaction is off.\n", .{used});
            }
        },
        .set => |tokens| {
            budget.setExplicit(tokens);
            try w.print("\nContext limit set to {d} tokens for this conversation.\n", .{tokens});
        },
        .off => {
            budget.disable();
            try w.print("\nAuto compaction is off for this conversation.\n", .{});
        },
        .invalid => try w.print("\nUsage: /context [tokens|off]\n", .{}),
    }
    try w.flush();
}

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
            if (!builtin.is_test) {
                var stderr_buffer: [1024]u8 = undefined;
                var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), ctx.io, &stderr_buffer);
                const stderr_writer = &stderr_file_writer.interface;
                stderr_writer.print("Warning: failed to save reasoning effort to config: {s}\n", .{@errorName(err)}) catch {};
                stderr_writer.flush() catch {};
            }
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

    try switchProvider(ctx, picked_provider);
}

fn switchProvider(ctx: *ChatLoopContext, picked_provider: ModelProvider) !void {
    const current_provider = ctx.model_provider.*;
    if (picked_provider == current_provider) {
        try ctx.stdout_writer.print("\nAlready using provider {s}.\n", .{provider.getProviderDisplayName(picked_provider)});
        try ctx.stdout_writer.flush();
        return;
    }

    const new_api_key = try resolver.resolveApiKey(ctx.arena, ctx.io, ctx.parsed, ctx.cfg.*, picked_provider, resolver.apiKeyEnv(ctx.init.environ_map, picked_provider));
    if (resolver.missingRequiredApiKey(ctx.parsed.mock, picked_provider, new_api_key)) {
        try printMissingApiKey(ctx.stdout_writer, picked_provider);
        return;
    }

    ctx.cfg.provider = picked_provider;
    // The startup --url targeted the previous provider, so only the picked
    // provider's configured url (or its default) applies here.
    const new_provider_url = resolver.baseUrlFor(picked_provider, .{}, ctx.cfg.*);

    config.save(ctx.arena, ctx.io, ctx.cfg.*, ctx.init.environ_map) catch |err| {
        // The live provider stays as it was, so the configured one must too.
        ctx.cfg.provider = current_provider;
        return err;
    };

    // Kept alive until the new provider answers, so an unreachable server can
    // hand the session back to it.
    var previous_prov = ctx.prov.*;
    errdefer previous_prov.deinit();
    const previous_url = ctx.provider_url.*;

    ctx.prov.* = resolver.createProvider(ctx.parsed.mock, picked_provider, new_provider_url, new_api_key, ctx.messages_arena.allocator(), ctx.io, ctx.session.id);
    if (ctx.debug_log) |log| debug_log.attachHttpDebugObserver(ctx.prov, log);
    if (!ctx.parsed.mock) try resolver.ensureCopilotAuth(ctx.arena, ctx.io, ctx.init, ctx.cfg, ctx.stdout_writer, ctx.prov);
    ctx.model_provider.* = picked_provider;
    ctx.provider_url.* = new_provider_url;

    const model_skip_validation = ctx.parsed.mock;
    const model_selection_result = model_selection.select(
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
    ) catch |err| {
        if (err != error.ProviderUnreachable) return err;
        restoreProvider(ctx, previous_prov, current_provider, previous_url);
        try printProviderUnreachable(ctx.stdout_writer, picked_provider, new_provider_url, current_provider);
        return;
    };
    previous_prov.deinit();

    if (model_selection_result) |sel| {
        ctx.model_key.* = sel.model_key;
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

/// Puts back the provider a switch replaced, live and in the saved config, so a
/// switch to a server that cannot be reached leaves the session as it was.
fn restoreProvider(
    ctx: *ChatLoopContext,
    previous_prov: provider.Provider,
    previous_provider: ModelProvider,
    previous_url: []const u8,
) void {
    ctx.prov.deinit();
    ctx.prov.* = previous_prov;
    ctx.model_provider.* = previous_provider;
    ctx.provider_url.* = previous_url;
    ctx.cfg.provider = previous_provider;
    // The switch saved this same config moments ago; if that write now fails,
    // the next startup explains the unreachable provider instead.
    config.save(ctx.arena, ctx.io, ctx.cfg.*, ctx.init.environ_map) catch {};
}

fn printProviderUnreachable(
    stdout_writer: *std.Io.Writer,
    unreachable_provider: ModelProvider,
    url: []const u8,
    still_using: ModelProvider,
) !void {
    try stdout_writer.print(
        "\nCould not connect to {s} at {s}. Make sure it is running, then try again.\nStill using {s}.\n",
        .{ provider.getProviderDisplayName(unreachable_provider), url, provider.getProviderDisplayName(still_using) },
    );
    try stdout_writer.flush();
}

fn printMissingApiKey(stdout_writer: *std.Io.Writer, selected_provider: ModelProvider) !void {
    try stdout_writer.print(
        "\nProvider '{s}' requires an API key. Set one with /config or {s}.\n",
        .{ provider.getProviderDisplayName(selected_provider), resolver.apiKeyEnvNames(selected_provider) },
    );
    try stdout_writer.flush();
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

    try commitReconfigure(ctx, old_provider_name);
}

/// Saves a /config change, but keeps the previous provider selected when the
/// newly picked one needs an API key that is not set, so the saved config does
/// not fail at the next startup.
fn commitReconfigure(ctx: *ChatLoopContext, old_provider_name: ModelProvider) !void {
    const candidate = ctx.cfg.provider;
    if (candidate != old_provider_name) {
        const candidate_key = try resolver.resolveApiKey(ctx.arena, ctx.io, ctx.parsed, ctx.cfg.*, candidate, resolver.apiKeyEnv(ctx.init.environ_map, candidate));
        if (resolver.missingRequiredApiKey(ctx.parsed.mock, candidate, candidate_key)) {
            try printMissingApiKey(ctx.stdout_writer, candidate);
            ctx.cfg.provider = old_provider_name;
        }
    }

    try config.save(ctx.arena, ctx.io, ctx.cfg.*, ctx.init.environ_map);
    try applyReconfiguredProvider(ctx, old_provider_name);
}

/// Applies a saved /config change to the running session.
fn applyReconfiguredProvider(ctx: *ChatLoopContext, old_provider_name: ModelProvider) !void {
    const new_provider_name = ctx.cfg.provider;
    const new_provider_url = if (ctx.parsed.mock) "-" else resolver.baseUrlFor(new_provider_name, ctx.parsed, ctx.cfg.*);
    const new_api_key = try resolver.resolveApiKey(ctx.arena, ctx.io, ctx.parsed, ctx.cfg.*, new_provider_name, resolver.apiKeyEnv(ctx.init.environ_map, new_provider_name));
    if (resolver.missingRequiredApiKey(ctx.parsed.mock, new_provider_name, new_api_key)) {
        try printMissingApiKey(ctx.stdout_writer, new_provider_name);
        return;
    }

    if (!ctx.parsed.mock and old_provider_name != new_provider_name) {
        ctx.prov.deinit();
        ctx.prov.* = resolver.createProvider(ctx.parsed.mock, new_provider_name, new_provider_url, new_api_key, ctx.messages_arena.allocator(), ctx.io, ctx.session.id);
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

        const new_url = input.readLineSimple(arena, io, stdout_writer, &line_alloc, &stdin_buffer) catch |err| {
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

    const new_key = input.readLineSimple(arena, io, stdout_writer, &line_alloc, &stdin_buffer) catch |err| {
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
        .review_tool_definitions = undefined,
        .messages = undefined,
        .mode = undefined,
        .review_outcome = undefined,
        .session = undefined,
        .session_stats = undefined,
        .debug_log = null,
        .chat_log = null,
        .skill_registry = undefined,
        .context_budget = undefined,
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

test "switchProvider refuses a key-gated provider without an API key" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var reasoning_effort: ?openai.ReasoningEffort = null;
    var model_provider: ModelProvider = .lmstudio;
    var cfg = config.Config.default();
    var ctx = testChatLoopContext(std.testing.allocator, &out.writer, &reasoning_effort, &model_provider, &cfg);
    ctx.parsed.mock = false;

    // No PUNY_API_KEY and no stored key. Without HOME the config cannot be
    // saved either, so reaching config.save would fail this test.
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

    try switchProvider(&ctx, .opencode_go);

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Provider 'OpenCode Go' requires an API key") != null);
    try std.testing.expectEqual(ModelProvider.lmstudio, model_provider);
    try std.testing.expectEqual(ModelProvider.lmstudio, cfg.provider);
}

test "switchProvider hints at OLLAMA_API_KEY when Ollama Cloud has no key" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var reasoning_effort: ?openai.ReasoningEffort = null;
    var model_provider: ModelProvider = .lmstudio;
    var cfg = config.Config.default();
    var ctx = testChatLoopContext(std.testing.allocator, &out.writer, &reasoning_effort, &model_provider, &cfg);
    ctx.parsed.mock = false;

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

    try switchProvider(&ctx, .ollama_cloud);

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Provider 'Ollama Cloud' requires an API key. Set one with /config or PUNY_API_KEY/OLLAMA_API_KEY.") != null);
    try std.testing.expectEqual(ModelProvider.lmstudio, model_provider);
}

test "switchProvider accepts OLLAMA_API_KEY for Ollama Cloud" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var reasoning_effort: ?openai.ReasoningEffort = null;
    var model_provider: ModelProvider = .lmstudio;
    var cfg = config.Config.default();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testChatLoopContext(arena_state.allocator(), &out.writer, &reasoning_effort, &model_provider, &cfg);
    ctx.parsed.mock = false;

    // The key passes the gate; without a config dir the save then fails,
    // which stops the switch before it builds a client.
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("OLLAMA_API_KEY", "ollama-key");
    ctx.io = std.testing.io;
    ctx.init = .{
        .minimal = undefined,
        .arena = undefined,
        .gpa = undefined,
        .io = undefined,
        .environ_map = &env,
        .preopens = undefined,
    };

    try std.testing.expectError(error.NoConfigDir, switchProvider(&ctx, .ollama_cloud));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "requires an API key") == null);
}

/// A loopback URL nothing listens on, so connecting to it is refused.
fn closedPortUrl(buf: []u8) ![]const u8 {
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = try std.Io.net.IpAddress.listen(&address, std.testing.io, .{});
    const port = server.socket.address.getPort();
    server.deinit(std.testing.io);
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}", .{port});
}

/// Everything a provider switch touches, wired up so the switch can run for
/// real: a live previous provider, a session, and a writable config dir.
const SwitchHarness = struct {
    out: std.Io.Writer.Allocating,
    arena_state: std.heap.ArenaAllocator,
    messages_arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    env: std.process.Environ.Map,
    reasoning_effort: ?openai.ReasoningEffort = null,
    model_provider: ModelProvider = .lmstudio,
    cfg: config.Config,
    prov: provider.Provider,
    provider_url: []const u8 = "http://previous:1234",
    model_key: []const u8 = "previous-model",
    session: @import("../core/session.zig").Session = .{ .id = "test-session", .base = "", .dir = "", .prd_path = "", .html_path = "" },
    random_source: std.Random.IoSource = .{ .io = std.testing.io },

    fn init(self: *SwitchHarness) !void {
        const http_client = @import("../providers/client.zig");
        self.out = .init(std.testing.allocator);
        self.arena_state = .init(std.testing.allocator);
        self.messages_arena = .init(std.testing.allocator);
        self.tmp = std.testing.tmpDir(.{});
        self.env = .init(std.testing.allocator);
        self.cfg = config.Config.default();
        self.reasoning_effort = null;
        self.model_provider = .lmstudio;
        self.provider_url = "http://previous:1234";
        self.model_key = "previous-model";
        self.session = .{ .id = "test-session", .base = "", .dir = "", .prd_path = "", .html_path = "" };
        self.random_source = .{ .io = std.testing.io };

        var previous = http_client.Client.init(self.messages_arena.allocator(), std.testing.io, "");
        previous.withBaseUrl(self.provider_url);
        self.prov = .{ .lmstudio = previous };

        const config_dir = try std.fs.path.join(self.arena_state.allocator(), &.{ ".zig-cache", "tmp", &self.tmp.sub_path });
        try self.env.put("APPDATA", config_dir);
        try self.env.put("XDG_CONFIG_HOME", config_dir);
    }

    fn deinit(self: *SwitchHarness) void {
        self.prov.deinit();
        self.env.deinit();
        self.tmp.cleanup();
        self.messages_arena.deinit();
        self.arena_state.deinit();
        self.out.deinit();
    }

    fn context(self: *SwitchHarness) ChatLoopContext {
        var ctx = testChatLoopContext(self.arena_state.allocator(), &self.out.writer, &self.reasoning_effort, &self.model_provider, &self.cfg);
        ctx.parsed.mock = false;
        ctx.io = std.testing.io;
        ctx.init = .{
            .minimal = undefined,
            .arena = undefined,
            .gpa = undefined,
            .io = undefined,
            .environ_map = &self.env,
            .preopens = undefined,
        };
        ctx.messages_arena = &self.messages_arena;
        ctx.prov = &self.prov;
        ctx.provider_url = &self.provider_url;
        ctx.model_key = &self.model_key;
        ctx.session = &self.session;
        ctx.random = self.random_source.interface();
        return ctx;
    }
};

test "switchProvider explains an unreachable server and keeps the previous provider" {
    var h: SwitchHarness = undefined;
    try h.init();
    defer h.deinit();
    var url_buf: [64]u8 = undefined;
    const ollama_url = try closedPortUrl(&url_buf);
    h.cfg.providerEntry(.ollama).url = ollama_url;
    var ctx = h.context();

    try switchProvider(&ctx, .ollama);

    const expected = try std.fmt.allocPrint(h.arena_state.allocator(), "Could not connect to Ollama at {s}. Make sure it is running, then try again.", .{ollama_url});
    try std.testing.expect(std.mem.indexOf(u8, h.out.written(), expected) != null);
    try std.testing.expect(std.mem.indexOf(u8, h.out.written(), "Still using LM Studio.") != null);

    // The live session and the saved config both stay on the previous provider.
    try std.testing.expectEqual(ModelProvider.lmstudio, h.model_provider);
    try std.testing.expectEqual(ModelProvider.lmstudio, h.cfg.provider);
    try std.testing.expectEqualStrings("http://previous:1234", h.provider_url);
    try std.testing.expectEqualStrings("previous-model", h.model_key);
    try std.testing.expectEqualStrings("http://previous:1234", h.prov.lmstudio.base_url);

    var loaded = try config.load(std.testing.allocator, std.testing.io, &h.env);
    defer loaded.deinit();
    try std.testing.expectEqual(ModelProvider.lmstudio, loaded.config.provider);
}

test "switchProvider keeps the configured url of the provider it switches to" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var reasoning_effort: ?openai.ReasoningEffort = null;
    var model_provider: ModelProvider = .lmstudio;
    var cfg = config.Config.default();
    // Unsloth needs no API key, so the switch proceeds without one.
    cfg.providerEntry(.unsloth).url = "http://gpu-box:8888";
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testChatLoopContext(arena_state.allocator(), &out.writer, &reasoning_effort, &model_provider, &cfg);
    ctx.parsed.mock = false;

    // Without a config dir the save fails, which stops the switch before it
    // builds a client or opens the interactive model picker.
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

    try std.testing.expectError(error.NoConfigDir, switchProvider(&ctx, .unsloth));
    try std.testing.expectEqualStrings("http://gpu-box:8888", cfg.providerEntryConst(.unsloth).url);
    // The live provider did not change, so neither may the configured one.
    try std.testing.expectEqual(ModelProvider.lmstudio, cfg.provider);
    try std.testing.expectEqual(ModelProvider.lmstudio, model_provider);
}

test "applyReconfiguredProvider does not switch to a key-gated provider without a key" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var reasoning_effort: ?openai.ReasoningEffort = null;
    var model_provider: ModelProvider = .lmstudio;
    var cfg = config.Config.default();
    // /config just picked OpenCode Go but the API key prompt was skipped.
    cfg.provider = .opencode_go;
    var ctx = testChatLoopContext(std.testing.allocator, &out.writer, &reasoning_effort, &model_provider, &cfg);
    ctx.parsed.mock = false;

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

    try applyReconfiguredProvider(&ctx, .lmstudio);

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Provider 'OpenCode Go' requires an API key") != null);
    try std.testing.expectEqual(ModelProvider.lmstudio, model_provider);
}

test "commitReconfigure keeps the previous provider when the picked one lacks a required key" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var reasoning_effort: ?openai.ReasoningEffort = null;
    var model_provider: ModelProvider = .lmstudio;
    var cfg = config.Config.default();
    // /config just picked OpenCode Go but the API key prompt was skipped.
    cfg.provider = .opencode_go;
    var ctx = testChatLoopContext(std.testing.allocator, &out.writer, &reasoning_effort, &model_provider, &cfg);
    ctx.parsed.mock = false;

    // Without a config dir the save fails, so the test observes what would
    // have been persisted without writing anything.
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

    try std.testing.expectError(error.NoConfigDir, commitReconfigure(&ctx, .lmstudio));

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Provider 'OpenCode Go' requires an API key") != null);
    try std.testing.expectEqual(ModelProvider.lmstudio, cfg.provider);
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
