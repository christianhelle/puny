const std = @import("std");
const ansi = @import("../tui/ansi.zig");
const chat_retry = @import("retry.zig");
const stats = @import("stats.zig");
const indicator = @import("../tui/indicator.zig");
const terminal = @import("../tui/terminal.zig");
const openai = @import("../providers/openai.zig");
const provider = @import("../providers/provider.zig");
const tools = @import("../tools/root.zig");
const tool_display = @import("display.zig");
const diff_view = @import("diff_view.zig");
const usage_estimator = @import("usage.zig");
const accumulator = @import("accumulator.zig");
const AgentMode = @import("../core/mode.zig").AgentMode;
const utf8 = @import("../core/utf8.zig");

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

/// Chooses the reasoning effort to request for a turn.
///
/// `--show-thinking` and `--chat-log` both want reasoning tokens to exist at
/// all, so with nothing configured they raise the level to high. An explicit
/// level always wins, including `.default`, which is how a caller opts out of
/// that behaviour and lets the provider decide.
fn effectiveEffort(
    explicit: ?openai.ReasoningEffort,
    show_thinking: bool,
    has_chat_log: bool,
) ?openai.ReasoningEffort {
    if (explicit) |level| return level;
    if (show_thinking or has_chat_log) return .high;
    return null;
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
    const effective_effort = effectiveEffort(reasoning_effort, show_thinking, chat_log != null);
    const request = openai.ChatRequest{
        .model = model_key,
        .messages = messages.items,
        .tools = tool_definitions,
        .stream = true,
        .reasoning_effort = effective_effort,
    };

    const tool_tokens = usage_estimator.estimateToolTokens(tool_definitions);
    const input_estimate = usage_estimator.estimateUsage(request.messages, 0).input_tokens + tool_tokens;
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
    const turn_usage = if (acc.usage) |u| u else blk: {
        var estimated = usage_estimator.estimateUsage(messages.items, acc.estimatedOutputChars());
        estimated.input_tokens += tool_tokens;
        break :blk estimated;
    };

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

        // Close an open reasoning block so the tool-call lines start on their
        // own line instead of running into the thinking text. Only done here:
        // when nothing follows the reasoning, the extra line would shift the
        // cursor the indicator rewinds over to clear its "Thinking..." line.
        try acc.finishReasoning();

        var tool_output_lines: usize = 0;
        for (assistant_content.tool_calls.?) |tc| {
            try printToolCall(arena, stdout_writer, tc);
            try stdout_writer.flush();
            const run = try runTool(arena, io, stdout_writer, tc, mode, content_cursor_offset + tool_output_lines, terminal.terminalHeight());
            const result = run.result;
            tool_output_lines += tool_display.toolCallRows(tc.function.name, result) + run.diff_rows;
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
    const columns = terminal.terminalWidth() orelse std.math.maxInt(usize);
    const rendered_tool_call = try tool_display.renderToolCallFitting(arena, tool_call, columns);
    try stdout_writer.print("\n{s}🔧 {s}{s}", .{ ansi.dim, rendered_tool_call, ansi.reset });
}

const ToolRun = struct { result: []const u8, diff_rows: usize };

/// Runs a tool call and prints the diff of any file it changed. The result
/// lives in `arena`, the conversation's, because it is kept in the history.
/// Everything the diff needs, which can be several times the size of the
/// file, lives in a scratch arena freed before returning.
fn runTool(
    arena: std.mem.Allocator,
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    tool_call: openai.ToolCall,
    mode: AgentMode,
    rows_used: usize,
    height: ?usize,
) !ToolRun {
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const snapshot = diff_view.capture(scratch.allocator(), io, tool_call);
    const result = try executeTool(arena, io, tool_call, mode);
    const diff_rows = try printDiff(scratch.allocator(), io, stdout_writer, snapshot, rows_used, height);
    return .{ .result = result, .diff_rows = diff_rows };
}

/// Prints the diff of the file a tool just changed under its tool-call line
/// and returns how many rows it took, which the thinking indicator needs to
/// find its own line again. `rows_used` is how many rows this turn already
/// put on a screen `height` rows tall; the diff is shortened, or skipped, so
/// the indicator line stays in view. A diff that can't be shown is skipped: it must
/// never fail the turn.
fn printDiff(
    arena: std.mem.Allocator,
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    snapshot: ?diff_view.Snapshot,
    rows_used: usize,
    height: ?usize,
) !usize {
    const before_change = snapshot orelse return 0;
    const columns = terminal.terminalWidth() orelse 120;
    const budget = diff_view.rowBudget(height, rows_used);
    const rendered = diff_view.render(arena, io, before_change, columns, budget) catch return 0;
    if (rendered.rows == 0) return 0;
    // The tool has already run: a terminal that can't take the diff must not
    // keep its result out of the history.
    stdout_writer.writeAll(rendered.text) catch return 0;
    stdout_writer.flush() catch return 0;
    return rendered.rows;
}

/// Backstop above every tool's own limit (read_file and web_fetch keep 1 MiB,
/// run_command 128 KiB per stream), so no tool result, a future tool's
/// included, can grow the conversation without bound. Every later request
/// resends it.
const max_tool_result_bytes: usize = 2 * 1024 * 1024;

fn executeTool(arena: std.mem.Allocator, io: std.Io, tool_call: openai.ToolCall, mode: AgentMode) ![]const u8 {
    const result = try executeToolUnbounded(arena, io, tool_call, mode);
    return boundToolResult(arena, result);
}

/// Cuts a result longer than `max_tool_result_bytes` and says so, so the
/// model knows it saw only the start.
fn boundToolResult(arena: std.mem.Allocator, result: []const u8) ![]const u8 {
    if (result.len <= max_tool_result_bytes) return result;
    const bounded = try std.fmt.allocPrint(arena, "{s}\n[tool result truncated after {d} bytes]", .{
        utf8.prefix(result, max_tool_result_bytes),
        max_tool_result_bytes,
    });
    std.debug.assert(bounded.len < max_tool_result_bytes + 64);
    return bounded;
}

fn executeToolUnbounded(arena: std.mem.Allocator, io: std.Io, tool_call: openai.ToolCall, mode: AgentMode) ![]const u8 {
    const tool = tools.dispatchForMode(tool_call.function.name, mode) orelse {
        return std.fmt.allocPrint(arena, "Unknown tool: {s}", .{tool_call.function.name});
    };

    // Arguments the model streamed can be truncated or malformed. Reporting
    // that back as the tool's result keeps every tool_call paired with a tool
    // message; letting it unwind would leave the assistant's tool_calls
    // orphaned, which the provider rejects on every later request.
    var parsed = std.json.parseFromSlice(std.json.Value, arena, tool_call.function.arguments, .{ .ignore_unknown_fields = true }) catch |err| {
        return std.fmt.allocPrint(arena, "Tool {s} failed: invalid arguments: {}", .{ tool_call.function.name, err });
    };
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

test "boundToolResult keeps a result at the limit and cuts a longer one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const at_limit = try arena.alloc(u8, max_tool_result_bytes);
    @memset(at_limit, 'a');
    try std.testing.expectEqual(at_limit.ptr, (try boundToolResult(arena, at_limit)).ptr);

    const over_limit = try arena.alloc(u8, max_tool_result_bytes + 1);
    @memset(over_limit, 'b');
    const bounded = try boundToolResult(arena, over_limit);
    try std.testing.expect(std.mem.endsWith(u8, bounded, "\n[tool result truncated after 2097152 bytes]"));
    try std.testing.expect(std.mem.allEqual(u8, bounded[0..max_tool_result_bytes], 'b'));
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

test "executeTool reports malformed tool arguments as a tool result" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const result = try executeTool(
        arena_state.allocator(),
        std.testing.io,
        .{ .id = "call_1", .function = .{ .name = "read_file", .arguments = "{\"path\": " } },
        .build,
    );
    try std.testing.expect(std.mem.startsWith(u8, result, "Tool read_file failed: invalid arguments: error."));
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

test "executeTool runs edit_file on a real file" {
    const helpers = @import("../tools/helpers.zig");
    const path = "puny-test-chat-edit.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    try helpers.writeFile(std.testing.io, path, "before");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arguments = try std.fmt.allocPrint(arena_state.allocator(), "{{\"path\":\"{s}\",\"old_string\":\"before\",\"new_string\":\"after\"}}", .{path});

    const result = try executeTool(
        arena_state.allocator(),
        std.testing.io,
        .{ .id = "call_1", .function = .{ .name = "edit_file", .arguments = arguments } },
        .build,
    );
    try std.testing.expectEqualStrings("File edited successfully.", result);

    const content = try helpers.readFileAlloc(std.testing.allocator, std.testing.io, path, 1024);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("after", content);
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

test "effectiveEffort keeps an explicit level even when the chat log is on" {
    try std.testing.expectEqual(
        @as(?openai.ReasoningEffort, .low),
        effectiveEffort(.low, false, true),
    );
}

test "effectiveEffort keeps an explicit level even when thinking is shown" {
    try std.testing.expectEqual(
        @as(?openai.ReasoningEffort, .low),
        effectiveEffort(.low, true, false),
    );
}

test "effectiveEffort honours an explicit default as the opt-out" {
    try std.testing.expectEqual(
        @as(?openai.ReasoningEffort, .default),
        effectiveEffort(.default, true, true),
    );
}

test "effectiveEffort raises to high when the chat log needs reasoning" {
    try std.testing.expectEqual(
        @as(?openai.ReasoningEffort, .high),
        effectiveEffort(null, false, true),
    );
}

test "effectiveEffort raises to high when thinking is shown" {
    try std.testing.expectEqual(
        @as(?openai.ReasoningEffort, .high),
        effectiveEffort(null, true, false),
    );
}

test "effectiveEffort leaves the level unset when nothing asks for reasoning" {
    try std.testing.expectEqual(
        @as(?openai.ReasoningEffort, null),
        effectiveEffort(null, false, false),
    );
}

test "agent loop output never leaves consecutive blank lines" {
    const mock = @import("../providers/mock.zig");
    const token_stats = @import("../tui/token_stats.zig");
    const FakeScreen = @import("../tui/fake_screen.zig").FakeScreen;
    var prov = provider.Provider{ .mock = mock.MockClient.init(std.testing.allocator, std.testing.io) };
    defer prov.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var output = std.Io.Writer.Allocating.init(arena);
    defer output.deinit();

    var session_stats = stats.SessionStats.init(std.testing.allocator, std.testing.io);
    defer session_stats.deinit();

    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();

    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(arena);

    // Mirrors the interactive chat loop: submitting a prompt ends the prompt
    // row, each agent iteration shows the indicator before running its turn,
    // and a footer closes the turn.
    for ([_][]const u8{ "read the file", "say fast" }) |prompt| {
        try output.writer.print("\n> {s}\r\n", .{prompt});
        try messages.append(arena, .{ .user = prompt });
        var turn_complete = false;
        while (!turn_complete) {
            var thinking_indicator = indicator.ThinkingIndicator.init(std.testing.io);
            try thinking_indicator.show(&output.writer);
            const result = try runTurn(&prov, arena, std.testing.io, &output.writer, &session_stats, false, random, "mock-model", null, &messages, &.{}, &thinking_indicator, null);
            turn_complete = result.turn_complete;
        }
        try token_stats.printTokenFooter(&output.writer, 1, 1, false, 2, null, null, null, null);
    }
    try output.writer.writeAll("\n> ");

    var screen = FakeScreen{ .width = terminal.terminalWidth() orelse 80 };
    defer screen.deinit(arena);
    try screen.feed(arena, output.written());
    const text = try screen.toText(arena);

    errdefer std.debug.print("screen:\n{s}\n", .{text});
    try std.testing.expect(std.mem.indexOf(u8, text, "Thinking...") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\n\n\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "> read the file\n\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, ")\n\n> "));
}

test "runTurn estimates unreported input with the tool definitions" {
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

    var function: std.json.ObjectMap = .empty;
    try function.put(arena, "name", .{ .string = "read_file" });
    const tool_definitions = [_]openai.ToolDefinition{.{ .function = .{ .object = function } }};

    const result = try runTurn(&prov, arena, std.testing.io, &output.writer, &session_stats, false, random, "mock-model", null, &messages, &tool_definitions, null, null);
    session_stats.finalizeTurn(result.usage, result.turn_complete);

    // 2 tokens for "say fast" and 12 for the 51-character tool definition.
    try std.testing.expect(result.usage_estimated);
    try std.testing.expectEqual(@as(i64, 14), result.usage.?.input_tokens);
    try std.testing.expectEqual(@as(i64, 14), session_stats.models.items[0].stats.input_tokens);
}

test "printDiff writes the rows a write_file produced and returns their count" {
    diff_view.enabled = true;
    defer diff_view.enabled = false;
    const path = "puny-test-chat-diff.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var output = std.Io.Writer.Allocating.init(arena);

    const call = openai.ToolCall{ .id = "call_1", .function = .{ .name = "write_file", .arguments = "{\"path\":\"puny-test-chat-diff.txt\",\"content\":\"hi\\n\"}" } };
    const snapshot = diff_view.capture(arena, std.testing.io, call);
    _ = try executeTool(arena, std.testing.io, call, .build);
    const rows = try printDiff(arena, std.testing.io, &output.writer, snapshot, 0, null);
    try std.testing.expectEqual(@as(usize, 1), rows);
    try std.testing.expectEqualStrings("\n   " ++ ansi.green ++ "1 +" ++ ansi.reset ++ " hi", output.written());
}

test "printDiff writes nothing when diffs are off or nothing changed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var output = std.Io.Writer.Allocating.init(arena);
    try std.testing.expectEqual(@as(usize, 0), try printDiff(arena, std.testing.io, &output.writer, null, 0, null));
    try std.testing.expectEqualStrings("", output.written());
}

test "diff rows are cleared with the indicator and stay in order" {
    const helpers = @import("../tools/helpers.zig");
    const FakeScreen = @import("../tui/fake_screen.zig").FakeScreen;
    diff_view.enabled = true;
    defer diff_view.enabled = false;
    const path = "puny-test-chat-diff-screen.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try helpers.writeFile(std.testing.io, path, "a\nb\nc\n");
    var output = std.Io.Writer.Allocating.init(arena);

    const call = openai.ToolCall{ .id = "call_1", .function = .{ .name = "edit_file", .arguments = "{\"path\":\"puny-test-chat-diff-screen.txt\",\"old_string\":\"b\",\"new_string\":\"X\"}" } };
    var thinking = indicator.ThinkingIndicator.init(std.testing.io);
    try output.writer.writeAll("\n> go\r\n");
    try thinking.show(&output.writer);
    try printToolCall(arena, &output.writer, call);
    const snapshot = diff_view.capture(arena, std.testing.io, call);
    _ = try executeTool(arena, std.testing.io, call, .build);
    const rows = try printDiff(arena, std.testing.io, &output.writer, snapshot, 0, null);
    try std.testing.expectEqual(@as(usize, 4), rows);
    try thinking.finish(std.testing.io, &output.writer, 1 + rows, false, true, .done, null);

    var screen = FakeScreen{ .width = 80 };
    defer screen.deinit(arena);
    try screen.feed(arena, output.written());
    const text = try screen.toText(arena);
    errdefer std.debug.print("screen:\n{s}\n", .{text});
    try std.testing.expect(std.mem.indexOf(u8, text, "Thinking...") == null);
    const tool = std.mem.indexOf(u8, text, "Editing") orelse return error.MissingToolLine;
    const removed = std.mem.indexOf(u8, text, "2 - b") orelse return error.MissingRemoved;
    const added = std.mem.indexOf(u8, text, "2 + X") orelse return error.MissingAdded;
    try std.testing.expect(tool < removed and removed < added);
}

test "stacked diffs never push the indicator line off a short screen" {
    diff_view.enabled = true;
    defer diff_view.enabled = false;
    const path = "puny-test-chat-diff-budget.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var output = std.Io.Writer.Allocating.init(arena);

    var content: std.ArrayList(u8) = .empty;
    for (0..40) |i| try content.print(arena, "line {d}\n", .{i});
    const args = try std.json.Stringify.valueAlloc(arena, .{ .path = path, .content = content.items }, .{});
    const call = openai.ToolCall{ .id = "call_1", .function = .{ .name = "write_file", .arguments = args } };

    const height: usize = 24;
    var rows_used: usize = 0;
    var shown: usize = 0;
    for (0..3) |_| {
        // Each pass rewrites the file with different content, as two writes
        // in one turn would.
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        const snapshot = diff_view.capture(arena, std.testing.io, call);
        _ = try executeTool(arena, std.testing.io, call, .build);
        const rows = try printDiff(arena, std.testing.io, &output.writer, snapshot, rows_used, height);
        if (rows > 0) {
            shown += 1;
            // The indicator must stay in view above this tool's line, the diff
            // and the input bar.
            try std.testing.expect(rows_used + 1 + rows <= height - 3);
        }
        rows_used += 1 + rows;
    }
    // The first diff fits; once the screen is nearly full the rest are skipped.
    try std.testing.expectEqual(@as(usize, 1), shown);
}

test "diffing a large file does not grow the conversation arena" {
    const helpers = @import("../tools/helpers.zig");
    diff_view.enabled = true;
    defer diff_view.enabled = false;
    const path = "puny-test-chat-diff-scratch.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    // About 600 KiB on disk, replaced by a two-line file: the diff has to
    // read, split and prepare all of it.
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(std.testing.allocator);
    for (0..40000) |i| try big.print(std.testing.allocator, "line number {d}\n", .{i});
    try helpers.writeFile(std.testing.io, path, big.items);

    const call = openai.ToolCall{ .id = "call_1", .function = .{ .name = "write_file", .arguments = "{\"path\":\"puny-test-chat-diff-scratch.txt\",\"content\":\"a\\nb\\n\"}" } };
    const before = arena_state.queryCapacity();
    const run = try runTool(arena, std.testing.io, &output.writer, call, .build, 0, null);
    try std.testing.expect(run.diff_rows > 0);
    try std.testing.expectEqualStrings("File written successfully.", run.result);
    // Only the tool result and its arguments belong to the conversation.
    try std.testing.expect(arena_state.queryCapacity() - before < 64 * 1024);
}

test "printDiff leaves the turn alone when the terminal write fails" {
    diff_view.enabled = true;
    defer diff_view.enabled = false;
    const path = "puny-test-chat-diff-failing.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const call = openai.ToolCall{ .id = "call_1", .function = .{ .name = "write_file", .arguments = "{\"path\":\"puny-test-chat-diff-failing.txt\",\"content\":\"hi\\n\"}" } };
    const snapshot = diff_view.capture(arena, std.testing.io, call);
    _ = try executeTool(arena, std.testing.io, call, .build);
    var failing = std.Io.Writer.failing;
    // The tool already ran, so its result must still be recorded.
    try std.testing.expectEqual(@as(usize, 0), try printDiff(arena, std.testing.io, &failing, snapshot, 0, null));
}
