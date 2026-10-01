const std = @import("std");
const ansi = @import("ansi.zig");
const openai = @import("../providers/openai.zig");
const version = @import("../version.zig");
const help = @import("help.zig");
const token_stats = @import("token_stats.zig");

pub const Info = struct {
    provider_name: []const u8,
    provider_url: []const u8,
    model_key: []const u8,
    reasoning_effort: ?openai.ReasoningEffort = null,
    /// The model's whole context window, shown after the effort when known.
    context_window: ?usize = null,
    session_id: []const u8 = "",
    oneshot: bool = false,
    prefilled: bool = false,
};

/// Writes a model as `id - effort - window`, leaving out a default effort
/// and an unknown window, e.g. `gpt-6-luna - max - 400K`.
pub fn writeModel(writer: *std.Io.Writer, model_key: []const u8, reasoning_effort: ?openai.ReasoningEffort, context_window: ?usize) !void {
    try writer.print("{s}", .{model_key});
    if (reasoning_effort) |effort| {
        if (effort != .default) {
            try writer.print(" - {s}{s}{s}", .{ ansi.bold_start, @tagName(effort), ansi.bold_end });
        }
    }
    if (context_window) |tokens| {
        var buf: [16]u8 = undefined;
        try writer.print(" - {s}", .{token_stats.formatContextSize(&buf, tokens)});
    }
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
    try writer.print("  {s}Model:{s}    ", .{ ansi.bright, ansi.reset });
    try writeModel(writer, info.model_key, info.reasoning_effort, info.context_window);

    if (!info.oneshot and !info.prefilled) {
        // End the model line before the list and leave a blank line after it.
        try writer.print("\n", .{});
        try help.showHelp(writer);
        try writer.print("\n", .{});
    } else {
        try writer.print("\n\n", .{});
    }

    if (info.session_id.len > 0) {
        try writer.print("{s}Session:{s} {s}\n", .{ ansi.dim, ansi.reset, info.session_id });
    }

    try writer.flush();
}

pub fn printSummary(writer: *std.Io.Writer, info: Info) !void {
    try writer.print("\n", .{});
    try writer.print("  {s}Provider:{s} {s} ({s})\n", .{ ansi.bright, ansi.reset, info.provider_name, info.provider_url });
    try writer.print("  {s}Model:{s}    ", .{ ansi.bright, ansi.reset });
    try writeModel(writer, info.model_key, info.reasoning_effort, info.context_window);
    try writer.print("\n", .{});
    try writer.print("\n", .{});
    try writer.flush();
}

test "print writes banner, provider, model and commands" {
    const allocator = std.testing.allocator;
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    try print(&out.writer, .{
        .provider_name = "LM Studio",
        .provider_url = "http://127.0.0.1:1234",
        .model_key = "test-model",
        .session_id = "abc-123",
    });

    const text = out.written();
    try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, "Welcome to Puny"));
    try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, "LM Studio"));
    try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, "http://127.0.0.1:1234"));
    try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, "test-model"));
    try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, "abc-123"));
    try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, "/quit, /exit"));
    try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, "/config"));
    try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, "/plan"));
    try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, "/provider"));
}

test "banner lists every registered command" {
    const commands = @import("../cli/commands.zig");
    const allocator = std.testing.allocator;
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    try print(&out.writer, .{
        .provider_name = "LM Studio",
        .provider_url = "http://127.0.0.1:1234",
        .model_key = "test-model",
    });

    const text = out.written();
    for (commands.command_tokens) |token| {
        try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, token));
    }
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

test "prefilled prompt mode omits available commands" {
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
    try std.testing.expect(!std.mem.containsAtLeast(u8, text, 1, "/quit, /exit"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, text, 1, "Available commands:"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, text, 1, "Type a prompt"));
}

test "prefilled prompt mode terminates the model line before session id" {
    const allocator = std.testing.allocator;
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    try print(&out.writer, .{
        .provider_name = "OpenCode Go",
        .provider_url = "https://opencode.ai/zen/go",
        .model_key = "deepseek-v4-pro",
        .session_id = "5492cc96",
        .prefilled = true,
    });

    const text = out.written();
    try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, "5492cc96"));
    try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, "\n\x1b[2mSession:"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, text, 1, "pro\x1b[2mSession:"));
}

test "oneshot mode terminates the model line before session id" {
    const allocator = std.testing.allocator;
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    try print(&out.writer, .{
        .provider_name = "Mock",
        .provider_url = "-",
        .model_key = "mock-model",
        .session_id = "abc-123",
        .oneshot = true,
    });

    const text = out.written();
    try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, "abc-123"));
    try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, "\n\x1b[2mSession:"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, text, 1, "model\x1b[2mSession:"));
}

test "print shows reasoning effort when non-default" {
    const allocator = std.testing.allocator;

    {
        var out = std.Io.Writer.Allocating.init(allocator);
        defer out.deinit();
        try print(&out.writer, .{
            .provider_name = "Test",
            .provider_url = "http://localhost",
            .model_key = "deepseek-v4-pro",
            .reasoning_effort = .high,
        });
        try std.testing.expect(std.mem.containsAtLeast(u8, out.written(), 1, " - \x1b[1mhigh\x1b[22m"));
    }

    {
        var out = std.Io.Writer.Allocating.init(allocator);
        defer out.deinit();
        try print(&out.writer, .{
            .provider_name = "Test",
            .provider_url = "http://localhost",
            .model_key = "deepseek-v4-pro",
            .reasoning_effort = .xhigh,
        });
        try std.testing.expect(std.mem.containsAtLeast(u8, out.written(), 1, " - \x1b[1mxhigh\x1b[22m"));
    }
}

test "print and printSummary show the context window after the effort" {
    const allocator = std.testing.allocator;
    const info = Info{
        .provider_name = "GitHub Copilot",
        .provider_url = "https://api.githubcopilot.com",
        .model_key = "gpt-6-luna",
        .reasoning_effort = .max,
        .context_window = 400000,
    };

    var banner = std.Io.Writer.Allocating.init(allocator);
    defer banner.deinit();
    try print(&banner.writer, info);
    try std.testing.expect(std.mem.containsAtLeast(u8, banner.written(), 1, "gpt-6-luna - \x1b[1mmax\x1b[22m - 400K\n"));

    var summary = std.Io.Writer.Allocating.init(allocator);
    defer summary.deinit();
    try printSummary(&summary.writer, info);
    try std.testing.expect(std.mem.containsAtLeast(u8, summary.written(), 1, "gpt-6-luna - \x1b[1mmax\x1b[22m - 400K\n"));
}

test "writeModel shows the window even with the default effort" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeModel(&out.writer, "gpt-6-luna", .default, 1000000);
    try std.testing.expectEqualStrings("gpt-6-luna - 1M", out.written());
}

test "print omits reasoning effort when default" {
    const allocator = std.testing.allocator;
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    try print(&out.writer, .{
        .provider_name = "Test",
        .provider_url = "http://localhost",
        .model_key = "deepseek-v4-pro",
        .reasoning_effort = .default,
    });

    const text = out.written();
    try std.testing.expect(!std.mem.containsAtLeast(u8, text, 1, " - \x1b[1m"));
}

test "printSummary shows reasoning effort when non-default" {
    const allocator = std.testing.allocator;
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    try printSummary(&out.writer, .{
        .provider_name = "Test",
        .provider_url = "http://localhost",
        .model_key = "deepseek-v4-pro",
        .reasoning_effort = .high,
    });

    try std.testing.expect(std.mem.containsAtLeast(u8, out.written(), 1, " - \x1b[1mhigh\x1b[22m"));
}

test "printSummary omits a default reasoning effort and prints a blank line" {
    const allocator = std.testing.allocator;
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    try @call(.never_inline, printSummary, .{ &out.writer, @as(Info, .{
        .provider_name = "Test",
        .provider_url = "http://localhost",
        .model_key = "m",
    }) });

    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, " - \x1b[1m") == null);
    try std.testing.expect(std.mem.endsWith(u8, text, "\n\n"));
}

test "print renders a full banner out of line for coverage" {
    const allocator = std.testing.allocator;
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    try @call(.never_inline, print, .{ &out.writer, @as(Info, .{
        .provider_name = "Test",
        .provider_url = "http://localhost",
        .model_key = "m",
        .reasoning_effort = .low,
        .session_id = "sess-1",
    }) });

    const text = out.written();
    try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, "Welcome to Puny"));
    try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, "sess-1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, text, 1, " - \x1b[1mlow\x1b[22m"));
}

test "print keeps one blank line around the command list" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try print(&out.writer, .{
        .provider_name = "Mock",
        .provider_url = "-",
        .model_key = "test-model",
        .session_id = "abc-123",
    });

    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "test-model\n\n" ++ ansi.yellow ++ "Available commands:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "prompt.\n\n" ++ ansi.dim ++ "Session:") != null);
}
