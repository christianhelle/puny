const std = @import("std");
const ansi = @import("../tui/ansi.zig");
const attachments = @import("../chat/attachments.zig");
const config = @import("../config/config.zig");
const openai = @import("../providers/openai.zig");
const prompts = @import("../prompts/prompts.zig");
const parser = @import("parser.zig");
const AgentMode = @import("../core/mode.zig").AgentMode;

const Command = parser.Command;
const default_cfg = config.Config.default();
const prd_hint_prefix = "Session PRD path: ";
const build_notice = "Planning mode has ended and you are now in build mode. Earlier instructions not to write files or make changes no longer apply: implement the plan.";

pub const Action = union(enum) {
    exit,
    continue_,
    full_reset,
    run_chat_turn,
    print_stats,
    compact,
    set_context: ?[]const u8,
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
    begin_review,
    begin_orchestrate: []const u8,
    help,
};

pub const Context = struct {
    arena: std.mem.Allocator,
    messages_alloc: std.mem.Allocator,
    messages_arena: *std.heap.ArenaAllocator,
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    messages: *std.ArrayList(openai.Message),
    mode: *AgentMode,
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

        .compact => return .compact,

        .context => |limit| return .{ .set_context = limit },

        .config => return .reconfigure,

        .plan => |text| {
            ctx.mode.* = .planning;
            const planning_prompt = try ctx.cfg.resolvePrompt(ctx.messages_alloc, "planning", prompts.planning);
            try ctx.messages.append(ctx.messages_alloc, .{ .system = planning_prompt });
            if (ctx.session_prd_path.len > 0) {
                const prd_hint = try std.fmt.allocPrint(ctx.messages_alloc, prd_hint_prefix ++ "{s}. Use the save_prd tool when ready to write the final PRD.", .{ctx.session_prd_path});
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
            ctx.mode.* = .build;
            try dropPlanningInstructions(ctx);
            try ctx.messages.append(ctx.messages_alloc, .{ .system = build_notice });
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

        .review => return .begin_review,
        .orchestrate => |text| return .{ .begin_orchestrate = text orelse "" },

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

/// Removes the system messages `/plan` installed. Providers such as Anthropic
/// fold every system message into one prompt, so a lingering "MUST NOT write
/// files" instruction would keep the model planning after `/build`. A resumed
/// session replays the prompt it was saved with, so the built-in prompt is
/// matched inside any prefix or suffix. A custom override from an older config
/// cannot be recognized; the build notice appended afterwards overrides it.
fn dropPlanningInstructions(ctx: Context) !void {
    const planning_prompt = try ctx.cfg.resolvePrompt(ctx.arena, "planning", prompts.planning);
    defer ctx.arena.free(planning_prompt);
    var i: usize = 0;
    while (i < ctx.messages.items.len) {
        const msg = ctx.messages.items[i];
        if (msg == .system and isStaleModeInstruction(msg.system, planning_prompt)) {
            _ = ctx.messages.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

fn isStaleModeInstruction(content: []const u8, planning_prompt: []const u8) bool {
    return std.mem.eql(u8, content, planning_prompt) or
        std.mem.indexOf(u8, content, prompts.planning) != null or
        std.mem.startsWith(u8, content, prd_hint_prefix) or
        std.mem.eql(u8, content, build_notice);
}

test "dispatch quit returns exit" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var mode: AgentMode = .build;

    const action = try dispatch(.quit, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
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
    var mode: AgentMode = .build;

    const action = try dispatch(.reset, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
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
    var mode: AgentMode = .build;

    const action = try dispatch(.config, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
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
    var mode: AgentMode = .build;

    const action = try dispatch(.stats, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
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
    var mode: AgentMode = .build;

    const action = try dispatch(Command{ .plan = null }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqual(Action.continue_, action);
    try std.testing.expectEqual(.planning, mode);
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
    var mode: AgentMode = .build;

    const action = try dispatch(Command{ .plan = "do thing" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqual(Action.run_chat_turn, action);
    try std.testing.expectEqual(.planning, mode);
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
    var mode: AgentMode = .planning;

    const action = try dispatch(Command{ .build = null }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqual(Action.continue_, action);
    try std.testing.expectEqual(.build, mode);
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expectEqualDeep(openai.Message{ .system = build_notice }, messages.items[0]);
    try std.testing.expectEqualDeep(openai.Message{ .user = "Now implement the plan. Write all necessary code." }, messages.items[1]);
}

test "dispatch build with text switches to build mode and runs chat turn" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var mode: AgentMode = .planning;

    const action = try dispatch(Command{ .build = "now" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqual(Action.run_chat_turn, action);
    try std.testing.expectEqual(.build, mode);
    try std.testing.expectEqual(@as(usize, 3), messages.items.len);
    try std.testing.expectEqualDeep(openai.Message{ .system = build_notice }, messages.items[0]);
    try std.testing.expectEqualDeep(openai.Message{ .user = "Now implement the plan. Write all necessary code." }, messages.items[1]);
    try std.testing.expectEqualDeep(openai.Message{ .user = "now" }, messages.items[2]);
}

test "dispatch build drops the planning instructions from the conversation" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var mode: AgentMode = .build;
    const ctx: Context = .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
        .oneshot = false,
        .cfg = &default_cfg,
        .session_prd_path = "plan.md",
    };
    try messages.append(messages_arena_state.allocator(), .{ .system = "base prompt" });

    _ = try dispatch(Command{ .plan = "design it" }, ctx);
    try messages.append(messages_arena_state.allocator(), .{ .assistant = .{ .content = "PRD saved. Run /build implement" } });
    _ = try dispatch(Command{ .build = "implement" }, ctx);

    try std.testing.expectEqual(.build, mode);
    var system_count: usize = 0;
    for (messages.items) |msg| {
        if (msg != .system) continue;
        system_count += 1;
        try std.testing.expect(std.mem.indexOf(u8, msg.system, "PLANNING MODE") == null);
        try std.testing.expect(std.mem.indexOf(u8, msg.system, "Session PRD path") == null);
    }
    try std.testing.expectEqual(@as(usize, 2), system_count);
    try std.testing.expectEqualDeep(openai.Message{ .user = "design it" }, messages.items[1]);
    try std.testing.expectEqualDeep(openai.Message{ .user = "implement" }, messages.items[messages.items.len - 1]);
}

fn expectBuildNoticeAfterPlanning(messages: []const openai.Message, planning_text: []const u8) !void {
    var planning_at: ?usize = null;
    var notice_at: ?usize = null;
    var notice_count: usize = 0;
    for (messages, 0..) |msg, i| {
        if (msg != .system) continue;
        if (std.mem.indexOf(u8, msg.system, planning_text) != null) planning_at = i;
        if (std.mem.eql(u8, msg.system, build_notice)) {
            notice_at = i;
            notice_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), notice_count);
    if (planning_at) |p| try std.testing.expect(p < notice_at.?);
}

test "dispatch build drops a planning prompt saved with a different prefix" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var mode: AgentMode = .build;
    var saved_cfg = config.Config.default();
    saved_cfg.prompts.planning.prefix = "[old] ";
    var ctx: Context = .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
        .oneshot = false,
        .cfg = &saved_cfg,
    };

    _ = try dispatch(Command{ .plan = "design it" }, ctx);
    // A resumed session replays the saved prompt under the current config.
    ctx.cfg = &default_cfg;
    _ = try dispatch(Command{ .build = "implement" }, ctx);

    for (messages.items) |msg| {
        if (msg == .system) try std.testing.expect(std.mem.indexOf(u8, msg.system, "PLANNING MODE") == null);
    }
}

test "dispatch build overrides a planning prompt it cannot recognize" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var mode: AgentMode = .build;
    var saved_cfg = config.Config.default();
    saved_cfg.prompts.planning.override = "Custom planning rules: never write files.";
    var ctx: Context = .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
        .oneshot = false,
        .cfg = &saved_cfg,
    };

    _ = try dispatch(Command{ .plan = "design it" }, ctx);
    ctx.cfg = &default_cfg;
    _ = try dispatch(Command{ .build = "implement" }, ctx);
    _ = try dispatch(Command{ .build = "keep going" }, ctx);

    try expectBuildNoticeAfterPlanning(messages.items, "Custom planning rules");
}

test "dispatch model in oneshot mode rejects" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var mode: AgentMode = .build;

    const action = try dispatch(Command{ .model = "x" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
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
    var mode: AgentMode = .build;

    const action = try dispatch(Command{ .model = "llama" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
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
    var mode: AgentMode = .build;

    const action = try dispatch(Command{ .provider = "opencode" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
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
    var mode: AgentMode = .build;

    const action = try dispatch(Command{ .provider = "opencode" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
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
    var mode: AgentMode = .build;

    const action = try dispatch(Command{ .provider = null }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
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
    var mode: AgentMode = .build;

    const action = try dispatch(Command{ .thinking = "high" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
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
    var mode: AgentMode = .build;

    const action = try dispatch(Command{ .thinking = "high" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
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
    var mode: AgentMode = .build;

    const action = try dispatch(Command{ .thinking = null }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
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
    var mode: AgentMode = .build;

    const action = try dispatch(.sessions, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
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
    var mode: AgentMode = .build;

    const action = try dispatch(.prune, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
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
    var mode: AgentMode = .build;

    const action = try dispatch(Command{ .prompt = "hello" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
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
    var mode: AgentMode = .build;

    const action = try dispatch(Command{ .file = null }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
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
    var mode: AgentMode = .build;

    const action = try dispatch(Command{ .file = "spec.md" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
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
    var mode: AgentMode = .build;

    const action = try dispatch(Command{ .file = "  spec.md " }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
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
    var mode: AgentMode = .build;

    const action = try dispatch(Command{ .file = "   " }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
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
    var mode: AgentMode = .build;

    const action = try dispatch(Command{ .resume_session = "abc-1" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
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
    var mode: AgentMode = .build;

    const action = try dispatch(Command{ .resume_session = "abc-1" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
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
    var mode: AgentMode = .build;

    const action = try dispatch(.skills, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
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
    var mode: AgentMode = .build;

    const action = try dispatch(.help, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
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
    var mode: AgentMode = .build;

    const action = try dispatch(Command{ .plan = null }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
        .oneshot = false,
        .cfg = &default_cfg,
        .session_prd_path = "plan.md",
    });

    try std.testing.expectEqual(Action.continue_, action);
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expect(messages.items[1] == .system);
    try std.testing.expect(std.mem.indexOf(u8, messages.items[1].system, "Session PRD path: plan.md") != null);
}

test "dispatch review requests review preparation without changing mode" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var mode: AgentMode = .build;

    const action = try dispatch(.review, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqual(Action.begin_review, action);
    try std.testing.expectEqual(.build, mode);
}

test "dispatch orchestrate carries the argument text without changing mode" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var mode: AgentMode = .build;

    const action = try dispatch(Command{ .orchestrate = "--iterations 3 add csv export" }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqualDeep(Action{ .begin_orchestrate = "--iterations 3 add csv export" }, action);
    try std.testing.expectEqual(.build, mode);
    try std.testing.expectEqual(@as(usize, 0), messages.items.len);
}

test "dispatch orchestrate without text yields an empty spec" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var mode: AgentMode = .build;

    const action = try dispatch(Command{ .orchestrate = null }, .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
        .oneshot = false,
        .cfg = &default_cfg,
    });

    try std.testing.expectEqualDeep(Action{ .begin_orchestrate = "" }, action);
}

test "dispatch compact and context return their actions" {
    var messages_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena_state.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var mode: AgentMode = .build;
    const ctx: Context = .{
        .arena = std.testing.allocator,
        .messages_alloc = messages_arena_state.allocator(),
        .messages_arena = &messages_arena_state,
        .stdout_writer = &out.writer,
        .io = std.testing.io,
        .messages = &messages,
        .mode = &mode,
        .oneshot = false,
        .cfg = &default_cfg,
    };

    try std.testing.expectEqual(Action.compact, try dispatch(.compact, ctx));
    try std.testing.expectEqualDeep(Action{ .set_context = "off" }, try dispatch(.{ .context = "off" }, ctx));
    try std.testing.expectEqualDeep(Action{ .set_context = null }, try dispatch(.{ .context = null }, ctx));
}
