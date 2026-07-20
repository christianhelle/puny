const std = @import("std");
const ansi = @import("../tui/ansi.zig");
const config = @import("../config/config.zig");
const openai = @import("../providers/openai.zig");
const prompts = @import("../prompts/prompts.zig");

const default_cfg = config.Config.default();

pub const Command = union(enum) {
    quit,
    reset,
    stats,
    config,
    plan: ?[]const u8,
    build: ?[]const u8,
    model: ?[]const u8,
    provider: ?[]const u8,
    prompt: []const u8,
};

pub const Action = union(enum) {
    exit,
    continue_,
    full_reset,
    run_chat_turn,
    print_stats,
    reconfigure,
    switch_model: ?[]const u8,
    switch_provider: ?[]const u8,
};

pub const Context = struct {
    arena: std.mem.Allocator,
    messages_alloc: std.mem.Allocator,
    messages_arena: *std.heap.ArenaAllocator,
    stdout_writer: *std.Io.Writer,
    messages: *std.array_list.Managed(openai.Message),
    planning_mode: *bool,
    oneshot: bool,
    cfg: *const config.Config,
};

pub fn parse(user_message: []const u8) Command {
    if (std.mem.eql(u8, user_message, "/quit") or std.mem.eql(u8, user_message, "/exit"))
        return .quit;

    if (std.mem.eql(u8, user_message, "/reset"))
        return .reset;

    if (std.mem.eql(u8, user_message, "/stats"))
        return .stats;

    if (std.mem.eql(u8, user_message, "/config"))
        return .config;

    if (std.mem.eql(u8, user_message, "/plan") or std.mem.startsWith(u8, user_message, "/plan ")) {
        if (user_message.len > "/plan ".len) {
            return .{ .plan = user_message["/plan ".len..] };
        }
        return .{ .plan = null };
    }

    if (std.mem.eql(u8, user_message, "/build") or std.mem.startsWith(u8, user_message, "/build ")) {
        if (user_message.len > "/build ".len) {
            return .{ .build = user_message["/build ".len..] };
        }
        return .{ .build = null };
    }

    if (std.mem.eql(u8, user_message, "/model") or std.mem.startsWith(u8, user_message, "/model ")) {
        if (user_message.len > "/model ".len) {
            return .{ .model = user_message["/model ".len..] };
        }
        return .{ .model = null };
    }

    if (std.mem.eql(u8, user_message, "/provider") or std.mem.startsWith(u8, user_message, "/provider ")) {
        if (user_message.len > "/provider ".len) {
            return .{ .provider = user_message["/provider ".len..] };
        }
        return .{ .provider = null };
    }

    return .{ .prompt = user_message };
}

pub fn dispatch(command: Command, ctx: Context) !Action {
    switch (command) {
        .quit => return .exit,

        .reset => {
            try ctx.stdout_writer.print("\nConversation reset.", .{});
            try ctx.stdout_writer.flush();
            return .full_reset;
        },

        .stats => return .print_stats,

        .config => return .reconfigure,

        .plan => |text| {
            ctx.planning_mode.* = true;
            const planning_prompt = try ctx.cfg.resolvePrompt(ctx.messages_alloc, "planning", prompts.planning);
            try ctx.messages.append(.{ .system = planning_prompt });
            if (text) |t| {
                try ctx.messages.append(.{ .user = try ctx.messages_alloc.dupe(u8, t) });
                try ctx.stdout_writer.print("\n{s}Entering planning mode: {s}{s}\n", .{ ansi.bright, t, ansi.reset });
                try ctx.stdout_writer.flush();
                return .run_chat_turn;
            }
            try ctx.stdout_writer.print("\n{s}Entering planning mode.{s}\n", .{ ansi.bright, ansi.reset });
            try ctx.stdout_writer.flush();
            return .continue_;
        },

        .build => |text| {
            ctx.planning_mode.* = false;
            try ctx.messages.append(.{ .user = "Now implement the plan. Write all necessary code." });
            if (text) |t| {
                try ctx.messages.append(.{ .user = try ctx.messages_alloc.dupe(u8, t) });
                try ctx.stdout_writer.print("\n{s}Switching to build mode: {s}{s}\n", .{ ansi.bright, t, ansi.reset });
                try ctx.stdout_writer.flush();
                return .run_chat_turn;
            }
            try ctx.stdout_writer.print("\n{s}Switching to build mode.{s}\n", .{ ansi.bright, ansi.reset });
            try ctx.stdout_writer.flush();
            return .continue_;
        },

        .model => |model_id| {
            if (ctx.oneshot) {
                try ctx.stdout_writer.print("\n/model not available in oneshot mode.\n", .{});
                try ctx.stdout_writer.flush();
                return .continue_;
            }
            return .{ .switch_model = model_id };
        },

        .provider => |provider_id| {
            if (ctx.oneshot) {
                try ctx.stdout_writer.print("\n/provider not available in oneshot mode.\n", .{});
                try ctx.stdout_writer.flush();
                return .continue_;
            }
            return .{ .switch_provider = provider_id };
        },

        .prompt => |text| {
            try ctx.messages.append(.{ .user = try ctx.messages_alloc.dupe(u8, text) });
            return .run_chat_turn;
        },
    }
}

test "parse recognizes all slash commands" {
    try std.testing.expectEqual(Command.quit, parse("/quit"));
    try std.testing.expectEqual(Command.quit, parse("/exit"));
    try std.testing.expectEqual(Command.reset, parse("/reset"));
    try std.testing.expectEqual(Command.stats, parse("/stats"));
    try std.testing.expectEqual(Command.config, parse("/config"));

    try std.testing.expectEqualDeep(Command{ .plan = null }, parse("/plan"));
    try std.testing.expectEqualDeep(Command{ .plan = "do thing" }, parse("/plan do thing"));

    try std.testing.expectEqualDeep(Command{ .build = null }, parse("/build"));
    try std.testing.expectEqualDeep(Command{ .build = "code it" }, parse("/build code it"));

    try std.testing.expectEqualDeep(Command{ .model = null }, parse("/model"));
    try std.testing.expectEqualDeep(Command{ .model = "llama" }, parse("/model llama"));

    try std.testing.expectEqualDeep(Command{ .provider = null }, parse("/provider"));
    try std.testing.expectEqualDeep(Command{ .provider = "opencode" }, parse("/provider opencode"));

    try std.testing.expectEqualDeep(Command{ .prompt = "hello" }, parse("hello"));
}

test "dispatch quit returns exit" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.array_list.Managed(openai.Message).init(messages_arena_state.allocator());
    defer messages.deinit();
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(.quit, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
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
    var messages = std.array_list.Managed(openai.Message).init(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(.reset, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
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
    var messages = std.array_list.Managed(openai.Message).init(messages_arena_state.allocator());
    defer messages.deinit();
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(.config, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
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
    var messages = std.array_list.Managed(openai.Message).init(messages_arena_state.allocator());
    defer messages.deinit();
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(.stats, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
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
    var messages = std.array_list.Managed(openai.Message).init(messages_arena_state.allocator());
    defer messages.deinit();
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(Command{ .plan = null }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqual(Action.continue_, action);
    try std.testing.expect(planning_mode);
    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    try std.testing.expectEqual(openai.Message.system, messages.items[0]);
}

test "dispatch plan with text enters planning mode and runs chat turn" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.array_list.Managed(openai.Message).init(messages_arena_state.allocator());
    defer messages.deinit();
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(Command{ .plan = "do thing" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqual(Action.run_chat_turn, action);
    try std.testing.expect(planning_mode);
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expectEqual(openai.Message.system, messages.items[0]);
    try std.testing.expectEqualDeep(openai.Message{ .user = "do thing" }, messages.items[1]);
}

test "dispatch build without text switches to build mode and continues" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.array_list.Managed(openai.Message).init(messages_arena_state.allocator());
    defer messages.deinit();
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = true;

    const action = try dispatch(Command{ .build = null }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
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
    var messages = std.array_list.Managed(openai.Message).init(messages_arena_state.allocator());
    defer messages.deinit();
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = true;

    const action = try dispatch(Command{ .build = "now" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
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
    var messages = std.array_list.Managed(openai.Message).init(messages_arena_state.allocator());
    defer messages.deinit();
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(Command{ .model = "x" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
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
    var messages = std.array_list.Managed(openai.Message).init(messages_arena_state.allocator());
    defer messages.deinit();
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(Command{ .model = "llama" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
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
    var messages = std.array_list.Managed(openai.Message).init(messages_arena_state.allocator());
    defer messages.deinit();
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(Command{ .provider = "opencode" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
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
    var messages = std.array_list.Managed(openai.Message).init(messages_arena_state.allocator());
    defer messages.deinit();
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(Command{ .provider = "opencode" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
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
    var messages = std.array_list.Managed(openai.Message).init(messages_arena_state.allocator());
    defer messages.deinit();
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(Command{ .provider = null }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqualDeep(Action{ .switch_provider = null }, action);
}

test "dispatch prompt appends user message and runs chat turn" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.array_list.Managed(openai.Message).init(messages_arena_state.allocator());
    defer messages.deinit();
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;

    const action = try dispatch(Command{ .prompt = "hello" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqual(Action.run_chat_turn, action);
    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    try std.testing.expectEqualDeep(openai.Message{ .user = "hello" }, messages.items[0]);
}
