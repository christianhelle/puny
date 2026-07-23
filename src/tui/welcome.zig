const std = @import("std");
const ansi = @import("ansi.zig");
const version = @import("../version.zig");

pub const Info = struct {
    provider_name: []const u8,
    provider_url: []const u8,
    model_key: []const u8,
    oneshot: bool = false,
    prefilled: bool = false,
};

const command_column_width = 18;
const command_padding = "                  "[0..command_column_width];

fn printCommand(writer: *std.Io.Writer, name: []const u8, description: []const u8) !void {
    const pad = if (name.len >= command_column_width) "" else command_padding[name.len..];
    try writer.print("  {s}{s}{s}{s} {s}\n", .{ ansi.green, name, ansi.reset, pad, description });
}

pub fn print(writer: *std.Io.Writer, info: Info) !void {
    var buf: [256]u8 = undefined;
    const version_line = version.format(&buf);

    try writer.print("\n", .{});
    try writer.print(
        "{s}Welcome to Puny {s}{s} - {s}Your tiny AI coding assistant{s}\n",
        .{ ansi.cyan, version_line, ansi.reset, ansi.dim, ansi.reset },
    );
    try writer.print("{s}AI makes mistakes - read the fucking code{s}\n", .{ ansi.dim, ansi.reset });
    try writer.print("\n", .{});

    try writer.print("  {s}Provider:{s} {s} ({s})\n", .{ ansi.bright, ansi.reset, info.provider_name, info.provider_url });
    try writer.print("  {s}Model:{s}    {s}\n", .{ ansi.bright, ansi.reset, info.model_key });
    try writer.print("\n", .{});

    if (!info.oneshot) {
        try writer.print("{s}Available commands:{s}\n", .{ ansi.yellow, ansi.reset });
        try printCommand(writer, "/quit, /exit", "Exit Puny");
        try printCommand(writer, "/reset", "Clear the conversation");
        try printCommand(writer, "/stats", "Show session statistics");
        try printCommand(writer, "/config", "Reconfigure URL and API key");
        try printCommand(writer, "/plan [task]", "Enter planning mode");
        try printCommand(writer, "/build [task]", "Switch to build mode");
        try printCommand(writer, "/model [id]", "Switch to another model");
        try printCommand(writer, "/provider [name]", "Switch to another provider");
        try printCommand(writer, "/skills", "List global and repository skills");
        try writer.print("\n", .{});
        if (info.prefilled) {
            try writer.print("{s}Prefilled prompt will be sent automatically. Type /quit to exit.{s}\n", .{ ansi.dim, ansi.reset });
        } else {
            try writer.print("{s}Type a prompt and press Enter to start chatting.{s}\n", .{ ansi.dim, ansi.reset });
        }
    }

    try writer.flush();
}

pub fn printSummary(writer: *std.Io.Writer, info: Info) !void {
    try writer.print("\n", .{});
    try writer.print("  {s}Provider:{s} {s} ({s})\n", .{ ansi.bright, ansi.reset, info.provider_name, info.provider_url });
    try writer.print("  {s}Model:{s}    {s}\n", .{ ansi.bright, ansi.reset, info.model_key });
    try writer.print("\n", .{});
    try writer.flush();
}

test "print writes banner, provider, model, commands and hint" {
    const allocator = std.testing.allocator;
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    try print(&out.writer, .{
        .provider_name = "LM Studio",
        .provider_url = "http://127.0.0.1:1234",
        .model_key = "test-model",
    });

    const text = out.written();
    try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, "Welcome to Puny"));
    try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, "LM Studio"));
    try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, "http://127.0.0.1:1234"));
    try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, "test-model"));
    try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, "/quit, /exit"));
    try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, "/config"));
    try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, "/plan"));
    try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, "/provider"));
    try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, "Type a prompt"));
}

test "oneshot mode omits interactive commands" {
    const allocator = std.testing.allocator;
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    try print(&out.writer, .{
        .provider_name = "Mock",
        .provider_url = "-",
        .model_key = "mock-model",
        .oneshot = true,
    });

    const text = out.written();
    try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, "Welcome to Puny"));
    try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, "mock-model"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, text, 1, "/quit"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, text, 1, "Type a prompt"));
}

test "prefilled prompt mode shows automatic submission hint" {
    const allocator = std.testing.allocator;
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    try print(&out.writer, .{
        .provider_name = "LM Studio",
        .provider_url = "http://127.0.0.1:1234",
        .model_key = "test-model",
        .prefilled = true,
    });

    const text = out.written();
    try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, "Welcome to Puny"));
    try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, "/quit, /exit"));
    try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, "Prefilled prompt will be sent automatically"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, text, 1, "Type a prompt"));
}
