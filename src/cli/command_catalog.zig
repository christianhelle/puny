//! Single source of truth for the slash commands that autocomplete offers.
//!
//! `parser.zig` decides what a typed line means; this catalog decides what the
//! prompt suggests. The tests below tie the two together, so a command added to
//! one without the other fails the build.

const std = @import("std");
const parser = @import("parser.zig");

pub const Completion = struct {
    /// Name as displayed and inserted, including the leading slash.
    name: []const u8,
    /// Argument hint shown next to the name, or "" when the command takes none.
    hint: []const u8,
    /// One-line description shown to the right.
    description: []const u8,
    /// True when accepting the entry should append a trailing space.
    ///
    /// `parse("/quit ")` does not match `/quit` and falls through to the skill
    /// branch, so a blanket trailing space would silently break every command
    /// that takes no argument.
    takes_arg: bool,
};

/// Commands in `/help` display order. Aliases (`/exit`, `/new`) are omitted:
/// they would only duplicate a description, and they still work when typed.
pub const command_completions = [_]Completion{
    .{ .name = "/quit", .hint = "", .description = "Exit Puny", .takes_arg = false },
    .{ .name = "/reset", .hint = "", .description = "New session", .takes_arg = false },
    .{ .name = "/stats", .hint = "", .description = "Show session statistics", .takes_arg = false },
    .{ .name = "/compact", .hint = "", .description = "Summarize the conversation to free context", .takes_arg = false },
    .{ .name = "/edit", .hint = "", .description = "Remove a message or rewind the conversation", .takes_arg = false },
    .{ .name = "/context", .hint = "[n|tier]", .description = "Show context usage or set its limit or tier", .takes_arg = true },
    .{ .name = "/config", .hint = "", .description = "Reconfigure URL and API key", .takes_arg = false },
    .{ .name = "/plan", .hint = "[task]", .description = "Enter planning mode", .takes_arg = true },
    .{ .name = "/build", .hint = "[task]", .description = "Switch to build mode", .takes_arg = true },
    .{ .name = "/review", .hint = "", .description = "Review the current branch", .takes_arg = false },
    .{ .name = "/orchestrate", .hint = "[task]", .description = "Implement, review, and fix until merge worthy", .takes_arg = true },
    .{ .name = "/model", .hint = "[id]", .description = "Switch to another model", .takes_arg = true },
    .{ .name = "/provider", .hint = "[id]", .description = "Open the provider picker", .takes_arg = true },
    .{ .name = "/thinking", .hint = "[level]", .description = "Change reasoning effort", .takes_arg = true },
    .{ .name = "/sessions", .hint = "", .description = "List saved sessions", .takes_arg = false },
    .{ .name = "/resume", .hint = "[id]", .description = "Resume a saved session", .takes_arg = true },
    .{ .name = "/prune", .hint = "", .description = "Remove old sessions", .takes_arg = false },
    .{ .name = "/skills", .hint = "", .description = "List global and repository skills", .takes_arg = false },
    .{ .name = "/file", .hint = "[path|url]", .description = "Load a prompt from a file or URL", .takes_arg = true },
    .{ .name = "/help", .hint = "", .description = "Show this help message", .takes_arg = false },
};

/// The catalog entry for `name`, or null when the command takes no completion.
pub fn findCompletion(name: []const u8) ?Completion {
    for (command_completions) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

test "every completable command token is in the catalog" {
    for (parser.command_tokens) |token| {
        if (parser.isAlias(token)) continue;
        if (findCompletion(token) == null) {
            std.debug.print("missing catalog entry for {s}\n", .{token});
            return error.TestFailed;
        }
    }
}

test "every catalog entry parses as its own command" {
    for (command_completions) |entry| {
        const cmd = parser.parse(entry.name);
        try std.testing.expect(cmd != .prompt);
        try std.testing.expect(cmd != .skill);
    }
}

test "takes_arg marks every command whose trailing text stays a command" {
    const allocator = std.testing.allocator;
    for (command_completions) |entry| {
        const with_text = try std.fmt.allocPrint(allocator, "{s} x", .{entry.name});
        defer allocator.free(with_text);

        const bare = parser.parse(entry.name);
        const with_arg = parser.parse(with_text);
        if (entry.takes_arg) {
            try std.testing.expect(std.meta.activeTag(bare) == std.meta.activeTag(with_arg));
            if (payloadOf(with_arg) == null) {
                std.debug.print("takes_arg but no payload: {s}\n", .{entry.name});
                return error.TestFailed;
            }
        } else {
            // Anything after the name, a stray trailing space included, makes
            // the line fall through to the skill branch: this is why accepting
            // these commands must not append a space.
            try std.testing.expect(with_arg == .skill);
        }
    }
}

fn payloadOf(cmd: parser.Command) ?[]const u8 {
    return switch (cmd) {
        .context => |v| v,
        .plan => |v| v,
        .build => |v| v,
        .orchestrate => |v| v,
        .model => |v| v,
        .provider => |v| v,
        .thinking => |v| v,
        .resume_session => |v| v,
        .file => |v| v,
        else => null,
    };
}

test "the catalog lists each command once" {
    for (command_completions, 0..) |entry, i| {
        for (command_completions[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, entry.name, other.name));
        }
    }
}

test "findCompletion returns the entry for a known command" {
    const entry = findCompletion("/model").?;
    try std.testing.expectEqualStrings("/model", entry.name);
    try std.testing.expectEqualStrings("[id]", entry.hint);
    try std.testing.expect(entry.takes_arg);
    try std.testing.expect(findCompletion("/nope") == null);
}
