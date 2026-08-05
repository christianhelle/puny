const std = @import("std");
const builtin = @import("builtin");
const prompt_file = @import("prompt_file.zig");

pub const History = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList([]const u8),
    path: []const u8,
    browsing_index: ?usize,
    saved_current: ?[]const u8,
    max_entries: usize,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) History {
        return .{
            .allocator = allocator,
            .entries = .empty,
            .path = path,
            .browsing_index = null,
            .saved_current = null,
            .max_entries = 1000,
        };
    }

    pub fn deinit(self: *History) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry);
        }
        self.entries.deinit(self.allocator);
        if (self.saved_current) |current| {
            self.allocator.free(current);
        }
    }

    pub fn load(self: *History, io: std.Io) !void {
        const cwd = std.Io.Dir.cwd();
        const data = cwd.readFileAlloc(io, self.path, self.allocator, std.Io.Limit.limited(1024 * 1024)) catch |err|
            switch (err) {
                error.FileNotFound => return,
                else => |e| return e,
            };
        defer self.allocator.free(data);

        const parsed = std.json.parseFromSlice([]const []const u8, self.allocator, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_if_needed,
        }) catch |err| {
            std.log.warn(
                "failed to parse prompt history at {s}: {s}. starting fresh.",
                .{ self.path, @errorName(err) },
            );
            return;
        };
        defer parsed.deinit();

        for (parsed.value) |entry| {
            const copy = try self.allocator.dupe(u8, entry);
            try self.entries.append(self.allocator, copy);
        }
    }

    pub fn save(self: *const History, io: std.Io) !void {
        const dir = std.fs.path.dirname(self.path) orelse return error.BadPath;
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(io, dir) catch |err| {
            std.log.warn(
                "failed to create prompt history directory {s}: {s}. history will not be saved.",
                .{ dir, @errorName(err) },
            );
            return;
        };

        // Tighten an existing history file to owner-only before overwriting it
        // so prompts are never left group/other-readable after a rewrite.
        if (comptime builtin.os.tag != .windows) {
            if (cwd.statFile(io, self.path, .{})) |st| {
                if (st.permissions.toMode() & 0o077 != 0) {
                    std.log.warn(
                        "prompt history file {s} is readable or writable by other users; tightening to owner-only.",
                        .{self.path},
                    );
                    cwd.setFilePermissions(io, self.path, @enumFromInt(0o600), .{}) catch {};
                }
            } else |_| {}
        }

        const buffer = try std.json.Stringify.valueAlloc(
            self.allocator,
            self.entries.items,
            .{ .whitespace = .indent_2 },
        );
        defer self.allocator.free(buffer);

        var file = cwd.createFile(io, self.path, .{}) catch |err| {
            std.log.warn(
                "failed to create prompt history file {s}: {s}. history will not be saved.",
                .{ self.path, @errorName(err) },
            );
            return;
        };
        defer file.close(io);
        // A freshly created file can inherit a permissive umask, and truncating
        // an existing file keeps its previous mode; force owner-only either way.
        if (comptime builtin.os.tag != .windows) {
            cwd.setFilePermissions(io, self.path, @enumFromInt(0o600), .{}) catch {};
        }
        file.writeStreamingAll(io, buffer) catch |err| {
            std.log.warn("failed to write prompt history to {s}: {s}.", .{ self.path, @errorName(err) });
            return;
        };
        file.writeStreamingAll(io, "\n") catch |err| {
            std.log.warn("failed to write prompt history to {s}: {s}.", .{ self.path, @errorName(err) });
            return;
        };
    }

    pub fn add(self: *History, text: []const u8) !void {
        if (text.len == 0) return;

        const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
        if (trimmed.len == 0) return;
        if (std.mem.startsWith(u8, trimmed, "/") and !isFileCommand(trimmed)) return;
        if (std.mem.startsWith(u8, trimmed, "/file ") and fileSourceHasCredentials(trimmed["/file ".len..])) return;

        // Avoid consecutive duplicates.
        if (self.entries.items.len > 0) {
            const last = self.entries.items[self.entries.items.len - 1];
            if (std.mem.eql(u8, last, trimmed)) return;
        }

        const copy = try self.allocator.dupe(u8, trimmed);
        try self.entries.append(self.allocator, copy);

        while (self.entries.items.len > self.max_entries) {
            self.allocator.free(self.entries.items[0]);
            _ = self.entries.orderedRemove(0);
        }
    }

    /// `/file <source>` commands are stored so a user can re-run a prompt file from
    /// history after editing it. Other slash commands are transient input and
    /// are not stored.
    fn isFileCommand(text: []const u8) bool {
        return std.mem.startsWith(u8, text, "/file ");
    }

    /// Returns true when `source` is an http(s) URL that embeds credentials in
    /// its userinfo (e.g. `https://user:secret@host/...`). Such URLs must not
    /// be written to prompt history in plaintext.
    fn fileSourceHasCredentials(source: []const u8) bool {
        if (!prompt_file.isHttpUrl(source)) return false;
        const scheme_end = (std.mem.indexOf(u8, source, "://") orelse return false) + 3;
        const rest = source[scheme_end..];
        const path_start = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
        const at = std.mem.indexOfScalar(u8, rest, '@') orelse return false;
        return at < path_start;
    }

    pub fn clear(self: *History) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry);
        }
        self.entries.deinit(self.allocator);
        self.entries = .empty;
        if (self.saved_current) |current| {
            self.allocator.free(current);
            self.saved_current = null;
        }
        self.browsing_index = null;
    }

    pub fn resetNavigation(self: *History) void {
        self.browsing_index = null;
        if (self.saved_current) |current| {
            self.allocator.free(current);
            self.saved_current = null;
        }
    }

    pub fn previous(self: *History, current: []const u8) ?[]const u8 {
        if (self.entries.items.len == 0) return null;

        if (self.browsing_index == null) {
            const current_copy = self.allocator.dupe(u8, current) catch return null;
            self.saved_current = current_copy;
            self.browsing_index = self.entries.items.len - 1;
        } else if (self.browsing_index.? > 0) {
            self.browsing_index = self.browsing_index.? - 1;
        } else {
            return null;
        }

        return self.entries.items[self.browsing_index.?];
    }

    pub fn next(self: *History) ?[]const u8 {
        const index = self.browsing_index orelse return null;

        if (index + 1 >= self.entries.items.len) {
            self.browsing_index = null;
            return null;
        }

        self.browsing_index = index + 1;
        return self.entries.items[self.browsing_index.?];
    }

    pub fn currentDraft(self: *const History) ?[]const u8 {
        return self.saved_current;
    }
};

pub fn historyPath(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const base = environ_map.get("APPDATA") orelse environ_map.get("USERPROFILE") orelse return error.NoConfigDir;
        return std.fs.path.join(allocator, &.{ base, "puny", "prompt_history.json" });
    }

    if (environ_map.get("XDG_CONFIG_HOME")) |base| {
        return std.fs.path.join(allocator, &.{ base, "puny", "prompt_history.json" });
    }

    const home = environ_map.get("HOME") orelse return error.NoConfigDir;
    return std.fs.path.join(allocator, &.{ home, ".config", "puny", "prompt_history.json" });
}

test "add ignores empty and non-file slash commands" {
    var history = History.init(std.testing.allocator, "");
    defer history.deinit();

    try history.add("");
    try history.add("/quit");
    try history.add(" /quit");
    try std.testing.expectEqual(@as(usize, 0), history.entries.items.len);
}

test "add stores /file commands so they can be re-run from history" {
    var history = History.init(std.testing.allocator, "");
    defer history.deinit();

    try history.add("/file spec.md");
    try history.add("/file spec.md");
    try history.add(" /file https://example.com/prompt.md ");
    try std.testing.expectEqual(@as(usize, 2), history.entries.items.len);
    try std.testing.expectEqualStrings("/file spec.md", history.entries.items[0]);
    try std.testing.expectEqualStrings("/file https://example.com/prompt.md", history.entries.items[1]);
}

test "add does not persist /file urls that embed credentials in the userinfo" {
    var history = History.init(std.testing.allocator, "");
    defer history.deinit();

    try history.add("/file https://user:secret@example.com/prompt.md");
    try history.add("/file https://token@example.com/prompt.md");
    try history.add("/file https://example.com/prompt.md");
    try std.testing.expectEqual(@as(usize, 1), history.entries.items.len);
    try std.testing.expectEqualStrings("/file https://example.com/prompt.md", history.entries.items[0]);
}

test "add persists /file urls with an @ inside the path" {
    var history = History.init(std.testing.allocator, "");
    defer history.deinit();

    try history.add("/file https://example.com/repos/@user/prompt.md");
    try std.testing.expectEqual(@as(usize, 1), history.entries.items.len);
    try std.testing.expectEqualStrings("/file https://example.com/repos/@user/prompt.md", history.entries.items[0]);
}

test "add stores prompts and avoids consecutive duplicates" {
    var history = History.init(std.testing.allocator, "");
    defer history.deinit();

    try history.add("hello");
    try history.add("hello");
    try history.add("world");
    try std.testing.expectEqual(@as(usize, 2), history.entries.items.len);
    try std.testing.expectEqualStrings("hello", history.entries.items[0]);
    try std.testing.expectEqualStrings("world", history.entries.items[1]);
}

test "clear removes all entries and resets navigation" {
    var history = History.init(std.testing.allocator, "");
    defer history.deinit();

    try history.add("first");
    try history.add("second");
    _ = history.previous("draft");
    try std.testing.expectEqual(@as(usize, 2), history.entries.items.len);
    try std.testing.expect(history.saved_current != null);

    history.clear();

    try std.testing.expectEqual(@as(usize, 0), history.entries.items.len);
    try std.testing.expectEqual(@as(?usize, null), history.browsing_index);
    try std.testing.expectEqual(@as(?[]const u8, null), history.saved_current);

    try history.add("after");
    try std.testing.expectEqual(@as(usize, 1), history.entries.items.len);
    try std.testing.expectEqualStrings("after", history.entries.items[0]);
}

test "navigation moves through history and restores current draft" {
    var history = History.init(std.testing.allocator, "");
    defer history.deinit();

    try history.add("first");
    try history.add("second");
    try history.add("third");

    try std.testing.expectEqualStrings("third", history.previous("current draft").?);
    try std.testing.expectEqualStrings("second", history.previous("ignored").?);
    try std.testing.expectEqualStrings("first", history.previous("ignored").?);
    try std.testing.expectEqual(@as(?[]const u8, null), history.previous("ignored"));

    try std.testing.expectEqualStrings("second", history.next().?);
    try std.testing.expectEqualStrings("third", history.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), history.next());
    try std.testing.expectEqualStrings("current draft", history.currentDraft().?);
}

test "reset navigation clears browsing state" {
    var history = History.init(std.testing.allocator, "");
    defer history.deinit();

    try history.add("entry");
    _ = history.previous("draft");
    history.resetNavigation();

    try std.testing.expectEqual(@as(?usize, null), history.browsing_index);
    try std.testing.expectEqual(@as(?[]const u8, null), history.saved_current);
}

test "load and save round trip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);

    const path = try std.fs.path.join(allocator, &.{ cwd, "zig-out", "test-prompt-history.json" });
    defer allocator.free(path);

    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    {
        var history = History.init(allocator, path);
        try history.add("alpha");
        try history.add("beta");
        try history.save(io);
        history.deinit();
    }

    {
        var history = History.init(allocator, path);
        defer history.deinit();
        try history.load(io);
        try std.testing.expectEqual(@as(usize, 2), history.entries.items.len);
        try std.testing.expectEqualStrings("alpha", history.entries.items[0]);
        try std.testing.expectEqualStrings("beta", history.entries.items[1]);
    }

    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "save tolerates inaccessible history path" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);

    const obstructing_path = try std.fs.path.join(allocator, &.{ cwd, "zig-out", "test-history-obstruction" });
    defer allocator.free(obstructing_path);

    std.Io.Dir.cwd().deleteFile(io, obstructing_path) catch {};

    {
        var file = try std.Io.Dir.cwd().createFile(io, obstructing_path, .{});
        defer file.close(io);
    }
    defer std.Io.Dir.cwd().deleteFile(io, obstructing_path) catch {};

    const history_path = try std.fs.path.join(allocator, &.{ obstructing_path, "prompt_history.json" });
    defer allocator.free(history_path);

    var history = History.init(allocator, history_path);
    defer history.deinit();
    try history.add("alpha");

    try history.save(io);
}

test "save writes history with owner-only permissions" {
    if (comptime builtin.os.tag == .windows) return;

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);

    const path = try std.fs.path.join(allocator, &.{ cwd, "zig-out", "test-history-permissions.json" });
    defer allocator.free(path);

    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    {
        var history = History.init(allocator, path);
        try history.add("alpha");
        try history.save(io);
        history.deinit();
    }

    const st = try std.Io.Dir.cwd().statFile(io, path, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0), st.permissions.toMode() & 0o077);

    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "history size is capped" {
    var history = History.init(std.testing.allocator, "");
    defer history.deinit();
    history.max_entries = 3;

    try history.add("a");
    try history.add("b");
    try history.add("c");
    try history.add("d");
    try std.testing.expectEqual(@as(usize, 3), history.entries.items.len);
    try std.testing.expectEqualStrings("b", history.entries.items[0]);
    try std.testing.expectEqualStrings("c", history.entries.items[1]);
    try std.testing.expectEqualStrings("d", history.entries.items[2]);
}
