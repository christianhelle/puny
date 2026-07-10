const std = @import("std");
const ansi = @import("ansi.zig");
const chat = @import("chat.zig");
const openai = @import("providers/openai.zig");
const prompts = @import("prompts.zig");

pub const Command = union(enum) {
    quit,
    reset,
    stats,
    plan: ?[]const u8,
    build: ?[]const u8,
    model: ?[]const u8,
    prompt: []const u8,
};

pub const Action = union(enum) {
    exit,
    continue_,
    run_chat_turn,
    switch_model: ?[]const u8,
};

pub const Context = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    messages: *std.array_list.Managed(openai.Message),
    planning_mode: *bool,
    oneshot: bool,
    session_stats: *chat.SessionStats,
};

pub fn parse(user_message: []const u8) Command {
    if (std.mem.eql(u8, user_message, "/quit") or std.mem.eql(u8, user_message, "/exit"))
        return .quit;

    if (std.mem.eql(u8, user_message, "/reset"))
        return .reset;

    if (std.mem.eql(u8, user_message, "/stats"))
        return .stats;

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

    return .{ .prompt = user_message };
}

pub fn dispatch(command: Command, ctx: Context) !Action {
    switch (command) {
        .quit => return .exit,

        .reset => {
            ctx.messages.clearRetainingCapacity();
            ctx.planning_mode.* = false;
            try ctx.messages.append(.{ .system = prompts.system });
            try ctx.stdout_writer.print("\nConversation reset.", .{});
            try ctx.stdout_writer.flush();
            return .continue_;
        },

        .stats => {
            try ctx.session_stats.print(ctx.io, ctx.stdout_writer);
            return .continue_;
        },

        .plan => |text| {
            ctx.planning_mode.* = true;
            try ctx.messages.append(.{ .system = prompts.planning });
            if (text) |t| {
                try ctx.messages.append(.{ .user = try ctx.arena.dupe(u8, t) });
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
                try ctx.messages.append(.{ .user = try ctx.arena.dupe(u8, t) });
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

        .prompt => |text| {
            try ctx.messages.append(.{ .user = try ctx.arena.dupe(u8, text) });
            return .run_chat_turn;
        },
    }
}
