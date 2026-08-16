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

/// Returns a markdown code-fence length that is strictly longer than any run
/// of backticks in `content`, so a fence inside the content can never close
/// the enclosing fence early.
fn fenceLen(content: []const u8) usize {
    var longest: usize = 0;
    var run: usize = 0;
    for (content) |c| {
        if (c == '`') {
            run += 1;
            longest = @max(longest, run);
        } else {
            run = 0;
        }
    }
    return @max(3, longest + 1);
}

fn appendAttachment(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    path: []const u8,
    content: []const u8,
) !void {
    const fence = fenceLen(content);
    try buf.appendSlice(allocator, "\n\n@");
    try buf.appendSlice(allocator, path);
    try buf.append(allocator, '\n');
    try buf.appendNTimes(allocator, '`', fence);
    try buf.append(allocator, '\n');
    try buf.appendSlice(allocator, content);
    if (content.len == 0 or content[content.len - 1] != '\n') {
        try buf.append(allocator, '\n');
    }
    try buf.appendNTimes(allocator, '`', fence);
    try buf.append(allocator, '\n');
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

test "buildAttachedMessage uses a fence longer than any backtick run in the content" {
    const path = "puny-test-fence.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    try helpers.writeFile(std.testing.io, path, "x\n```\ny\n");

    const out = try buildAttachedMessage(std.testing.allocator, std.testing.io, "see @puny-test-fence.txt");
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\n````\n") != null);
}

test "fenceLen is strictly longer than any backtick run" {
    try std.testing.expectEqual(@as(usize, 3), fenceLen(""));
    try std.testing.expectEqual(@as(usize, 3), fenceLen("no backticks"));
    try std.testing.expectEqual(@as(usize, 3), fenceLen("a`b"));
    try std.testing.expectEqual(@as(usize, 4), fenceLen("```"));
    try std.testing.expectEqual(@as(usize, 5), fenceLen("````"));
    try std.testing.expectEqual(@as(usize, 4), fenceLen("x\n```\ny"));
    try std.testing.expectEqual(@as(usize, 4), fenceLen("``a```"));
}

test "extractRefs finds a mention at the end of the text" {
    const refs = try extractRefs(std.testing.allocator, "please look at @src/main.zig");
    defer {
        for (refs) |r| std.testing.allocator.free(r);
        std.testing.allocator.free(refs);
    }
    try std.testing.expectEqual(@as(usize, 1), refs.len);
    try std.testing.expectEqualStrings("src/main.zig", refs[0]);
}

test "extractRefs finds mentions separated by newlines and tabs" {
    const refs = try extractRefs(std.testing.allocator, "see @a.txt\nand\t@b.txt");
    defer {
        for (refs) |r| std.testing.allocator.free(r);
        std.testing.allocator.free(refs);
    }
    try std.testing.expectEqual(@as(usize, 2), refs.len);
    try std.testing.expectEqualStrings("a.txt", refs[0]);
    try std.testing.expectEqualStrings("b.txt", refs[1]);
}

test "extractRefs ignores an @ in the middle of a word" {
    const refs = try extractRefs(std.testing.allocator, "foo@bar and @baz");
    defer {
        for (refs) |r| std.testing.allocator.free(r);
        std.testing.allocator.free(refs);
    }
    try std.testing.expectEqual(@as(usize, 1), refs.len);
    try std.testing.expectEqualStrings("baz", refs[0]);
}

test "buildAttachedMessage attaches only readable files" {
    const path = "puny-test-mixed.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    try helpers.writeFile(std.testing.io, path, "present\n");

    const out = try buildAttachedMessage(std.testing.allocator, std.testing.io, "see @puny-test-mixed.txt and @puny-test-absent.txt");
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.startsWith(u8, out, "see @puny-test-mixed.txt and @puny-test-absent.txt"));
    try std.testing.expect(std.mem.indexOf(u8, out, "\n\n@puny-test-mixed.txt\n```\npresent\n```\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\n\n@puny-test-absent.txt\n") == null);
}

test "buildAttachedMessage appends a newline before the closing fence" {
    const path = "puny-test-no-trailing-newline.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    try helpers.writeFile(std.testing.io, path, "no newline at end");

    const out = try buildAttachedMessage(std.testing.allocator, std.testing.io, "see @puny-test-no-trailing-newline.txt");
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "```\nno newline at end\n```\n") != null);
}

test "buildAttachedMessage handles an empty referenced file" {
    const path = "puny-test-empty.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    try helpers.writeFile(std.testing.io, path, "");

    const out = try buildAttachedMessage(std.testing.allocator, std.testing.io, "see @puny-test-empty.txt");
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\n\n@puny-test-empty.txt\n```\n\n```\n") != null);
}
