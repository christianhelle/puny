const std = @import("std");
const helpers = @import("../tools/helpers.zig");

/// Upper bound on a single attached file's size. Larger files are skipped
/// rather than blowing up the prompt.
pub const max_attachment_bytes = 64 * 1024;

/// Scans `text` for `@path` mentions and returns the referenced paths (without
/// the leading `@`). An `@` only starts a mention when it appears at the start
/// of the text or immediately after whitespace, matching how the picker inserts
/// mentions. Paths are delimited by whitespace. The returned slice and each
/// path are owned by `allocator`.
pub fn extractRefs(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var refs: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (refs.items) |r| allocator.free(r);
        refs.deinit(allocator);
    }

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '@' and (i == 0 or std.ascii.isWhitespace(text[i - 1]))) {
            const start = i + 1;
            var end = start;
            while (end < text.len and !std.ascii.isWhitespace(text[end])) end += 1;
            if (end > start) {
                try refs.append(allocator, try allocator.dupe(u8, text[start..end]));
            }
            i = end;
        } else {
            i += 1;
        }
    }
    return refs.toOwnedSlice(allocator);
}

fn appendAttachment(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    path: []const u8,
    content: []const u8,
) !void {
    try buf.appendSlice(allocator, "\n\n@");
    try buf.appendSlice(allocator, path);
    try buf.appendSlice(allocator, "\n```\n");
    try buf.appendSlice(allocator, content);
    if (content.len == 0 or content[content.len - 1] != '\n') {
        try buf.append(allocator, '\n');
    }
    try buf.appendSlice(allocator, "```\n");
}

/// Resolves `@path` mentions in `text` to the contents of the referenced files
/// and returns the full prompt with those contents appended. Mentions whose
/// files cannot be read are skipped. If no mention resolves to readable file
/// content, the text is returned unchanged.
pub fn buildAttachedMessage(allocator: std.mem.Allocator, io: std.Io, text: []const u8) ![]const u8 {
    const refs = try extractRefs(allocator, text);
    defer {
        for (refs) |r| allocator.free(r);
        allocator.free(refs);
    }

    if (refs.len == 0) return try allocator.dupe(u8, text);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, text);

    var attached: usize = 0;
    for (refs) |path| {
        const content = helpers.readFileAlloc(allocator, io, path, max_attachment_bytes) catch continue;
        defer allocator.free(content);
        try appendAttachment(&buf, allocator, path, content);
        attached += 1;
    }

    if (attached == 0) return try allocator.dupe(u8, text);
    return buf.toOwnedSlice(allocator);
}

test "extractRefs returns nothing when there are no mentions" {
    const refs = try extractRefs(std.testing.allocator, "hello world");
    defer {
        for (refs) |r| std.testing.allocator.free(r);
        std.testing.allocator.free(refs);
    }
    try std.testing.expectEqual(@as(usize, 0), refs.len);
}

test "extractRefs finds a mention after whitespace" {
    const refs = try extractRefs(std.testing.allocator, "review @src/main.zig please");
    defer {
        for (refs) |r| std.testing.allocator.free(r);
        std.testing.allocator.free(refs);
    }
    try std.testing.expectEqual(@as(usize, 1), refs.len);
    try std.testing.expectEqualStrings("src/main.zig", refs[0]);
}

test "extractRefs finds a mention at the start of the text" {
    const refs = try extractRefs(std.testing.allocator, "@README.md is important");
    defer {
        for (refs) |r| std.testing.allocator.free(r);
        std.testing.allocator.free(refs);
    }
    try std.testing.expectEqual(@as(usize, 1), refs.len);
    try std.testing.expectEqualStrings("README.md", refs[0]);
}

test "extractRefs finds multiple mentions" {
    const refs = try extractRefs(std.testing.allocator, "see @a.txt and @b.txt now");
    defer {
        for (refs) |r| std.testing.allocator.free(r);
        std.testing.allocator.free(refs);
    }
    try std.testing.expectEqual(@as(usize, 2), refs.len);
    try std.testing.expectEqualStrings("a.txt", refs[0]);
    try std.testing.expectEqualStrings("b.txt", refs[1]);
}

test "extractRefs ignores email addresses" {
    const refs = try extractRefs(std.testing.allocator, "mail me at foo@bar.com");
    defer {
        for (refs) |r| std.testing.allocator.free(r);
        std.testing.allocator.free(refs);
    }
    try std.testing.expectEqual(@as(usize, 0), refs.len);
}

test "extractRefs ignores a trailing @ with no path" {
    const refs = try extractRefs(std.testing.allocator, "what about @");
    defer {
        for (refs) |r| std.testing.allocator.free(r);
        std.testing.allocator.free(refs);
    }
    try std.testing.expectEqual(@as(usize, 0), refs.len);
}

test "buildAttachedMessage returns text unchanged when there are no mentions" {
    const out = try buildAttachedMessage(std.testing.allocator, std.testing.io, "plain prompt");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("plain prompt", out);
}

test "buildAttachedMessage returns text unchanged when the file is missing" {
    const out = try buildAttachedMessage(std.testing.allocator, std.testing.io, "check @does-not-exist.txt");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("check @does-not-exist.txt", out);
}

test "buildAttachedMessage appends the referenced file contents" {
    const path = "puny-test-attachments.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    try helpers.writeFile(std.testing.io, path, "file body\n");

    const out = try buildAttachedMessage(std.testing.allocator, std.testing.io, "look at @puny-test-attachments.txt");
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.startsWith(u8, out, "look at @puny-test-attachments.txt"));
    try std.testing.expect(std.mem.indexOf(u8, out, "\n\n@puny-test-attachments.txt\n```\nfile body\n```\n") != null);
}
