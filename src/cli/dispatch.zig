const std = @import("std");
const ansi = @import("../tui/ansi.zig");
const attachments = @import("../chat/attachments.zig");
const config = @import("../config/config.zig");
const openai = @import("../providers/openai.zig");
const prompts = @import("../prompts/prompts.zig");
const parser = @import("parser.zig");

const Command = parser.Command;
const default_cfg = config.Config.default();

pub const Action = union(enum) {
    exit,
    continue_,
    full_reset,
    run_chat_turn,
    print_stats,
    reconfigure,
    switch_model: ?[]const u8,
    switch_provider: ?[]const u8,
    switch_effort: ?[]const u8,
    list_sessions,
    prune_sessions,
    restore_session: ?[]const u8,
    list_skills,
    load_skill: []const u8,
    load_prompt_file: []const u8,
    help,
};

pub const Context = struct {
    arena: std.mem.Allocator,
    messages_alloc: std.mem.Allocator,
    messages_arena: *std.heap.ArenaAllocator,
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    messages: *std.ArrayList(openai.Message),
    planning_mode: *bool,
    review_mode: *bool,
    oneshot: bool,
    cfg: *const config.Config,
    session_prd_path: []const u8 = "",
};

pub fn dispatch(command: Command, ctx: Context) !Action {
    switch (command) {
        .quit => return .exit,

        .help => return .help,

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
            try ctx.messages.append(ctx.messages_alloc, .{ .system = planning_prompt });
            if (ctx.session_prd_path.len > 0) {
                const prd_hint = try std.fmt.allocPrint(ctx.messages_alloc, "Session PRD path: {s}. Use the save_prd tool when ready to write the final PRD.", .{ctx.session_prd_path});
                try ctx.messages.append(ctx.messages_alloc, .{ .system = prd_hint });
            }
            if (text) |t| {
                try ctx.messages.append(ctx.messages_alloc, .{ .user = try ctx.messages_alloc.dupe(u8, t) });
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
            ctx.review_mode.* = false;
            try ctx.messages.append(ctx.messages_alloc, .{ .user = "Now implement the plan. Write all necessary code." });
            if (text) |t| {
                try ctx.messages.append(ctx.messages_alloc, .{ .user = try ctx.messages_alloc.dupe(u8, t) });
                try ctx.stdout_writer.print("\n{s}Switching to build mode: {s}{s}\n", .{ ansi.bright, t, ansi.reset });
                try ctx.stdout_writer.flush();
                return .run_chat_turn;
            }
            try ctx.stdout_writer.print("\n{s}Switching to build mode.{s}\n", .{ ansi.bright, ansi.reset });
            try ctx.stdout_writer.flush();
            return .continue_;
        },

        .review => |text| {
            ctx.planning_mode.* = false;
            ctx.review_mode.* = true;
            const review_prompt = try ctx.cfg.resolvePrompt(ctx.messages_alloc, "review", prompts.review);
            try ctx.messages.append(ctx.messages_alloc, .{ .system = review_prompt });
            if (text) |t| {
                try ctx.messages.append(ctx.messages_alloc, .{ .user = try ctx.messages_alloc.dupe(u8, t) });
                try ctx.stdout_writer.print("\n{s}Entering review mode: {s}{s}\n", .{ ansi.bright, t, ansi.reset });
                try ctx.stdout_writer.flush();
                return .run_chat_turn;
            }
            try ctx.stdout_writer.print("\n{s}Entering review mode.{s}\n", .{ ansi.bright, ansi.reset });
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

        .thinking => |effort| {
            if (ctx.oneshot) {
                try ctx.stdout_writer.print("\n/thinking not available in oneshot mode.\n", .{});
                try ctx.stdout_writer.flush();
                return .continue_;
            }
            return .{ .switch_effort = effort };
        },

        .sessions => return .list_sessions,

        .prune => return .prune_sessions,

        .resume_session => |session_id| {
            if (ctx.oneshot) {
                try ctx.stdout_writer.print("\n/resume not available in oneshot mode.\n", .{});
                try ctx.stdout_writer.flush();
                return .continue_;
            }
            return .{ .restore_session = session_id };
        },

        .skills => return .list_skills,

        .skill => |name_text| return .{ .load_skill = name_text },

        .file => |source| {
            const path = if (source) |s| std.mem.trim(u8, s, &std.ascii.whitespace) else "";
            if (path.len == 0) {
                try ctx.stdout_writer.print("\nUsage: /file <path-or-url>\n", .{});
                try ctx.stdout_writer.flush();
                return .continue_;
            }
            return .{ .load_prompt_file = path };
        },

        .prompt => |text| {
            const message = try attachments.buildAttachedMessage(ctx.messages_alloc, ctx.io, text);
            try ctx.messages.append(ctx.messages_alloc, .{ .user = message });
            return .run_chat_turn;
        },
    }
}
test "dispatch quit returns exit" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;
    var review_mode = false;

    const action = try dispatch(.quit, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .review_mode = &review_mode,
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
    var review_mode = false;

    const action = try dispatch(.reset, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .review_mode = &review_mode,
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
    var review_mode = false;

    const action = try dispatch(.config, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .review_mode = &review_mode,
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
    var review_mode = false;

    const action = try dispatch(.stats, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .review_mode = &review_mode,
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
    var review_mode = false;

    const action = try dispatch(Command{ .plan = null }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .review_mode = &review_mode,
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
    var review_mode = false;

    const action = try dispatch(Command{ .plan = "do thing" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .review_mode = &review_mode,
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
    var review_mode = false;

    const action = try dispatch(Command{ .build = null }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .review_mode = &review_mode,
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
    var review_mode = false;

    const action = try dispatch(Command{ .build = "now" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .review_mode = &review_mode,
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
    var review_mode = false;

    const action = try dispatch(Command{ .model = "x" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .review_mode = &review_mode,
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
    var review_mode = false;

    const action = try dispatch(Command{ .model = "llama" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .review_mode = &review_mode,
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
    var review_mode = false;

    const action = try dispatch(Command{ .provider = "opencode" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .review_mode = &review_mode,
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
    var review_mode = false;

    const action = try dispatch(Command{ .provider = "opencode" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .review_mode = &review_mode,
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
    var review_mode = false;

    const action = try dispatch(Command{ .provider = null }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .review_mode = &review_mode,
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
    var review_mode = false;

    const action = try dispatch(Command{ .thinking = "high" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .review_mode = &review_mode,
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
    var review_mode = false;

    const action = try dispatch(Command{ .thinking = "high" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .review_mode = &review_mode,
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
    var review_mode = false;

    const action = try dispatch(Command{ .thinking = null }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .review_mode = &review_mode,
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
    var review_mode = false;

    const action = try dispatch(.sessions, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .review_mode = &review_mode,
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
    var review_mode = false;

    const action = try dispatch(.prune, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .review_mode = &review_mode,
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
    var review_mode = false;

    const action = try dispatch(Command{ .prompt = "hello" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .review_mode = &review_mode,
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
    var review_mode = false;

    const action = try dispatch(Command{ .file = null }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .review_mode = &review_mode,
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
    var review_mode = false;

    const action = try dispatch(Command{ .file = "spec.md" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .review_mode = &review_mode,
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
    var review_mode = false;

    const action = try dispatch(Command{ .file = "  spec.md " }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .review_mode = &review_mode,
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
    var review_mode = false;

    const action = try dispatch(Command{ .file = "   " }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .review_mode = &review_mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqual(Action.continue_, action);
    try std.testing.expect(std.mem.containsAtLeast(u8, out.written(), 1, "Usage: /file"));
}

test "dispatch resume_session in oneshot mode rejects" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;
    var review_mode = false;

    const action = try dispatch(Command{ .resume_session = "abc-1" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .review_mode = &review_mode,
        .oneshot = true,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqual(Action.continue_, action);
}

test "dispatch resume_session returns restore_session" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;
    var review_mode = false;

    const action = try dispatch(Command{ .resume_session = "abc-1" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .review_mode = &review_mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqualDeep(Action{ .restore_session = "abc-1" }, action);
}

test "dispatch skills returns list_skills" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;
    var review_mode = false;

    const action = try dispatch(.skills, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .review_mode = &review_mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqual(Action.list_skills, action);
}

test "dispatch help returns help" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;
    var review_mode = false;

    const action = try dispatch(.help, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .review_mode = &review_mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqual(Action.help, action);
}

test "dispatch plan appends the PRD hint when a session PRD path is set" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;
    var review_mode = false;

    const action = try dispatch(Command{ .plan = null }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .review_mode = &review_mode,
        .oneshot = false,
        .cfg = &default_cfg,
        .session_prd_path = "plan.md",
    });

    try std.testing.expectEqual(Action.continue_, action);
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expect(messages.items[1] == .system);
    try std.testing.expect(std.mem.indexOf(u8, messages.items[1].system, "Session PRD path: plan.md") != null);
}
