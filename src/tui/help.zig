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
    try printCommand(writer, "/model [id]", "Switch to another model");
    try printCommand(writer, "/provider [name]", "Switch to another provider");
    try printCommand(writer, "/sessions", "List saved sessions");
    try printCommand(writer, "/resume [id]", "Resume a saved session");
    try printCommand(writer, "/prune", "Remove old sessions");
    try printCommand(writer, "/skills", "List global and repository skills");
    try printCommand(writer, "/file [path|url]", "Load a prompt from a file or URL");
    try writer.print("\n", .{});
    try writer.flush();
}

fn printCommand(writer: *std.Io.Writer, name: []const u8, description: []const u8) !void {
    const pad = if (name.len >= command_column_width) "" else command_padding[name.len..];
    try writer.print("  {s}{s}{s}{s} {s}\n", .{ ansi.green, name, ansi.reset, pad, description });
}
