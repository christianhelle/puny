//! Tests for the CLI command dispatcher. Kept in a separate file so
//! `dispatch.zig` stays focused on the production implementation.
const std = @import("std");
const openai = @import("../providers/openai.zig");
const config = @import("../config/config.zig");
const parser = @import("parser.zig");
const dispatch_mod = @import("dispatch.zig");

const dispatch = dispatch_mod.dispatch;
const Action = dispatch_mod.Action;
const Command = parser.Command;
const default_cfg = config.Config.default();

test "dispatch quit returns exit" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(.quit, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqual(Action.exit, action);
}

test "dispatch reset returns full_reset action" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(.reset, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqual(Action.full_reset, action);
}

test "dispatch config returns reconfigure" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(.config, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqual(Action.reconfigure, action);
}

test "dispatch stats returns print_stats" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(.stats, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqual(Action.print_stats, action);
}

test "dispatch plan without text enters planning mode and continues" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(Command{ .plan = null }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqual(Action.continue_, action);
    try std.testing.expect(planning_mode);
    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    try std.testing.expect(messages.items[0] == .system);
}

test "dispatch plan with text enters planning mode and runs chat turn" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(Command{ .plan = "do thing" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqual(Action.run_chat_turn, action);
    try std.testing.expect(planning_mode);
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expect(messages.items[0] == .system);
    try std.testing.expectEqualDeep(openai.Message{ .user = "do thing" }, messages.items[1]);
}

test "dispatch build without text switches to build mode and continues" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = true;

    const action = try dispatch(Command{ .build = null }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqual(Action.continue_, action);
    try std.testing.expect(!planning_mode);
    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    try std.testing.expectEqualDeep(openai.Message{ .user = "Now implement the plan. Write all necessary code." }, messages.items[0]);
}

test "dispatch build with text switches to build mode and runs chat turn" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = true;

    const action = try dispatch(Command{ .build = "now" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqual(Action.run_chat_turn, action);
    try std.testing.expect(!planning_mode);
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expectEqualDeep(openai.Message{ .user = "Now implement the plan. Write all necessary code." }, messages.items[0]);
    try std.testing.expectEqualDeep(openai.Message{ .user = "now" }, messages.items[1]);
}

test "dispatch model in oneshot mode rejects" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(Command{ .model = "x" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .oneshot = true,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqual(Action.continue_, action);
}

test "dispatch model returns switch model" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(Command{ .model = "llama" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqualDeep(Action{ .switch_model = "llama" }, action);
}

test "dispatch provider in oneshot mode rejects" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(Command{ .provider = "opencode" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .oneshot = true,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqual(Action.continue_, action);
}

test "dispatch provider returns switch provider" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(Command{ .provider = "opencode" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqualDeep(Action{ .switch_provider = "opencode" }, action);
}

test "dispatch provider without text returns switch provider with null" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(Command{ .provider = null }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqualDeep(Action{ .switch_provider = null }, action);
}

test "dispatch thinking in oneshot mode rejects" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(Command{ .thinking = "high" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .oneshot = true,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqual(Action.continue_, action);
}

test "dispatch thinking returns switch effort" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(Command{ .thinking = "high" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqualDeep(Action{ .switch_effort = "high" }, action);
}

test "dispatch thinking without text returns switch effort with null" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(Command{ .thinking = null }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqualDeep(Action{ .switch_effort = null }, action);
}

test "dispatch sessions returns list_sessions" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(.sessions, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqual(Action.list_sessions, action);
}

test "dispatch prune returns prune_sessions" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(.prune, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqual(Action.prune_sessions, action);
}

test "dispatch prompt appends user message and runs chat turn" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(Command{ .prompt = "hello" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqual(Action.run_chat_turn, action);
    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    try std.testing.expectEqualDeep(openai.Message{ .user = "hello" }, messages.items[0]);
}

test "dispatch file without text prints usage and continues" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(Command{ .file = null }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqual(Action.continue_, action);
    try std.testing.expect(std.mem.containsAtLeast(u8, out.written(), 1, "Usage: /file"));
}

test "dispatch file returns load_prompt_file action" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(Command{ .file = "spec.md" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqualDeep(Action{ .load_prompt_file = "spec.md" }, action);
}

test "dispatch file trims surrounding whitespace from the path" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(Command{ .file = "  spec.md " }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqualDeep(Action{ .load_prompt_file = "spec.md" }, action);
}

test "dispatch file with only whitespace prints usage and continues" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(Command{ .file = "   " }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqual(Action.continue_, action);
    try std.testing.expect(std.mem.containsAtLeast(u8, out.written(), 1, "Usage: /file"));
}
