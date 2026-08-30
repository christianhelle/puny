const std = @import("std");

pub const Command = union(enum) {
    quit,
    reset,
    stats,
    config,
    plan: ?[]const u8,
    build: ?[]const u8,
    review,
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

/// Primary slash command tokens advertised in the welcome banner, in display order.
/// `parse` also accepts ':' variants and aliases such as `/exit`, `/new`, and `:help`.
pub const command_tokens = [_][]const u8{
    "/quit",
    "/exit",
    "/reset",
    "/new",
    "/stats",
    "/config",
    "/plan",
    "/build",
    "/review",
    "/model",
    "/provider",
    "/thinking",
    "/sessions",
    "/resume",
    "/prune",
    "/skills",
    "/file",
    "/help",
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

    if (eqlIgnoreCase(user_message, "/review") or eqlIgnoreCase(user_message, ":review"))
        return .review;

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
    try std.testing.expectEqualDeep(Command.review, parse("/review"));

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
