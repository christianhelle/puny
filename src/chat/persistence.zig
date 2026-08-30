const std = @import("std");
const builtin = @import("builtin");
const context = @import("context.zig");
const core_session = @import("../core/session.zig");
const openai = @import("../providers/openai.zig");

const ChatLoopContext = context.ChatLoopContext;

/// Writes the current conversation to `messages.json` in the session
/// directory through a temp file plus an atomic rename, so an interrupted
/// write never leaves a truncated conversation on disk.
pub fn saveMessages(ctx: *ChatLoopContext) !void {
    const dir = ctx.session.dir;
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(ctx.io, dir) catch {};

    const tmp_path = try std.fs.path.join(ctx.messages_arena.allocator(), &.{ dir, "messages.json.tmp" });
    defer ctx.messages_arena.allocator().free(tmp_path);
    const msg_path = try std.fs.path.join(ctx.messages_arena.allocator(), &.{ dir, "messages.json" });
    defer ctx.messages_arena.allocator().free(msg_path);
    const buffer = try std.json.Stringify.valueAlloc(ctx.messages_arena.allocator(), ctx.messages.items, .{ .whitespace = .indent_2 });
    defer ctx.messages_arena.allocator().free(buffer);

    var file = cwd.createFile(ctx.io, tmp_path, .{}) catch |err| {
        std.log.warn("failed to create temp file: {s}", .{@errorName(err)});
        return;
    };
    errdefer {
        file.close(ctx.io);
        cwd.deleteFile(ctx.io, tmp_path) catch {};
    }

    file.writeStreamingAll(ctx.io, buffer) catch |err| {
        std.log.warn("failed to write messages: {s}", .{@errorName(err)});
        return;
    };
    file.writeStreamingAll(ctx.io, "\n") catch |err| {
        std.log.warn("failed to write newline: {s}", .{@errorName(err)});
        return;
    };
    file.close(ctx.io);

    std.Io.Dir.renameAbsolute(tmp_path, msg_path, ctx.io) catch |err| {
        std.log.warn("failed to rename messages file: {s}", .{@errorName(err)});
        std.Io.Dir.cwd().deleteFile(ctx.io, tmp_path) catch {};
    };
}

/// Persists the session metadata (`session.json`) with the current planning
/// mode and the first user prompt, used as the sessions-index preview.
pub fn saveSessionMeta(ctx: *ChatLoopContext) !void {
    const dir = ctx.session.dir;
    const meta_path = try std.fs.path.join(ctx.messages_arena.allocator(), &.{ dir, "session.json" });
    defer ctx.messages_arena.allocator().free(meta_path);

    const first_prompt = firstUserPrompt(ctx.messages.items);

    const MetaStruct = struct {
        planning_mode: bool,
        review_mode: bool,
        first_prompt: ?[]const u8,
    };
    const meta = MetaStruct{ .planning_mode = ctx.planning_mode.*, .review_mode = ctx.review_mode.*, .first_prompt = first_prompt };

    const buffer = try std.json.Stringify.valueAlloc(ctx.messages_arena.allocator(), meta, .{ .whitespace = .indent_2 });
    defer ctx.messages_arena.allocator().free(buffer);
    const cwd = std.Io.Dir.cwd();
    var file = cwd.createFile(ctx.io, meta_path, .{}) catch |err| {
        std.log.warn("failed to save session meta: {s}", .{@errorName(err)});
        return;
    };
    defer file.close(ctx.io);
    file.writeStreamingAll(ctx.io, buffer) catch {};
    file.writeStreamingAll(ctx.io, "\n") catch {};
}

/// Loads `messages.json` from `dir` into `ctx.messages`. A missing file is
/// reported and leaves the message list untouched.
pub fn loadMessagesIntoContext(ctx: *ChatLoopContext, dir: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const msg_path = try std.fs.path.join(ctx.messages_arena.allocator(), &.{ dir, "messages.json" });
    defer ctx.messages_arena.allocator().free(msg_path);

    const data = cwd.readFileAlloc(ctx.io, msg_path, ctx.messages_arena.allocator(), std.Io.Limit.limited(10 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            try ctx.stdout_writer.print("Session has no saved conversation.\n", .{});
            try ctx.stdout_writer.flush();
            return;
        },
        else => |e| return e,
    };
    defer ctx.messages_arena.allocator().free(data);

    const parsed = try std.json.parseFromSlice(std.json.Value, ctx.messages_arena.allocator(), data, .{});
    defer parsed.deinit();

    for (parsed.value.array.items) |item| {
        const msg = try openai.Message.fromJsonValue(ctx.messages_arena.allocator(), item);
        try ctx.messages.append(ctx.messages_arena.allocator(), msg);
    }
}

/// The first user message in the conversation, or null when there is none.
pub fn firstUserPrompt(messages: []const openai.Message) ?[]const u8 {
    for (messages) |m| {
        if (m == .user) return m.user;
    }
    return null;
}

fn testContext(
    io: std.Io,
    session: *core_session.Session,
    messages_arena: *std.heap.ArenaAllocator,
    messages: *std.ArrayList(openai.Message),
    planning_mode: *bool,
    review_mode: *bool,
    stdout_writer: *std.Io.Writer,
) ChatLoopContext {
    return .{
        .arena = std.testing.allocator,
        .messages_arena = messages_arena,
        .io = io,
        .init = undefined,
        .parsed = undefined,
        .cfg = undefined,
        .stdout_writer = stdout_writer,
        .random = undefined,
        .history = undefined,
        .prov = undefined,
        .model_provider = undefined,
        .provider_url = undefined,
        .model_key = undefined,
        .reasoning_effort = undefined,
        .full_tool_definitions = undefined,
        .planning_tool_definitions = undefined,
        .messages = messages,
        .planning_mode = planning_mode,
        .review_mode = review_mode,
        .session = session,
        .session_stats = undefined,
        .debug_log = null,
        .chat_log = null,
        .skill_registry = undefined,
    };
}

fn testSessionDir(tmp: std.testing.TmpDir, name: []const u8) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const dir = try std.fs.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, name });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    return dir;
}

test "firstUserPrompt returns the first user message or null" {
    const messages = [_]openai.Message{
        .{ .system = "system" },
        .{ .user = "hello" },
        .{ .assistant = .{ .content = "hi" } },
        .{ .user = "second" },
    };
    try std.testing.expectEqualStrings("hello", firstUserPrompt(&messages).?);

    const no_user = [_]openai.Message{
        .{ .system = "system" },
        .{ .assistant = .{ .content = "hi" } },
    };
    try std.testing.expect(firstUserPrompt(&no_user) == null);
}

test "saveMessages and loadMessagesIntoContext round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try testSessionDir(tmp, "persist-1");
    defer std.testing.allocator.free(dir);

    var messages_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena.allocator());
    try messages.append(messages_arena.allocator(), .{ .system = "system" });
    try messages.append(messages_arena.allocator(), .{ .user = "hello" });
    try messages.append(messages_arena.allocator(), .{ .assistant = .{ .content = "hi there" } });

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;
    var review_mode = false;
    var session = core_session.Session{
        .id = "persist-1",
        .base = "",
        .dir = dir,
        .prd_path = "",
        .html_path = "",
    };
    var ctx = testContext(std.testing.io, &session, &messages_arena, &messages, &planning_mode, &review_mode, &out.writer);
    try saveMessages(&ctx);

    // Load into a fresh arena and message list to prove the file round-trips.
    var loaded_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loaded_arena.deinit();
    var loaded = std.ArrayList(openai.Message).empty;
    defer loaded.deinit(loaded_arena.allocator());
    var load_ctx = testContext(std.testing.io, &session, &loaded_arena, &loaded, &planning_mode, &review_mode, &out.writer);
    try loadMessagesIntoContext(&load_ctx, dir);

    try std.testing.expectEqual(@as(usize, 3), loaded.items.len);
    try std.testing.expectEqualDeep(openai.Message{ .system = "system" }, loaded.items[0]);
    try std.testing.expectEqualDeep(openai.Message{ .user = "hello" }, loaded.items[1]);
    try std.testing.expectEqualDeep(openai.Message{ .assistant = .{ .content = "hi there" } }, loaded.items[2]);
}

test "saveSessionMeta persists planning mode and the first prompt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try testSessionDir(tmp, "persist-meta");
    defer std.testing.allocator.free(dir);

    var messages_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena.allocator());
    try messages.append(messages_arena.allocator(), .{ .system = "system" });
    try messages.append(messages_arena.allocator(), .{ .user = "hello" });

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = true;
    var review_mode = false;
    var session = core_session.Session{
        .id = "persist-meta",
        .base = "",
        .dir = dir,
        .prd_path = "",
        .html_path = "",
    };
    var ctx = testContext(std.testing.io, &session, &messages_arena, &messages, &planning_mode, &review_mode, &out.writer);
    try saveSessionMeta(&ctx);

    const meta_path = try std.fs.path.join(std.testing.allocator, &.{ dir, "session.json" });
    defer std.testing.allocator.free(meta_path);
    const meta = try core_session.readSessionMetaJson(std.testing.io, std.testing.allocator, meta_path);
    defer if (meta.first_prompt) |p| std.testing.allocator.free(p);

    try std.testing.expect(meta.planning_mode);
    try std.testing.expectEqualStrings("hello", meta.first_prompt.?);
}

test "saveSessionMeta writes a null first prompt when there are no user messages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try testSessionDir(tmp, "persist-meta-null");
    defer std.testing.allocator.free(dir);

    var messages_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena.allocator());
    try messages.append(messages_arena.allocator(), .{ .system = "system" });

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;
    var review_mode = false;
    var session = core_session.Session{
        .id = "persist-meta-null",
        .base = "",
        .dir = dir,
        .prd_path = "",
        .html_path = "",
    };
    var ctx = testContext(std.testing.io, &session, &messages_arena, &messages, &planning_mode, &review_mode, &out.writer);
    try saveSessionMeta(&ctx);

    const meta_path = try std.fs.path.join(std.testing.allocator, &.{ dir, "session.json" });
    defer std.testing.allocator.free(meta_path);
    const meta = try core_session.readSessionMetaJson(std.testing.io, std.testing.allocator, meta_path);
    defer if (meta.first_prompt) |p| std.testing.allocator.free(p);

    try std.testing.expect(!meta.planning_mode);
    try std.testing.expect(meta.first_prompt == null);
}

test "loadMessagesIntoContext reports a missing conversation" {
    var messages_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena.allocator());

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;
    var review_mode = false;
    var session = core_session.Session{
        .id = "missing",
        .base = "",
        .dir = "puny-test-missing-session-dir",
        .prd_path = "",
        .html_path = "",
    };
    var ctx = testContext(std.testing.io, &session, &messages_arena, &messages, &planning_mode, &review_mode, &out.writer);
    try loadMessagesIntoContext(&ctx, "puny-test-missing-session-dir");

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Session has no saved conversation.") != null);
    try std.testing.expectEqual(@as(usize, 0), messages.items.len);
}

test "saveMessages tolerates an unwritable session directory" {
    const file_path = "puny-test-save-fail.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};

    // A plain file where the session directory should be: createDirPath and
    // createFile both fail, so saveMessages warns and returns without error.
    var f = try std.Io.Dir.cwd().createFile(std.testing.io, file_path, .{});
    f.close(std.testing.io);

    var messages_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena.allocator());
    try messages.append(messages_arena.allocator(), .{ .user = "hello" });

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;
    var review_mode = false;
    var session = core_session.Session{
        .id = "save-fail",
        .base = "",
        .dir = file_path,
        .prd_path = "",
        .html_path = "",
    };
    var ctx = testContext(std.testing.io, &session, &messages_arena, &messages, &planning_mode, &review_mode, &out.writer);
    try saveMessages(&ctx);
}

test "saveSessionMeta tolerates an unwritable session directory" {
    const file_path = "puny-test-save-meta-fail.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};

    var f = try std.Io.Dir.cwd().createFile(std.testing.io, file_path, .{});
    f.close(std.testing.io);

    var messages_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena.allocator());
    try messages.append(messages_arena.allocator(), .{ .user = "hello" });

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = true;
    var review_mode = false;
    var session = core_session.Session{
        .id = "save-meta-fail",
        .base = "",
        .dir = file_path,
        .prd_path = "",
        .html_path = "",
    };
    var ctx = testContext(std.testing.io, &session, &messages_arena, &messages, &planning_mode, &review_mode, &out.writer);
    try saveSessionMeta(&ctx);
}

test "loadMessagesIntoContext propagates non-missing-file read errors" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const file_path = "puny-test-load-fail.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};

    // A plain file where the session directory should be, so reading
    // "<file>/messages.json" fails with NotDir instead of FileNotFound.
    var f = try std.Io.Dir.cwd().createFile(std.testing.io, file_path, .{});
    f.close(std.testing.io);

    var messages_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena.allocator());

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;
    var review_mode = false;
    var session = core_session.Session{
        .id = "load-fail",
        .base = "",
        .dir = file_path,
        .prd_path = "",
        .html_path = "",
    };
    var ctx = testContext(std.testing.io, &session, &messages_arena, &messages, &planning_mode, &review_mode, &out.writer);
    try std.testing.expectError(error.NotDir, loadMessagesIntoContext(&ctx, file_path));
    try std.testing.expectEqual(@as(usize, 0), messages.items.len);
}

test "saveMessages round-trips an empty conversation and cleans up the temp file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try testSessionDir(tmp, "persist-empty");
    defer std.testing.allocator.free(dir);

    var messages_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer messages_arena.deinit();
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(messages_arena.allocator());

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var planning_mode = false;
    var review_mode = false;
    var session = core_session.Session{
        .id = "persist-empty",
        .base = "",
        .dir = dir,
        .prd_path = "",
        .html_path = "",
    };
    var ctx = testContext(std.testing.io, &session, &messages_arena, &messages, &planning_mode, &review_mode, &out.writer);
    try saveMessages(&ctx);

    const msg_path = try std.fs.path.join(std.testing.allocator, &.{ dir, "messages.json" });
    defer std.testing.allocator.free(msg_path);
    _ = try std.Io.Dir.cwd().statFile(std.testing.io, msg_path, .{});

    const tmp_path = try std.fs.path.join(std.testing.allocator, &.{ dir, "messages.json.tmp" });
    defer std.testing.allocator.free(tmp_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, tmp_path, .{}));

    var loaded_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loaded_arena.deinit();
    var loaded = std.ArrayList(openai.Message).empty;
    defer loaded.deinit(loaded_arena.allocator());
    var load_ctx = testContext(std.testing.io, &session, &loaded_arena, &loaded, &planning_mode, &review_mode, &out.writer);
    try loadMessagesIntoContext(&load_ctx, dir);

    try std.testing.expectEqual(@as(usize, 0), loaded.items.len);
}
