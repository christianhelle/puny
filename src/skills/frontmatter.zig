const std = @import("std");

pub const Frontmatter = struct {
    description: ?[]const u8 = null,
    triggers: ?[][]const u8 = null,
    disable_model_invocation: bool = false,
};

fn trimCr(maybe_cr: []const u8) []const u8 {
    if (maybe_cr.len > 0 and maybe_cr[maybe_cr.len - 1] == '\r') return maybe_cr[0 .. maybe_cr.len - 1];
    return maybe_cr;
}

/// Parses the YAML-ish frontmatter block of a SKILL.md file. Recognizes
/// `description` (plain or folded), `triggers`, and
/// `disable-model-invocation`. All returned strings are allocated with
/// `allocator`.
pub fn parseFrontmatter(content: []const u8, allocator: std.mem.Allocator) Frontmatter {
    var result = Frontmatter{};
    var lines = std.mem.splitScalar(u8, content, '\n');
    const first = trimCr(lines.next() orelse return result);
    if (!std.mem.eql(u8, first, "---")) return result;

    var desc_buf: std.ArrayList(u8) = .empty;
    defer desc_buf.deinit(allocator);

    var in_folded = false;
    var folded_key: ?[]const u8 = null;

    const flush_folded = struct {
        fn flush(r: *Frontmatter, buf: *std.ArrayList(u8), key: ?[]const u8, alloc: std.mem.Allocator) void {
            if (key == null or buf.items.len == 0) return;
            if (std.mem.eql(u8, key.?, "description")) {
                if (r.description == null) {
                    r.description = alloc.dupe(u8, buf.items) catch null;
                }
            }
        }
    }.flush;

    while (lines.next()) |raw_line| {
        const line = trimCr(raw_line);

        if (in_folded) {
            if (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) {
                const trimmed = std.mem.trimStart(u8, line, " \t");
                if (desc_buf.items.len > 0) {
                    desc_buf.append(allocator, ' ') catch {};
                }
                desc_buf.appendSlice(allocator, trimmed) catch {};
                continue;
            }
            in_folded = false;
            flush_folded(&result, &desc_buf, folded_key, allocator);
            folded_key = null;
        }

        if (std.mem.eql(u8, line, "---")) break;

        if (std.mem.startsWith(u8, line, "description: >")) {
            in_folded = true;
            folded_key = "description";
            desc_buf.clearRetainingCapacity();
        } else if (std.mem.startsWith(u8, line, "description: ")) {
            result.description = allocator.dupe(u8, line["description: ".len..]) catch null;
        } else if (std.mem.startsWith(u8, line, "triggers: ")) {
            result.triggers = parseTriggerList(line["triggers: ".len..], allocator);
        } else if (std.mem.startsWith(u8, line, "disable-model-invocation: true")) {
            result.disable_model_invocation = true;
        } else if (std.mem.startsWith(u8, line, "disable-model-invocation: false")) {
            result.disable_model_invocation = false;
        }
    }

    if (in_folded) {
        flush_folded(&result, &desc_buf, folded_key, allocator);
    }

    return result;
}

fn parseTriggerList(value: []const u8, allocator: std.mem.Allocator) ?[][]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;

    var list = std.ArrayList([]const u8).empty;
    defer list.deinit(allocator);

    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |item| {
        const t = std.mem.trim(u8, item, " \t");
        if (t.len > 0) {
            const duped = allocator.dupe(u8, t) catch return null;
            list.append(allocator, duped) catch {
                allocator.free(duped);
                return null;
            };
        }
    }

    if (list.items.len == 0) return null;
    return list.toOwnedSlice(allocator) catch null;
}

test "parseFrontmatter parses a single-line description" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const fm = parseFrontmatter("---\nname: test\ndescription: A skill\n---\nbody", allocator);
    defer if (fm.description) |d| allocator.free(d);

    try std.testing.expectEqualStrings("A skill", fm.description.?);
    try std.testing.expect(fm.triggers == null);
    try std.testing.expect(!fm.disable_model_invocation);
}

test "parseFrontmatter parses a multi-line folded description" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const fm = parseFrontmatter(
        "---\nname: test\ndescription: >\n  first line\n  second line\n---\nbody",
        allocator,
    );
    defer if (fm.description) |d| allocator.free(d);

    try std.testing.expectEqualStrings("first line second line", fm.description.?);
}

test "parseFrontmatter handles CRLF line endings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const fm = parseFrontmatter("---\r\nname: win\ndescription: >\r\n  line one\r\n  line two\r\n---\r\nbody\r\n", allocator);
    defer if (fm.description) |d| allocator.free(d);

    try std.testing.expectEqualStrings("line one line two", fm.description.?);
}

test "parseFrontmatter parses triggers as a comma-separated list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const fm = parseFrontmatter("---\ndescription: A skill\ntriggers: do the thing, run the thing\n---\nbody", allocator);
    defer {
        if (fm.description) |d| allocator.free(d);
        if (fm.triggers) |t| {
            for (t) |s| allocator.free(s);
            allocator.free(t);
        }
    }

    try std.testing.expectEqual(@as(usize, 2), fm.triggers.?.len);
    try std.testing.expectEqualStrings("do the thing", fm.triggers.?[0]);
    try std.testing.expectEqualStrings("run the thing", fm.triggers.?[1]);
}

test "parseFrontmatter parses disable-model-invocation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const fm = parseFrontmatter("---\ndisable-model-invocation: true\n---\nbody", allocator);
    try std.testing.expect(fm.disable_model_invocation);
}

test "parseFrontmatter returns defaults without a frontmatter block" {
    const fm = parseFrontmatter("just body text", std.testing.allocator);
    try std.testing.expect(fm.description == null);
    try std.testing.expect(fm.triggers == null);
    try std.testing.expect(!fm.disable_model_invocation);
}

test "parseTriggerList trims surrounding whitespace and drops empty items" {
    const fm = parseFrontmatter("---\ntriggers:  a ,, b ,  \n---\nbody", std.testing.allocator);
    defer if (fm.triggers) |t| {
        for (t) |s| std.testing.allocator.free(s);
        std.testing.allocator.free(t);
    };
    try std.testing.expectEqual(@as(usize, 2), fm.triggers.?.len);
    try std.testing.expectEqualStrings("a", fm.triggers.?[0]);
    try std.testing.expectEqualStrings("b", fm.triggers.?[1]);
}
