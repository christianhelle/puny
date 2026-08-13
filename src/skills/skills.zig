const std = @import("std");

pub const SkillRecord = struct {
    name: []const u8,
    description: ?[]const u8,
    dir_path: []const u8,
    triggers: ?[][]const u8,
    disable_model_invocation: bool,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(SkillRecord),
    fully_scanned: bool,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .records = .empty,
            .fully_scanned = false,
        };
    }

    pub fn deinit(self: *Registry) void {
        for (self.records.items) |*r| {
            self.allocator.free(r.name);
            if (r.description) |d| self.allocator.free(d);
            if (r.triggers) |t| {
                for (t) |s| self.allocator.free(s);
                self.allocator.free(t);
            }
            self.allocator.free(r.dir_path);
        }
        self.records.deinit(self.allocator);
    }

    pub fn lightScan(self: *Registry, io: std.Io, dir_path: []const u8) !void {
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => |e| return e,
        };
        defer dir.close(io);

        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            const name = try self.allocator.dupe(u8, entry.name);
            const full_dir_path = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
            try self.records.append(self.allocator, .{
                .name = name,
                .description = null,
                .dir_path = full_dir_path,
                .triggers = null,
                .disable_model_invocation = false,
            });
        }
    }

    pub fn findByName(self: *Registry, name: []const u8) ?*SkillRecord {
        for (self.records.items) |*r| {
            if (std.mem.eql(u8, r.name, name)) return r;
        }
        return null;
    }

    pub fn count(self: *Registry) usize {
        return self.records.items.len;
    }

    pub fn buildListing(self: *Registry, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);

        try buf.appendSlice(allocator, "<available_skills>\n");
        for (self.records.items) |r| {
            if (r.description) |desc| {
                try buf.appendSlice(allocator, "  <skill>\n    <name>");
                try buf.appendSlice(allocator, r.name);
                try buf.appendSlice(allocator, "</name>\n    <description>");
                try buf.appendSlice(allocator, desc);
                try buf.appendSlice(allocator, "</description>\n  </skill>\n");
            } else {
                try buf.appendSlice(allocator, "  <skill>\n    <name>");
                try buf.appendSlice(allocator, r.name);
                try buf.appendSlice(allocator, "</name>\n  </skill>\n");
            }
        }
        try buf.appendSlice(allocator, "</available_skills>");

        return buf.toOwnedSlice(allocator);
    }

    pub fn loadContent(self: *Registry, io: std.Io, name: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        const record = self.findByName(name) orelse return error.SkillNotFound;
        const skill_path = try std.fs.path.join(self.allocator, &.{ record.dir_path, "SKILL.md" });
        defer self.allocator.free(skill_path);

        const content = try std.Io.Dir.cwd().readFileAlloc(io, skill_path, allocator, std.Io.Limit.limited(1024 * 1024));
        defer allocator.free(content);

        if (content.len < 4) return allocator.dupe(u8, content);
        if (!std.mem.startsWith(u8, content, "---\n") and !std.mem.startsWith(u8, content, "---\r\n")) return allocator.dupe(u8, content);

        const delim = if (std.mem.startsWith(u8, content, "---\r\n")) "\r\n---" else "\n---";
        const header_len: usize = if (std.mem.startsWith(u8, content, "---\r\n")) 5 else 4;

        const body_start = std.mem.indexOf(u8, content[header_len..], delim) orelse return allocator.dupe(u8, content);
        const body = content[header_len + body_start + delim.len ..];
        return allocator.dupe(u8, body);
    }

    pub fn fullScan(self: *Registry, io: std.Io) !void {
        for (self.records.items) |*r| {
            const skill_path = try std.fs.path.join(self.allocator, &.{ r.dir_path, "SKILL.md" });
            defer self.allocator.free(skill_path);

            const content = std.Io.Dir.cwd().readFileAlloc(io, skill_path, self.allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => |e| return e,
            };
            defer self.allocator.free(content);

            const fm = parseFrontmatter(content, self.allocator);
            r.description = fm.description;
            r.triggers = fm.triggers;
            r.disable_model_invocation = fm.disable_model_invocation;
        }
        self.fully_scanned = true;
    }

    pub fn findTriggeredSkill(self: *Registry, text: []const u8) ?[]const u8 {
        for (self.records.items) |r| {
            if (recordMatchesTrigger(&r, text)) return r.name;
        }
        return null;
    }
};

pub fn homeDir(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) !?[]const u8 {
    const home = environ_map.get("HOME") orelse environ_map.get("USERPROFILE") orelse return null;
    return try allocator.dupe(u8, home);
}

/// Maximum number of parent directories to walk upward when looking for a
/// repository root. Bounds the search so an unusual mount point cannot stall
/// startup.
const max_git_repo_depth = 64;

/// Returns true when `dir` contains a `.git` entry. The entry is a directory
/// in a regular clone, a file in a linked worktree, or a symlink to either;
/// existence alone marks the root, which matches how git locates the top
/// level of a worktree.
fn isGitRepoRoot(io: std.Io, dir: []const u8) bool {
    var marker_buf: [std.fs.max_path_bytes]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_buf, "{s}{c}.git", .{ dir, std.fs.path.sep }) catch return false;
    std.Io.Dir.cwd().access(io, marker, .{}) catch return false;
    return true;
}

/// Walks upward from `start_dir` and returns the path of the nearest ancestor
/// that contains a `.git` entry, or null when no ancestor is a repository
/// root. `start_dir` may be absolute or relative; relative paths are resolved
/// from the process working directory and the walk can climb above it. The
/// result is written into `out_buf` and stays valid until the next call that
/// reuses the buffer.
fn findRepoRootUpward(io: std.Io, start_dir: []const u8, out_buf: []u8) ?[]const u8 {
    var dir = start_dir;
    // Trim trailing separators while preserving a bare root like "/" or "C:\".
    while (dir.len > 1 and (dir[dir.len - 1] == '/' or dir[dir.len - 1] == '\\')) {
        dir = dir[0 .. dir.len - 1];
    }
    if (dir.len == 0) return null;
    const is_absolute = std.fs.path.isAbsolute(dir);

    // Scratch space for building relative parent chains such as "../..".
    var scratch: [std.fs.max_path_bytes]u8 = undefined;
    // Number of levels climbed above the working directory (relative starts).
    var hops: usize = 0;

    var depth: usize = 0;
    while (true) {
        if (depth >= max_git_repo_depth) return null;
        depth += 1;

        if (isGitRepoRoot(io, dir)) {
            // Prefer the canonical path, matching `git rev-parse
            // --show-toplevel`. `realPathFile` opens the directory and
            // resolves it through a real file descriptor, so unlike
            // `Dir.cwd().realPath` it works on every platform (the cwd handle
            // on POSIX is AT.FDCWD, which is not a real descriptor). Fall back
            // to the literal path when canonicalization fails.
            if (std.Io.Dir.cwd().realPathFile(io, dir, out_buf)) |n| {
                return out_buf[0..n];
            } else |_| {
                if (dir.len > out_buf.len) return null;
                @memcpy(out_buf[0..dir.len], dir);
                return out_buf[0..dir.len];
            }
        }

        if (is_absolute) {
            dir = std.fs.path.dirname(dir) orelse return null;
            if (dir.len == 0) return null;
        } else if (hops > 0) {
            // Climb above the working directory: extend the "../.." chain.
            hops += 1;
            const chain_len = 2 + (hops - 1) * 3;
            if (chain_len > scratch.len) return null;
            var i: usize = 0;
            for (0..hops) |_| {
                if (i > 0) {
                    scratch[i] = std.fs.path.sep;
                    i += 1;
                }
                scratch[i] = '.';
                scratch[i + 1] = '.';
                i += 2;
            }
            dir = scratch[0..i];
        } else {
            // Descend toward the working directory one level at a time.
            if (std.mem.eql(u8, dir, ".")) {
                hops = 1;
                dir = "..";
            } else {
                // A relative path with a single component has no dirname; its
                // parent is the working directory itself.
                dir = std.fs.path.dirname(dir) orelse ".";
            }
        }
    }
}

pub fn findGitRepoRoot(allocator: std.mem.Allocator, io: std.Io) !?[]const u8 {
    // Spawning `git rev-parse --show-toplevel` used to cost tens of
    // milliseconds per process start (and up to its 5 s timeout when git
    // hung). Detecting the repository by walking up the working directory for
    // a `.git` entry is microseconds and needs no external process, so
    // startup stays fast even on huge or slow repositories.
    //
    // The walk starts from the relative path "." because the absolute working
    // directory cannot be resolved portably: on POSIX `Dir.cwd().realPath()`
    // reads /proc/self/fd/{handle}, but the cwd handle is AT.FDCWD, which is
    // not a real file descriptor.
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = findRepoRootUpward(io, ".", &root_buf) orelse return null;
    return try allocator.dupe(u8, root);
}
var global_registry: ?*Registry = null;

pub fn setGlobalRegistry(reg: *Registry) void {
    global_registry = reg;
}

pub fn getGlobalRegistry() ?*Registry {
    return global_registry;
}

const PendingSkill = struct { name: []const u8, content: []const u8 };

var pending_queue: std.ArrayList(PendingSkill) = .empty;

pub fn takePendingSkill(allocator: std.mem.Allocator) ?PendingSkill {
    if (pending_queue.items.len == 0) return null;
    const item = pending_queue.orderedRemove(0);
    return .{
        .name = allocator.dupe(u8, item.name) catch return null,
        .content = allocator.dupe(u8, item.content) catch return null,
    };
}

pub fn setPendingSkill(name: []const u8, content: []const u8, allocator: std.mem.Allocator) void {
    const dup_name = allocator.dupe(u8, name) catch return;
    const dup_content = allocator.dupe(u8, content) catch return;
    pending_queue.append(allocator, .{ .name = dup_name, .content = dup_content }) catch {
        allocator.free(dup_name);
        allocator.free(dup_content);
        return;
    };
}

fn trimCr(maybe_cr: []const u8) []const u8 {
    if (maybe_cr.len > 0 and maybe_cr[maybe_cr.len - 1] == '\r') return maybe_cr[0 .. maybe_cr.len - 1];
    return maybe_cr;
}

const Frontmatter = struct {
    description: ?[]const u8 = null,
    triggers: ?[][]const u8 = null,
    disable_model_invocation: bool = false,
};

fn parseFrontmatter(content: []const u8, allocator: std.mem.Allocator) Frontmatter {
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

pub fn recordMatchesTrigger(record: *const SkillRecord, text: []const u8) bool {
    if (record.disable_model_invocation) return false;
    if (textContainsWord(text, record.name)) return true;
    if (record.triggers) |triggers| {
        for (triggers) |trigger| {
            if (textContainsWord(text, trigger)) return true;
        }
    }
    return false;
}

pub fn textContainsWord(text: []const u8, word: []const u8) bool {
    if (word.len == 0) return false;
    if (wordAtBoundary(text, word)) return true;
    if (std.mem.indexOfScalar(u8, word, '-') != null and word.len <= 128) {
        var normalized_buf: [128]u8 = undefined;
        const normalized = normalizeHyphensToSpaces(&normalized_buf, word);
        if (wordAtBoundary(text, normalized)) return true;
    }
    return false;
}

fn wordAtBoundary(text: []const u8, word: []const u8) bool {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, text, search_from, word)) |match_pos| {
        if (match_pos > 0 and std.ascii.isAlphanumeric(text[match_pos - 1])) {
            search_from = match_pos + 1;
            continue;
        }
        const end = match_pos + word.len;
        if (end < text.len and std.ascii.isAlphanumeric(text[end])) {
            search_from = match_pos + 1;
            continue;
        }
        return true;
    }
    return false;
}

fn normalizeHyphensToSpaces(buf: *[128]u8, word: []const u8) []const u8 {
    for (word, 0..) |byte, i| {
        buf[i] = if (byte == '-') ' ' else byte;
    }
    return buf[0..word.len];
}

test "init creates empty registry" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try std.testing.expectEqual(@as(usize, 0), registry.records.items.len);
    try std.testing.expect(!registry.fully_scanned);
}

test "lightScan discovers skill directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "my-skill", .default_dir);
    try tmp.dir.createDir(std.testing.io, "other-skill", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "not-a-dir", .data = "" });

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.lightScan(std.testing.io, base_path);

    try std.testing.expectEqual(@as(usize, 2), registry.records.items.len);

    var found_my = false;
    var found_other = false;
    for (registry.records.items) |r| {
        if (std.mem.eql(u8, r.name, "my-skill")) found_my = true;
        if (std.mem.eql(u8, r.name, "other-skill")) found_other = true;
        try std.testing.expect(r.description == null);
    }
    try std.testing.expect(found_my);
    try std.testing.expect(found_other);
}

test "lightScan handles missing directory gracefully" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.lightScan(std.testing.io, "/nonexistent/path/that/does/not/exist");
    try std.testing.expectEqual(@as(usize, 0), registry.records.items.len);
}

test "findByName returns correct record" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "alpha", .default_dir);
    try tmp.dir.createDir(std.testing.io, "beta", .default_dir);

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);

    const found = registry.findByName("beta").?;
    try std.testing.expectEqualStrings("beta", found.name);
    try std.testing.expect(found.description == null);
}

test "findByName returns null for unknown name" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try std.testing.expect(registry.findByName("nope") == null);
}

fn writeSkillFile(io: std.Io, tmp: anytype, name: []const u8, frontmatter_name: []const u8, description_lines: []const []const u8, body: []const u8) !void {
    try tmp.dir.createDir(io, name, .default_dir);

    var lines: std.ArrayList(u8) = .empty;
    defer lines.deinit(std.testing.allocator);
    try lines.appendSlice(std.testing.allocator, "---\nname: ");
    try lines.appendSlice(std.testing.allocator, frontmatter_name);
    try lines.appendSlice(std.testing.allocator, "\ndescription: >\n");
    for (description_lines) |line| {
        try lines.appendSlice(std.testing.allocator, "  ");
        try lines.appendSlice(std.testing.allocator, line);
        try lines.appendSlice(std.testing.allocator, "\n");
    }
    try lines.appendSlice(std.testing.allocator, "---\n");
    try lines.appendSlice(std.testing.allocator, body);

    var skill_path_buf: [256]u8 = undefined;
    const skill_path = try std.fmt.bufPrint(&skill_path_buf, "{s}/SKILL.md", .{name});

    try tmp.dir.writeFile(io, .{ .sub_path = skill_path, .data = lines.items });
}

test "fullScan populates descriptions from frontmatter" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeSkillFile(std.testing.io, tmp, "my-skill", "my-skill", &.{"Does something useful."}, "This is the skill content\nwith multiple lines.");

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);
    try registry.fullScan(std.testing.io);

    try std.testing.expect(registry.fully_scanned);
    const record = registry.findByName("my-skill").?;
    try std.testing.expectEqualStrings("Does something useful.", record.description.?);
}

test "fullScan handles missing SKILL.md gracefully" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "empty-dir", .default_dir);

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);
    try registry.fullScan(std.testing.io);

    try std.testing.expect(registry.fully_scanned);
    const record = registry.findByName("empty-dir").?;
    try std.testing.expect(record.description == null);
}

test "fullScan parses frontmatter with CRLF line endings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "win-skill", .default_dir);
    const content = "---\r\nname: win-skill\r\ndescription: >\r\n  Works on Windows\r\n  with CRLF endings\r\n---\r\nbody text\r\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "win-skill/SKILL.md", .data = content });

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);
    try registry.fullScan(std.testing.io);

    try std.testing.expect(registry.fully_scanned);
    const record = registry.findByName("win-skill").?;
    try std.testing.expectEqualStrings("Works on Windows with CRLF endings", record.description.?);
}

test "fullScan parses single-line description with CRLF" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "simple", .default_dir);
    const content = "---\r\nname: simple\r\ndescription: A simple skill\r\n---\r\nbody\r\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "simple/SKILL.md", .data = content });

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);
    try registry.fullScan(std.testing.io);

    const record = registry.findByName("simple").?;
    try std.testing.expectEqualStrings("A simple skill", record.description.?);
}

test "fullScan parses multi-line folded description" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeSkillFile(std.testing.io, tmp, "alba-testing", "alba-testing", &.{
        "Expert knowledge of Alba, a class library for integration testing.",
        "Covers AlbaHost creation, Scenario-based HTTP testing.",
    }, "These are the instructions.");

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);
    try registry.fullScan(std.testing.io);

    const record = registry.findByName("alba-testing").?;
    try std.testing.expectEqualStrings("Expert knowledge of Alba, a class library for integration testing. Covers AlbaHost creation, Scenario-based HTTP testing.", record.description.?);
}

test "loadContent returns body without frontmatter" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "my-skill", .default_dir);
    const content = "---\nname: my-skill\ndescription: >\n  A test skill\n---\n\nThis is the skill body\nwith multiple lines.\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "my-skill/SKILL.md", .data = content });

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);

    const body = try registry.loadContent(std.testing.io, "my-skill", std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("\n\nThis is the skill body\nwith multiple lines.\n", body);
}

test "loadContent returns full file when no frontmatter" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "plain", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "plain/SKILL.md", .data = "Just plain text\nno frontmatter" });

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);

    const body = try registry.loadContent(std.testing.io, "plain", std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("Just plain text\nno frontmatter", body);
}

test "loadContent returns error for unknown skill" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const body = registry.loadContent(std.testing.io, "nonexistent", std.testing.allocator);
    try std.testing.expectError(error.SkillNotFound, body);
}

test "buildListing shows names only before fullScan" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "alpha", .default_dir);
    try tmp.dir.createDir(std.testing.io, "beta", .default_dir);

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);

    const listing = try registry.buildListing(std.testing.allocator);
    defer std.testing.allocator.free(listing);
    try std.testing.expect(std.mem.indexOf(u8, listing, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, listing, "beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, listing, "<available_skills>") != null);
}

test "findGitRepoRoot does not crash" {
    const result = try findGitRepoRoot(std.testing.allocator, std.testing.io);
    if (result) |r| std.testing.allocator.free(r);
}
test "findGitRepoRoot finds the repository when run inside one" {
    // The test runner's working directory is this repository's root, so the
    // lookup must find a repo root (the same outcome `git rev-parse
    // --show-toplevel` produced before the walk-based implementation).
    const result = try findGitRepoRoot(std.testing.allocator, std.testing.io);
    defer if (result) |r| std.testing.allocator.free(r);
    try std.testing.expect(result != null);
}

test "isGitRepoRoot detects a .git directory and rejects other directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    try tmp.dir.createDir(std.testing.io, "plain", .default_dir);
    try std.testing.expect(!isGitRepoRoot(std.testing.io, base_path));

    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    const repo_path = try std.fs.path.join(std.testing.allocator, &.{ base_path, "repo" });
    defer std.testing.allocator.free(repo_path);
    try std.testing.expect(isGitRepoRoot(std.testing.io, repo_path));
}

test "isGitRepoRoot treats a .git file (linked worktree) as a repo root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "wt");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "wt/.git", .data = "gitdir: /elsewhere/.git\n" });

    const wt_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "wt" });
    defer std.testing.allocator.free(wt_path);
    try std.testing.expect(isGitRepoRoot(std.testing.io, wt_path));
}

test "findRepoRootUpward finds the nearest ancestor with a .git directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "root", .default_dir);
    try tmp.dir.createDir(std.testing.io, "root/.git", .default_dir);
    try tmp.dir.createDirPath(std.testing.io, "root/sub/deeper");

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    const start_path = try std.fs.path.join(std.testing.allocator, &.{ base_path, "root", "sub", "deeper" });
    defer std.testing.allocator.free(start_path);

    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = findRepoRootUpward(std.testing.io, start_path, &out_buf).?;

    var expected_buf: [std.fs.max_path_bytes]u8 = undefined;
    const expected_path = try std.fs.path.join(std.testing.allocator, &.{ base_path, "root" });
    defer std.testing.allocator.free(expected_path);
    const n = try std.Io.Dir.cwd().realPathFile(std.testing.io, expected_path, &expected_buf);

    try std.testing.expectEqualStrings(expected_buf[0..n], root);
}

test "findRepoRootUpward treats a .git file (linked worktree) as a repo root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "wt");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "wt/.git", .data = "gitdir: /elsewhere/.git\n" });
    try tmp.dir.createDirPath(std.testing.io, "wt/sub");

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    const start_path = try std.fs.path.join(std.testing.allocator, &.{ base_path, "wt", "sub" });
    defer std.testing.allocator.free(start_path);

    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = findRepoRootUpward(std.testing.io, start_path, &out_buf).?;

    var expected_buf: [std.fs.max_path_bytes]u8 = undefined;
    const expected_path = try std.fs.path.join(std.testing.allocator, &.{ base_path, "wt" });
    defer std.testing.allocator.free(expected_path);
    const n = try std.Io.Dir.cwd().realPathFile(std.testing.io, expected_path, &expected_buf);

    try std.testing.expectEqualStrings(expected_buf[0..n], root);
}

test "findRepoRootUpward returns null when no ancestor is a repository" {
    // A synthetic path that cannot exist anywhere in the tree, so the walk
    // reaches the filesystem root without finding a `.git` marker. The tmp
    // dirs from other tests live inside this repository, so they cannot be
    // used for a "no repo" case.
    const start = if (comptime @import("builtin").os.tag == .windows)
        "Z:\\puny-no-git-walk-test"
    else
        "/puny-no-git-walk-test";

    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expect(findRepoRootUpward(std.testing.io, start, &out_buf) == null);
}
test "findRepoRootUpward finds the repository root from a relative start" {
    // The test runner's working directory is this repository's root, so a
    // relative start inside the tree must resolve to the repo root. This
    // covers the startup path, which walks from "." because the absolute
    // working directory cannot be resolved portably.
    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = findRepoRootUpward(std.testing.io, "src", &out_buf).?;

    var expected_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.cwd().realPathFile(std.testing.io, ".", &expected_buf);
    try std.testing.expectEqualStrings(expected_buf[0..n], root);
}

test "homeDir returns HOME from environ map" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/testuser");

    const result = try homeDir(std.testing.allocator, &env);
    defer if (result) |r| std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("/home/testuser", result.?);
}

test "homeDir returns USERPROFILE if HOME not set" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("USERPROFILE", "C:\\Users\\test");

    const result = try homeDir(std.testing.allocator, &env);
    defer if (result) |r| std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("C:\\Users\\test", result.?);
}

test "homeDir returns null when no home vars set" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    const result = try homeDir(std.testing.allocator, &env);
    try std.testing.expect(result == null);
}

test "buildListing includes descriptions after fullScan" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "my-skill", .default_dir);
    const content = "---\nname: my-skill\ndescription: >\n  Does something useful\n---\nbody";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "my-skill/SKILL.md", .data = content });

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);
    try registry.fullScan(std.testing.io);

    const listing = try registry.buildListing(std.testing.allocator);
    defer std.testing.allocator.free(listing);
    try std.testing.expect(std.mem.indexOf(u8, listing, "Does something useful") != null);
}

test "fullScan populates triggers from frontmatter" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "my-skill", .default_dir);
    const content = "---\nname: my-skill\ndescription: A skill\ntriggers: do the thing, run the thing\n---\nbody";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "my-skill/SKILL.md", .data = content });

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);
    try registry.fullScan(std.testing.io);

    const record = registry.findByName("my-skill").?;
    try std.testing.expect(record.triggers != null);
    try std.testing.expectEqual(@as(usize, 2), record.triggers.?.len);
    try std.testing.expectEqualStrings("do the thing", record.triggers.?[0]);
    try std.testing.expectEqualStrings("run the thing", record.triggers.?[1]);
}

test "fullScan populates disable_model_invocation from frontmatter" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "manual-skill", .default_dir);
    const content = "---\nname: manual-skill\ndescription: Manual only\ndisable-model-invocation: true\n---\nbody";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "manual-skill/SKILL.md", .data = content });

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);
    try registry.fullScan(std.testing.io);

    const record = registry.findByName("manual-skill").?;
    try std.testing.expect(record.disable_model_invocation);
}

test "findTriggeredSkill matches directory name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "grill-me", .default_dir);
    try tmp.dir.createDir(std.testing.io, "other-skill", .default_dir);

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);

    const matched = registry.findTriggeredSkill("can you grill me on this");
    try std.testing.expect(matched != null);
    try std.testing.expectEqualStrings("grill-me", matched.?);
}

test "findTriggeredSkill matches trigger phrase" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "my-skill", .default_dir);
    const content = "---\nname: my-skill\ndescription: Does stuff\ntriggers: do the thing, run it\n---\nbody";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "my-skill/SKILL.md", .data = content });

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);
    try registry.fullScan(std.testing.io);

    const matched = registry.findTriggeredSkill("please do the thing now");
    try std.testing.expect(matched != null);
    try std.testing.expectEqualStrings("my-skill", matched.?);
}

test "findTriggeredSkill skips disabled skills" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "manual-skill", .default_dir);
    const content = "---\nname: manual-skill\ndescription: Manual\ndisable-model-invocation: true\n---\nbody";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "manual-skill/SKILL.md", .data = content });

    try tmp.dir.createDir(std.testing.io, "auto-skill", .default_dir);
    const content2 = "---\nname: auto-skill\ndescription: Auto\n---\nbody";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "auto-skill/SKILL.md", .data = content2 });

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);
    try registry.fullScan(std.testing.io);

    const matched = registry.findTriggeredSkill("please use auto-skill");
    try std.testing.expect(matched != null);
    try std.testing.expectEqualStrings("auto-skill", matched.?);
}

test "findTriggeredSkill returns null when no match" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const matched = registry.findTriggeredSkill("hello world");
    try std.testing.expect(matched == null);
}

test "textContainsWord matches whole words" {
    try std.testing.expect(textContainsWord("hello world", "hello"));
    try std.testing.expect(textContainsWord("hello world", "world"));
    try std.testing.expect(!textContainsWord("hello world", "worl"));
    try std.testing.expect(!textContainsWord("hello world", "ello"));
    try std.testing.expect(textContainsWord("foo-bar baz", "foo-bar"));
    try std.testing.expect(!textContainsWord("hello", ""));
}

test "textContainsWord finds a later valid occurrence after a rejected one" {
    // The first "do it" sits inside "undo" (alphanumeric on its left); the
    // later standalone "do it" must still match.
    try std.testing.expect(textContainsWord("undo it, then do it", "do it"));
    try std.testing.expect(textContainsWord("do itty, do it", "do it"));
    try std.testing.expect(!textContainsWord("undo it", "do it"));
}

test "normalizeHyphensToSpaces converts hyphens for trigger matching" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("foo bar", normalizeHyphensToSpaces(&buf, "foo-bar"));
    try std.testing.expectEqualStrings("a b c", normalizeHyphensToSpaces(&buf, "a-b-c"));
    try std.testing.expectEqualStrings("plain", normalizeHyphensToSpaces(&buf, "plain"));
}

test "findTriggeredSkill matches a hyphenated directory name in prose" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "write-a-skill", .default_dir);
    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);

    const matched = registry.findTriggeredSkill("help me write a skill");
    try std.testing.expect(matched != null);
    try std.testing.expectEqualStrings("write-a-skill", matched.?);
}

test "recordMatchesTrigger matches whole words only" {
    var triggers = [_][]const u8{ "do it", "run now" };
    const record = SkillRecord{
        .name = "test-skill",
        .description = "",
        .dir_path = "/tmp/skills/test-skill",
        .triggers = triggers[0..],
        .disable_model_invocation = false,
    };
    try std.testing.expect(recordMatchesTrigger(&record, "please do it please"));
    try std.testing.expect(recordMatchesTrigger(&record, "run now!"));
    try std.testing.expect(!recordMatchesTrigger(&record, "undo it now"));
    try std.testing.expect(!recordMatchesTrigger(&record, "do"));
}
