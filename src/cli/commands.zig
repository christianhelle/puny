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
    thinking: ?[]const u8,
    sessions,
    prune,
    resume_session: ?[]const u8,
    skills,
    skill: []const u8,
    file: ?[]const u8,
    prompt: []const u8,
    help,
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
    stdout_writer: *std.Io.Writer,
    messages: *std.ArrayList(openai.Message),
    planning_mode: *bool,
    oneshot: bool,
    cfg: *const config.Config,
    session_prd_path: []const u8 = "",
};

/// The interactive slash commands recognized by `parse`, in display order.
pub const command_tokens = [_][]const u8{
    "/quit",
    "/exit",
    "/reset",
    "/new",
    "/stats",
    "/config",
    "/plan",
    "/build",
    "/model",
    "/provider",
    "/thinking",
    "/sessions",
    "/resume",
    "/prune",
    "/skills",
    "/file",
};

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

pub fn parse(user_message: []const u8) Command {
    if (eqlIgnoreCase(user_message, "/quit") or eqlIgnoreCase(user_message, "/exit"))
        return .quit;
    if (eqlIgnoreCase(user_message, ":exit") or eqlIgnoreCase(user_message, ":quit"))
        return .quit;
    if (eqlIgnoreCase(user_message, ":q"))
        return .quit;

    if (eqlIgnoreCase(user_message, "/reset") or eqlIgnoreCase(user_message, "/new"))
        return .reset;
    if (eqlIgnoreCase(user_message, ":reset") or eqlIgnoreCase(user_message, ":new"))
        return .reset;

    if (eqlIgnoreCase(user_message, "/stats") or eqlIgnoreCase(user_message, ":stats"))
        return .stats;

    if (eqlIgnoreCase(user_message, "/config") or eqlIgnoreCase(user_message, ":config"))
        return .config;

    if (eqlIgnoreCase(user_message, "/plan") or std.mem.startsWith(u8, user_message, "/plan ")) {
        if (user_message.len > "/plan ".len) {
            return .{ .plan = user_message["/plan ".len..] };
        }
        return .{ .plan = null };
    }
    if (eqlIgnoreCase(user_message, ":plan") or std.mem.startsWith(u8, user_message, ":plan ")) {
        if (user_message.len > ":plan ".len) {
            return .{ .plan = user_message[":plan ".len..] };
        }
        return .{ .plan = null };
    }

    if (eqlIgnoreCase(user_message, "/build") or std.mem.startsWith(u8, user_message, "/build ")) {
        if (user_message.len > "/build ".len) {
            return .{ .build = user_message["/build ".len..] };
        }
        return .{ .build = null };
    }
    if (eqlIgnoreCase(user_message, ":build") or std.mem.startsWith(u8, user_message, ":build ")) {
        if (user_message.len > ":build ".len) {
            return .{ .build = user_message[":build ".len..] };
        }
        return .{ .build = null };
    }

    if (eqlIgnoreCase(user_message, "/model") or std.mem.startsWith(u8, user_message, "/model ")) {
        if (user_message.len > "/model ".len) {
            return .{ .model = user_message["/model ".len..] };
        }
        return .{ .model = null };
    }
    if (eqlIgnoreCase(user_message, ":model") or std.mem.startsWith(u8, user_message, ":model ")) {
        if (user_message.len > ":model ".len) {
            return .{ .model = user_message[":model ".len..] };
        }
        return .{ .model = null };
    }

    if (eqlIgnoreCase(user_message, "/provider") or std.mem.startsWith(u8, user_message, "/provider ")) {
        if (user_message.len > "/provider ".len) {
            return .{ .provider = user_message["/provider ".len..] };
        }
        return .{ .provider = null };
    }
    if (eqlIgnoreCase(user_message, ":provider") or std.mem.startsWith(u8, user_message, ":provider ")) {
        if (user_message.len > ":provider ".len) {
            return .{ .provider = user_message[":provider ".len..] };
        }
        return .{ .provider = null };
    }

    if (eqlIgnoreCase(user_message, "/thinking") or std.mem.startsWith(u8, user_message, "/thinking ")) {
        if (user_message.len > "/thinking ".len) {
            return .{ .thinking = user_message["/thinking ".len..] };
        }
        return .{ .thinking = null };
    }
    if (eqlIgnoreCase(user_message, ":thinking") or std.mem.startsWith(u8, user_message, ":thinking ")) {
        if (user_message.len > ":thinking ".len) {
            return .{ .thinking = user_message[":thinking ".len..] };
        }
        return .{ .thinking = null };
    }

    if (eqlIgnoreCase(user_message, "/sessions") or eqlIgnoreCase(user_message, ":sessions"))
        return .sessions;

    if (eqlIgnoreCase(user_message, "/prune") or eqlIgnoreCase(user_message, ":prune"))
        return .prune;

    if (eqlIgnoreCase(user_message, "/skills") or eqlIgnoreCase(user_message, ":skills"))
        return .skills;

    if (eqlIgnoreCase(user_message, "/resume") or std.mem.startsWith(u8, user_message, "/resume ")) {
        if (user_message.len > "/resume ".len) {
            return .{ .resume_session = user_message["/resume ".len..] };
        }
        return .{ .resume_session = null };
    }
    if (eqlIgnoreCase(user_message, ":resume") or std.mem.startsWith(u8, user_message, ":resume ")) {
        if (user_message.len > ":resume ".len) {
            return .{ .resume_session = user_message[":resume ".len..] };
        }
        return .{ .resume_session = null };
    }

    if (eqlIgnoreCase(user_message, "/file") or std.mem.startsWith(u8, user_message, "/file ")) {
        if (user_message.len > "/file ".len) {
            return .{ .file = user_message["/file ".len..] };
        }
        return .{ .file = null };
    }
    if (eqlIgnoreCase(user_message, ":file") or std.mem.startsWith(u8, user_message, ":file ")) {
        if (user_message.len > ":file ".len) {
            return .{ .file = user_message[":file ".len..] };
        }
        return .{ .file = null };
    }

    if (eqlIgnoreCase(user_message, "/help") or eqlIgnoreCase(user_message, ":help"))
        return .help;

    if (user_message.len > 0 and user_message[0] == '/' or user_message.len > 0 and user_message[0] == ':')
        return .{ .skill = user_message[1..] };

    return .{ .prompt = user_message };
}

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
            try ctx.messages.append(ctx.messages_alloc, .{ .user = try ctx.messages_alloc.dupe(u8, text) });
            return .run_chat_turn;
        },
    }
}

test "parse recognizes all slash commands" {
    try std.testing.expectEqual(Command.quit, parse("/quit"));
    try std.testing.expectEqual(Command.quit, parse("/exit"));
    try std.testing.expectEqual(Command.reset, parse("/reset"));
    try std.testing.expectEqual(Command.reset, parse("/new"));
    try std.testing.expectEqual(Command.stats, parse("/stats"));
    try std.testing.expectEqual(Command.config, parse("/config"));
    try std.testing.expectEqual(Command.sessions, parse("/sessions"));
    try std.testing.expectEqual(Command.prune, parse("/prune"));
    try std.testing.expectEqual(Command.skills, parse("/skills"));

    try std.testing.expectEqualDeep(Command{ .resume_session = null }, parse("/resume"));
    try std.testing.expectEqualDeep(Command{ .resume_session = "abc-123" }, parse("/resume abc-123"));

    try std.testing.expectEqualDeep(Command{ .plan = null }, parse("/plan"));
    try std.testing.expectEqualDeep(Command{ .plan = "do thing" }, parse("/plan do thing"));

    try std.testing.expectEqualDeep(Command{ .build = null }, parse("/build"));
    try std.testing.expectEqualDeep(Command{ .build = "code it" }, parse("/build code it"));

    try std.testing.expectEqualDeep(Command{ .model = null }, parse("/model"));
    try std.testing.expectEqualDeep(Command{ .model = "llama" }, parse("/model llama"));

    try std.testing.expectEqualDeep(Command{ .provider = null }, parse("/provider"));
    try std.testing.expectEqualDeep(Command{ .provider = "opencode" }, parse("/provider opencode"));

    try std.testing.expectEqualDeep(Command{ .thinking = null }, parse("/thinking"));
    try std.testing.expectEqualDeep(Command{ .thinking = "high" }, parse("/thinking high"));
    try std.testing.expectEqualDeep(Command{ .thinking = null }, parse(":thinking"));
    try std.testing.expectEqualDeep(Command{ .thinking = "low" }, parse(":thinking low"));

    try std.testing.expectEqualDeep(Command{ .skill = "grill-me" }, parse("/grill-me"));
    try std.testing.expectEqualDeep(Command{ .skill = "nano-commits" }, parse("/nano-commits"));

    try std.testing.expectEqualDeep(Command{ .prompt = "hello" }, parse("hello"));
}

test "parse recognizes the file command before the skill fallback" {
    try std.testing.expectEqualDeep(Command{ .file = null }, parse("/file"));
    try std.testing.expectEqualDeep(Command{ .file = "spec.md" }, parse("/file spec.md"));
    try std.testing.expectEqualDeep(Command{ .file = "https://example.com/prompt.md" }, parse("/file https://example.com/prompt.md"));
}

test "every registered command token parses as a command" {
    for (command_tokens) |token| {
        const cmd = parse(token);
        try std.testing.expect(cmd != .prompt);
        try std.testing.expect(cmd != .skill);
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
    var messages = std.ArrayList(openai.Message).empty;
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
        .messages = &messages,
        .planning_mode = &planning_mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqual(Action.continue_, action);
    try std.testing.expect(std.mem.containsAtLeast(u8, out.written(), 1, "Usage: /file"));
}
