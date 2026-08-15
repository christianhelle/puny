const std = @import("std");
const frontmatter = @import("frontmatter.zig");
const triggers = @import("triggers.zig");

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

            const fm = frontmatter.parseFrontmatter(content, self.allocator);
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

pub fn recordMatchesTrigger(record: *const SkillRecord, text: []const u8) bool {
    if (record.disable_model_invocation) return false;
    if (triggers.textContainsWord(text, record.name)) return true;
    if (record.triggers) |trigger_list| {
        for (trigger_list) |trigger| {
            if (triggers.textContainsWord(text, trigger)) return true;
        }
    }
    return false;
}
