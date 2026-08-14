const std = @import("std");
const ansi = @import("../tui/ansi.zig");
const cli = @import("../cli/args.zig");
const config = @import("../config/config.zig");
const effort_picker = @import("../tui/effort_picker.zig");
const openai = @import("../providers/openai.zig");
const model_selection = @import("../models/select.zig");
const provider = @import("../providers/provider.zig");
const provider_picker = @import("../tui/provider_picker.zig");
const resolver = @import("../providers/resolver.zig");
const session = @import("session.zig");
const welcome = @import("../tui/welcome.zig");

const ModelProvider = provider.ModelProvider;
const ChatLoopContext = session.ChatLoopContext;

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
    if (ctx.debug_log) |log| session.attachHttpDebugObserver(ctx.prov, log);
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
    const result = try session.promptReconfigure(ctx.arena, ctx.io, ctx.init, ctx.stdout_writer, ctx.cfg);
    if (result.cancelled) return;
    if (!result.changed) return;

    try config.save(ctx.arena, ctx.io, ctx.cfg.*, ctx.init.environ_map);
    const new_provider_name = ctx.cfg.provider;
    const new_provider_url = if (ctx.parsed.mock) "-" else resolver.baseUrlFor(new_provider_name, ctx.parsed, ctx.cfg.*);
    const new_api_key = try resolver.resolveApiKey(ctx.arena, ctx.io, ctx.parsed, ctx.cfg.*, new_provider_name, ctx.init.environ_map.get("PUNY_API_KEY"));

    if (!ctx.parsed.mock and old_provider_name != new_provider_name) {
        ctx.prov.deinit();
        ctx.prov.* = resolver.createProvider(ctx.parsed.mock, new_provider_name, new_provider_url, new_api_key, ctx.messages_arena.allocator(), ctx.io);
        if (ctx.debug_log) |log| session.attachHttpDebugObserver(ctx.prov, log);
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

fn testChatLoopContext(
    allocator: std.mem.Allocator,
    stdout_writer: *std.Io.Writer,
    reasoning_effort: *?openai.ReasoningEffort,
    model_provider: *ModelProvider,
    cfg: *config.Config,
) ChatLoopContext {
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
