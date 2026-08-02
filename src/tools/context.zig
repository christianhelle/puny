const std = @import("std");
const skills = @import("../skills/skills.zig");

pub const PendingSkill = struct {
    name: []const u8,
    content: []const u8,
};

/// Per-app state that tools need to do their job. Passed to every tool
/// execution so tools don't have to reach for process globals.
pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    prd_path: []const u8 = "",
    html_path: []const u8 = "",
    write_blocked: bool = false,
    skills: *skills.Registry,
    pending_skills: std.ArrayList(PendingSkill) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, registry: *skills.Registry) ToolContext {
        return .{
            .allocator = allocator,
            .io = io,
            .skills = registry,
        };
    }

    pub fn deinit(self: *ToolContext) void {
        self.pending_skills.deinit(self.allocator);
    }

    /// Point the PRD paths at a session struct (duck-typed: anything with
    /// `prd_path` and `html_path` fields works). Call after creating or
    /// restoring a session so save_prd writes to the right folder.
    pub fn setSession(self: *ToolContext, session: anytype) void {
        self.prd_path = session.prd_path;
        self.html_path = session.html_path;
    }

    pub fn isWriteBlocked(self: *const ToolContext) bool {
        return self.write_blocked;
    }

    /// Queue a skill the model requested for loading. The chat loop drains
    /// the queue after the turn and injects each entry as a system message.
    pub fn enqueuePendingSkill(self: *ToolContext, name: []const u8, content: []const u8) void {
        const dup_name = self.allocator.dupe(u8, name) catch return;
        const dup_content = self.allocator.dupe(u8, content) catch return;
        self.pending_skills.append(self.allocator, .{ .name = dup_name, .content = dup_content }) catch {
            self.allocator.free(dup_name);
            self.allocator.free(dup_content);
            return;
        };
    }

    /// Pop the oldest pending skill, copying its name and content into the
    /// given allocator (the messages arena), or null when the queue is empty.
    pub fn takePendingSkill(self: *ToolContext, allocator: std.mem.Allocator) ?PendingSkill {
        if (self.pending_skills.items.len == 0) return null;
        const item = self.pending_skills.orderedRemove(0);
        return .{
            .name = allocator.dupe(u8, item.name) catch return null,
            .content = allocator.dupe(u8, item.content) catch return null,
        };
    }
};

test "ToolContext starts with empty session paths and no pending skills" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var registry = skills.Registry.init(arena_state.allocator());
    defer registry.deinit();

    var ctx = ToolContext.init(arena_state.allocator(), std.testing.io, &registry);
    defer ctx.deinit();

    try std.testing.expectEqualStrings("", ctx.prd_path);
    try std.testing.expectEqualStrings("", ctx.html_path);
    try std.testing.expect(!ctx.isWriteBlocked());
    try std.testing.expect(ctx.takePendingSkill(arena_state.allocator()) == null);
}

test "setSession copies prd and html paths from a session struct" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var registry = skills.Registry.init(arena_state.allocator());
    defer registry.deinit();

    var ctx = ToolContext.init(arena_state.allocator(), std.testing.io, &registry);
    defer ctx.deinit();

    const fake_session = .{ .prd_path = "/sessions/abc/plan.md", .html_path = "/sessions/abc/plan.html" };
    ctx.setSession(fake_session);

    try std.testing.expectEqualStrings("/sessions/abc/plan.md", ctx.prd_path);
    try std.testing.expectEqualStrings("/sessions/abc/plan.html", ctx.html_path);
}

test "pending skills drain in FIFO order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var registry = skills.Registry.init(arena_state.allocator());
    defer registry.deinit();

    var ctx = ToolContext.init(arena_state.allocator(), std.testing.io, &registry);
    defer ctx.deinit();

    ctx.enqueuePendingSkill("grill-me", "content one");
    ctx.enqueuePendingSkill("nano-commits", "content two");

    const first = ctx.takePendingSkill(arena_state.allocator()).?;
    try std.testing.expectEqualStrings("grill-me", first.name);
    try std.testing.expectEqualStrings("content one", first.content);

    const second = ctx.takePendingSkill(arena_state.allocator()).?;
    try std.testing.expectEqualStrings("nano-commits", second.name);
    try std.testing.expectEqualStrings("content two", second.content);

    try std.testing.expect(ctx.takePendingSkill(arena_state.allocator()) == null);
}
