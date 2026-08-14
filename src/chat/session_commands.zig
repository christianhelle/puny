const std = @import("std");
const ansi = @import("../tui/ansi.zig");
const cli = @import("../cli/args.zig");
const config = @import("../config/config.zig");
const effort_picker = @import("../tui/effort_picker.zig");
const openai = @import("../providers/openai.zig");
const model_selection = @import("../models/select.zig");
const provider = @import("../providers/provider.zig");
const session = @import("session.zig");

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
