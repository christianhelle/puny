const std = @import("std");
const ansi = @import("ansi.zig");

const command_column_width = 18;
const command_padding = "                  "[0..command_column_width];

pub fn showHelp(writer: *std.Io.Writer) !void {
    try writer.print("\n\n{s}Available commands:{s}\n", .{ ansi.yellow, ansi.reset });
    try printCommand(writer, "/quit, /exit", "Exit Puny");
    try printCommand(writer, "/new, /reset", "New session");
    try printCommand(writer, "/stats", "Show session statistics");
    try printCommand(writer, "/config", "Reconfigure URL and API key");
    try printCommand(writer, "/plan [task]", "Enter planning mode");
    try printCommand(writer, "/build [task]", "Switch to build mode");
    try printCommand(writer, "/review", "Review the current branch");
    try printCommand(writer, "/orchestrate [task]", "Implement, review, and fix until merge worthy");
    try printCommand(writer, "/model [id]", "Switch to another model");
    try printCommand(writer, "/provider [name]", "Switch to another provider");
    try printCommand(writer, "/thinking [level]", "Change reasoning effort");
    try printCommand(writer, "/sessions", "List saved sessions");
    try printCommand(writer, "/resume [id]", "Resume a saved session");
    try printCommand(writer, "/prune", "Remove old sessions");
    try printCommand(writer, "/skills", "List global and repository skills");
    try printCommand(writer, "/file [path|url]", "Load a prompt from a file or URL");
    try printCommand(writer, "/help", "Show this help message");
    try printCommand(writer, "@path", "Attach a file to the prompt");
    try writer.print("\n{s}Tip:{s} Type @ to search and attach files to your prompt.\n", .{ ansi.yellow, ansi.reset });
    try writer.print("\n", .{});
    try writer.flush();
}

fn printCommand(writer: *std.Io.Writer, name: []const u8, description: []const u8) !void {
    const pad = if (name.len >= command_column_width) "" else command_padding[name.len..];
    try writer.print("  {s}{s}{s}{s} {s}\n", .{ ansi.green, name, ansi.reset, pad, description });
}

test "showHelp lists all commands" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var output = std.Io.Writer.Allocating.init(arena);
    defer output.deinit();

    try showHelp(&output.writer);
    const text = output.written();

    const commands = [_][]const u8{
        "/quit, /exit",  "/new, /reset", "/stats",      "/config",          "/plan [task]",
        "/build [task]", "/review",      "/model [id]", "/provider [name]", "/thinking [level]",
        "/sessions",     "/resume [id]", "/prune",      "/skills",          "/file [path|url]",
        "/orchestrate [task]",
        "/help",         "@path",
    };
    for (commands) |command| {
        try std.testing.expect(std.mem.indexOf(u8, text, command) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, text, "Available commands:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Exit Puny") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Type @ to search and attach files") != null);
}

test "printCommand pads short command names to the column width" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var output = std.Io.Writer.Allocating.init(arena);
    defer output.deinit();

    try printCommand(&output.writer, "/stats", "Show session statistics");
    // "/stats" (6 chars) padded with 12 spaces to reach the 18-column width.
    try std.testing.expectEqualStrings("  \x1b[32m/stats\x1b[0m             Show session statistics\n", output.written());
}

test "printCommand does not pad an exactly 18-byte command name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var output = std.Io.Writer.Allocating.init(arena);
    defer output.deinit();

    // "/provider [name]xy" is exactly command_column_width bytes; no padding
    // may appear before the description.
    try printCommand(&output.writer, "/provider [name]xy", "Desc");
    try std.testing.expectEqualStrings("  \x1b[32m/provider [name]xy\x1b[0m Desc\n", output.written());
}

test "printCommand does not pad long command names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var output = std.Io.Writer.Allocating.init(arena);
    defer output.deinit();

    try printCommand(&output.writer, "/provider [name] is long", "Desc");
    try std.testing.expectEqualStrings("  \x1b[32m/provider [name] is long\x1b[0m Desc\n", output.written());
}

test "showHelp renders the full command table when called out of line" {
    // Forces an out-of-line call so the function body cannot be attributed to
    // an inlined test instance.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var output = std.Io.Writer.Allocating.init(arena);
    defer output.deinit();

    try @call(.never_inline, showHelp, .{&output.writer});
    const text = output.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "/quit, /exit") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/plan [task]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "@path") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "\n"));
}
