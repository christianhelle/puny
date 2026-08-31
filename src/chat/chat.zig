const std = @import("std");
const ansi = @import("../tui/ansi.zig");
const chat_retry = @import("retry.zig");
const stats = @import("stats.zig");
const indicator = @import("../tui/indicator.zig");
const openai = @import("../providers/openai.zig");
const provider = @import("../providers/provider.zig");
const tools = @import("../tools/root.zig");
const tool_display = @import("display.zig");
const usage_estimator = @import("usage.zig");
const accumulator = @import("accumulator.zig");
const AgentMode = @import("../core/mode.zig").AgentMode;

pub const OpenAiAccumulator = accumulator.OpenAiAccumulator;

pub const TurnResult = struct {
    turn_complete: bool,
    usage: ?openai.TurnUsage,
    usage_estimated: bool = false,
    was_cancelled: bool = false,
    had_error: bool = false,
};

pub fn runTurn(
    prov: *provider.Provider,
    arena: std.mem.Allocator,
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    session_stats: *stats.SessionStats,
    show_thinking: bool,
    random: std.Random,
    model_key: []const u8,
    reasoning_effort: ?openai.ReasoningEffort,
    messages: *std.ArrayList(openai.Message),
    tool_definitions: []const openai.ToolDefinition,
    indicator_opt: ?*indicator.ThinkingIndicator,
    chat_log: ?*std.Io.Writer,
) !TurnResult {
    return runTurnWithMode(
        prov,
        arena,
        io,
        stdout_writer,
        session_stats,
        show_thinking,
        random,
        model_key,
        reasoning_effort,
        messages,
        tool_definitions,
        indicator_opt,
        chat_log,
        .build,
    );
}

pub fn runTurnWithMode(
    prov: *provider.Provider,
    arena: std.mem.Allocator,
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    session_stats: *stats.SessionStats,
    show_thinking: bool,
    random: std.Random,
    model_key: []const u8,
    reasoning_effort: ?openai.ReasoningEffort,
    messages: *std.ArrayList(openai.Message),
    tool_definitions: []const openai.ToolDefinition,
    indicator_opt: ?*indicator.ThinkingIndicator,
    chat_log: ?*std.Io.Writer,
    mode: AgentMode,
) !TurnResult {
    const effective_effort = if (reasoning_effort) |e| e else if (show_thinking or chat_log != null) openai.ReasoningEffort.high else null;
    const request = openai.ChatRequest{
        .model = model_key,
        .messages = messages.items,
        .tools = tool_definitions,
        .stream = true,
        .reasoning_effort = effective_effort,
    };

    const input_estimate = usage_estimator.estimateUsage(request.messages, 0).input_tokens;
    session_stats.beginTurn(model_key, input_estimate);

    var acc = OpenAiAccumulator.init(arena, io, stdout_writer, session_stats);
    acc.show_thinking = show_thinking;
    defer acc.deinit();
    // Record partial tokens even when an error interrupts the turn mid-stream.
    errdefer session_stats.finalizeTurn(acc.usage, false);
    const callback = acc.streamCallback();

    const outcome = try chat_retry.runChatWithRetry(prov, arena, request, callback, io, random, stdout_writer);

    const provider_ttft = if (acc.usage) |u| u.time_to_first_token_seconds else null;
    const has_streamed_content = acc.has_streamed_output or acc.hasToolCalls();
    const indicator_offset = 0;

    switch (outcome) {
        .success => {},
        .cancelled => {
            _ = try acc.finishStream();
            if (indicator_opt) |i| try i.finish(io, stdout_writer, indicator_offset, false, has_streamed_content, .cancelled, provider_ttft);
            return .{ .turn_complete = true, .usage = acc.usage, .usage_estimated = acc.usage == null, .was_cancelled = true };
        },
        .failed => {
            _ = try acc.finishStream();
            if (indicator_opt) |i| try i.finish(io, stdout_writer, indicator_offset, false, has_streamed_content, .error_, provider_ttft);
            return .{ .turn_complete = true, .usage = acc.usage, .usage_estimated = acc.usage == null, .had_error = true };
        },
    }

    const turn_usage_estimated = acc.usage == null;
    const turn_usage = if (acc.usage) |u| u else usage_estimator.estimateUsage(messages.items, acc.estimatedOutputChars());

    const has_content = acc.content.items.len > 0;
    const has_streamed_content_after = acc.has_streamed_output or acc.hasToolCalls() or has_content;

    var content_cursor_offset: usize = 0;
    var content_ends_with_newline = false;
    var final_lines_printed: usize = 0;
    if (has_content) {
        final_lines_printed = try acc.finishStream();
        content_cursor_offset = final_lines_printed;
        content_ends_with_newline = true;
    }

    if (acc.hasToolCalls()) {
        const assistant_content = try acc.cloneAssistantContent(arena) orelse return .{ .turn_complete = true, .usage = turn_usage, .usage_estimated = turn_usage_estimated };
        try messages.append(arena, .{ .assistant = assistant_content });

        if (chat_log) |log| {
            if (acc.reasoning.items.len > 0) {
                log.print("[REASONING]\n{s}\n\n", .{acc.reasoning.items}) catch {};
            }
            if (assistant_content.content) |c| {
                log.print("[ASSISTANT]\n{s}\n\n", .{c}) catch {};
            }
        }

        var tool_output_lines: usize = 0;
        for (assistant_content.tool_calls.?) |tc| {
            try printToolCall(arena, stdout_writer, tc);
            try stdout_writer.flush();
            tool_output_lines += 1;
            const result = try executeTool(arena, io, tc, mode);
            try messages.append(arena, .{ .tool = .{ .tool_call_id = tc.id, .content = result } });
            if (chat_log) |log| {
                log.print("[TOOL_CALL]\n{s}\n{s}\n\n", .{ tc.function.name, tc.function.arguments }) catch {};
                log.print("[TOOL_RESULT]\n{s}\n\n", .{result}) catch {};
            }
        }

        const cursor_offset = content_cursor_offset + tool_output_lines;
        if (indicator_opt) |i| try i.finish(io, stdout_writer, cursor_offset, false, has_streamed_content_after, .done, provider_ttft);
        return .{ .turn_complete = false, .usage = turn_usage, .usage_estimated = turn_usage_estimated };
    }

    if (indicator_opt) |i| try i.finish(io, stdout_writer, content_cursor_offset, content_ends_with_newline, has_streamed_content_after, .done, provider_ttft);

    if (chat_log) |log| {
        if (acc.reasoning.items.len > 0) {
            log.print("[REASONING]\n{s}\n\n", .{acc.reasoning.items}) catch {};
        }
    }
    if (has_content) {
        if (chat_log) |log| {
            log.print("[ASSISTANT]\n{s}\n\n", .{acc.content.items}) catch {};
        }
        const content = try tools.dupeString(arena, acc.content.items);
        try messages.append(arena, .{ .assistant = .{ .content = content } });
    }

    return .{ .turn_complete = true, .usage = turn_usage, .usage_estimated = turn_usage_estimated };
}

fn printToolCall(
    arena: std.mem.Allocator,
    stdout_writer: *std.Io.Writer,
    tool_call: openai.ToolCall,
) !void {
    const rendered_tool_call = try tool_display.renderToolCall(arena, tool_call);
    try stdout_writer.print("\n{s}🔧 {s}{s}", .{ ansi.dim, rendered_tool_call, ansi.reset });
}

fn executeTool(arena: std.mem.Allocator, io: std.Io, tool_call: openai.ToolCall, mode: AgentMode) ![]const u8 {
    const tool = tools.dispatchForMode(tool_call.function.name, mode) orelse {
        return std.fmt.allocPrint(arena, "Unknown tool: {s}", .{tool_call.function.name});
    };

    var parsed = try std.json.parseFromSlice(std.json.Value, arena, tool_call.function.arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    return tool.execute(arena, io, parsed.value) catch |err| {
        return std.fmt.allocPrint(arena, "Tool {s} failed: {}", .{ tool_call.function.name, err });
    };
}

test "prints human-friendly tool call output" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try printToolCall(
        arena_state.allocator(),
        &output.writer,
        .{
            .id = "call_1",
            .function = .{
                .name = "read_file",
                .arguments = "{\"path\":\"src/main.zig\"}",
            },
        },
    );

    try std.testing.expectEqualStrings(
        "\n\x1b[2m🔧 Reading \"src/main.zig\"\x1b[0m",
        output.written(),
    );
}

test "executeTool reports unknown tools" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const result = try executeTool(
        arena_state.allocator(),
        std.testing.io,
        .{ .id = "call_1", .function = .{ .name = "definitely_not_a_tool", .arguments = "{}" } },
        .build,
    );
    try std.testing.expectEqualStrings("Unknown tool: definitely_not_a_tool", result);
}

test "executeTool reports failures for a missing file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const result = try executeTool(
        arena_state.allocator(),
        std.testing.io,
        .{ .id = "call_1", .function = .{ .name = "read_file", .arguments = "{\"path\":\"puny-test-chat-missing.txt\"}" } },
        .build,
    );
    try std.testing.expectEqualStrings("Tool read_file failed: error.FileNotFound", result);
}

test "executeTool runs read_file on a real file" {
    const helpers = @import("../tools/helpers.zig");
    const path = "puny-test-chat-read.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    try helpers.writeFile(std.testing.io, path, "hello chat");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const result = try executeTool(
        arena_state.allocator(),
        std.testing.io,
        .{ .id = "call_1", .function = .{ .name = "read_file", .arguments = "{\"path\":\"puny-test-chat-read.txt\"}" } },
        .build,
    );
    try std.testing.expectEqualStrings("hello chat", result);
}

test "executeTool runs write_file on a real file" {
    const path = "puny-test-chat-write.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const result = try executeTool(
        arena_state.allocator(),
        std.testing.io,
        .{ .id = "call_1", .function = .{ .name = "write_file", .arguments = "{\"path\":\"puny-test-chat-write.txt\",\"content\":\"written\"}" } },
        .build,
    );
    try std.testing.expectEqualStrings("File written successfully.", result);
}

test "executeTool enforces mode allowlist" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const write_in_review = try executeTool(
        arena_state.allocator(),
        std.testing.io,
        .{ .id = "call_1", .function = .{ .name = "write_file", .arguments = "{\"path\":\"x\",\"content\":\"y\"}" } },
        .review,
    );
    try std.testing.expectEqualStrings("Unknown tool: write_file", write_in_review);

    const prd_in_review = try executeTool(
        arena_state.allocator(),
        std.testing.io,
        .{ .id = "call_1", .function = .{ .name = "save_prd", .arguments = "{\"markdown\":\"m\",\"html\":\"h\"}" } },
        .review,
    );
    try std.testing.expectEqualStrings("Unknown tool: save_prd", prd_in_review);

    const prd_in_build = try executeTool(
        arena_state.allocator(),
        std.testing.io,
        .{ .id = "call_1", .function = .{ .name = "save_prd", .arguments = "{\"markdown\":\"m\",\"html\":\"h\"}" } },
        .build,
    );
    try std.testing.expectEqualStrings("Unknown tool: save_prd", prd_in_build);

    const review_tool_in_build = try executeTool(
        arena_state.allocator(),
        std.testing.io,
        .{ .id = "call_1", .function = .{ .name = "save_review_results", .arguments = "{\"analysis_markdown\":\"## Change Summary\\nA\\n\\n## Quality and Regression Assessment\\nB\\n\\n## Validation Performed\\nC\\n\\n## Findings\\nD\",\"conclusion\":\"ok\",\"evidence_complete\":true,\"merge_worthy\":true}" } },
        .build,
    );
    try std.testing.expectEqualStrings("Unknown tool: save_review_results", review_tool_in_build);

    const read_in_review = try executeTool(
        arena_state.allocator(),
        std.testing.io,
        .{ .id = "call_1", .function = .{ .name = "read_file", .arguments = "{\"path\":\"puny-test-chat-missing.txt\"}" } },
        .review,
    );
    try std.testing.expect(std.mem.indexOf(u8, read_in_review, "Tool read_file failed") != null);

    const shell_in_planning = try executeTool(
        arena_state.allocator(),
        std.testing.io,
        .{ .id = "call_1", .function = .{ .name = "execute_shell", .arguments = "{\"command\":\"echo hi\"}" } },
        .planning,
    );
    try std.testing.expectEqualStrings("Unknown tool: execute_shell", shell_in_planning);
}

test "runTurn completes a content turn against the mock provider" {
    const mock = @import("../providers/mock.zig");
    var prov = provider.Provider{ .mock = mock.MockClient.init(std.testing.allocator, std.testing.io) };
    defer prov.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    var session_stats = stats.SessionStats.init(std.testing.allocator, std.testing.io);
    defer session_stats.deinit();

    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();

    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(arena);
    try messages.append(arena, .{ .user = "say fast" });

    const result = try runTurn(&prov, arena, std.testing.io, &output.writer, &session_stats, false, random, "mock-model", null, &messages, &.{}, null, null);

    try std.testing.expect(result.turn_complete);
    try std.testing.expect(result.usage_estimated);
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    switch (messages.items[1]) {
        .assistant => |a| try std.testing.expect(a.content != null),
        else => return error.ExpectedAssistant,
    }
}

test "runTurn reports provider usage without estimating" {
    const mock = @import("../providers/mock.zig");
    var prov = provider.Provider{ .mock = mock.MockClient.init(std.testing.allocator, std.testing.io) };
    defer prov.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    var session_stats = stats.SessionStats.init(std.testing.allocator, std.testing.io);
    defer session_stats.deinit();

    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();

    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(arena);
    try messages.append(arena, .{ .user = "usage stats" });

    const result = try runTurn(&prov, arena, std.testing.io, &output.writer, &session_stats, false, random, "mock-model", null, &messages, &.{}, null, null);

    try std.testing.expect(result.turn_complete);
    try std.testing.expect(!result.usage_estimated);
    try std.testing.expectEqual(@as(i64, 156), result.usage.?.output_tokens);
    try std.testing.expectEqual(@as(i64, 24), result.usage.?.input_tokens);
}

test "runTurn executes tool calls and appends tool results" {
    const mock = @import("../providers/mock.zig");
    var prov = provider.Provider{ .mock = mock.MockClient.init(std.testing.allocator, std.testing.io) };
    defer prov.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    var session_stats = stats.SessionStats.init(std.testing.allocator, std.testing.io);
    defer session_stats.deinit();

    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();

    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(arena);
    try messages.append(arena, .{ .user = "read the file" });

    const result = try runTurn(&prov, arena, std.testing.io, &output.writer, &session_stats, false, random, "mock-model", null, &messages, &.{}, null, null);

    try std.testing.expect(!result.turn_complete);
    try std.testing.expectEqual(@as(usize, 12), messages.items.len);
    switch (messages.items[1]) {
        .assistant => |a| try std.testing.expectEqual(@as(usize, 10), a.tool_calls.?.len),
        else => return error.ExpectedAssistant,
    }
    switch (messages.items[2]) {
        .tool => |t| try std.testing.expect(std.mem.indexOf(u8, t.content, "read_file failed") != null),
        else => return error.ExpectedToolResult,
    }
}

test "runTurn reports a failed turn for a non-transient error" {
    const mock = @import("../providers/mock.zig");
    var prov = provider.Provider{ .mock = mock.MockClient.init(std.testing.allocator, std.testing.io) };
    defer prov.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    var session_stats = stats.SessionStats.init(std.testing.allocator, std.testing.io);
    defer session_stats.deinit();

    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();

    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(arena);
    try messages.append(arena, .{ .user = "trigger error please" });

    const result = try runTurn(&prov, arena, std.testing.io, &output.writer, &session_stats, false, random, "mock-model", null, &messages, &.{}, null, null);

    try std.testing.expect(result.turn_complete);
    try std.testing.expect(result.had_error);
    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Chat failed:") != null);
}

test "runTurn reports a cancelled turn" {
    const cancel = @import("../core/cancel.zig");
    cancel.reset();
    defer cancel.reset();
    const mock = @import("../providers/mock.zig");
    var prov = provider.Provider{ .mock = mock.MockClient.init(std.testing.allocator, std.testing.io) };
    defer prov.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    var session_stats = stats.SessionStats.init(std.testing.allocator, std.testing.io);
    defer session_stats.deinit();

    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();

    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(arena);
    try messages.append(arena, .{ .user = "slow" });

    const cancel_thread = try std.Thread.spawn(.{}, struct {
        fn run() void {
            std.Io.sleep(std.testing.io, .{ .nanoseconds = 25 * std.time.ns_per_ms }, .awake) catch {};
            cancel.setCancelled();
        }
    }.run, .{});
    defer cancel_thread.join();

    const result = try runTurn(&prov, arena, std.testing.io, &output.writer, &session_stats, false, random, "mock-model", null, &messages, &.{}, null, null);

    try std.testing.expect(result.turn_complete);
    try std.testing.expect(result.was_cancelled);
    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
}

test "runTurn records assistant output in the chat log" {
    const mock = @import("../providers/mock.zig");
    var prov = provider.Provider{ .mock = mock.MockClient.init(std.testing.allocator, std.testing.io) };
    defer prov.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var chat_log = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer chat_log.deinit();

    var session_stats = stats.SessionStats.init(std.testing.allocator, std.testing.io);
    defer session_stats.deinit();

    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();

    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(arena);
    try messages.append(arena, .{ .user = "say fast" });

    const result = try runTurn(&prov, arena, std.testing.io, &output.writer, &session_stats, false, random, "mock-model", null, &messages, &.{}, null, &chat_log.writer);

    try std.testing.expect(result.turn_complete);
    const logged = chat_log.written();
    try std.testing.expect(std.mem.indexOf(u8, logged, "[ASSISTANT]") != null);
    try std.testing.expect(std.mem.indexOf(u8, logged, "mock response") != null);
}

test "runTurn records tool calls and results in the chat log" {
    const mock = @import("../providers/mock.zig");
    var prov = provider.Provider{ .mock = mock.MockClient.init(std.testing.allocator, std.testing.io) };
    defer prov.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var chat_log = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer chat_log.deinit();

    var session_stats = stats.SessionStats.init(std.testing.allocator, std.testing.io);
    defer session_stats.deinit();

    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();

    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(arena);
    try messages.append(arena, .{ .user = "read the file" });

    const result = try runTurn(&prov, arena, std.testing.io, &output.writer, &session_stats, false, random, "mock-model", null, &messages, &.{}, null, &chat_log.writer);

    try std.testing.expect(!result.turn_complete);
    const logged = chat_log.written();
    try std.testing.expect(std.mem.indexOf(u8, logged, "[TOOL_CALL]") != null);
    try std.testing.expect(std.mem.indexOf(u8, logged, "read_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, logged, "[TOOL_RESULT]") != null);
}

test "runTurn completes an empty turn without appending a message" {
    const mock = @import("../providers/mock.zig");
    var prov = provider.Provider{ .mock = mock.MockClient.init(std.testing.allocator, std.testing.io) };
    defer prov.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    var session_stats = stats.SessionStats.init(std.testing.allocator, std.testing.io);
    defer session_stats.deinit();

    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();

    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(arena);
    try messages.append(arena, .{ .user = "empty response" });

    const result = try runTurn(&prov, arena, std.testing.io, &output.writer, &session_stats, false, random, "mock-model", null, &messages, &.{}, null, null);

    try std.testing.expect(result.turn_complete);
    try std.testing.expect(result.usage_estimated);
    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
}
