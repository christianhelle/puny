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
            const message = try attachments.buildAttachedMessage(ctx.messages_alloc, ctx.io, text);
            try ctx.messages.append(ctx.messages_alloc, .{ .user = message });
            return .run_chat_turn;
        },
    }
}
