const std = @import("std");
const http_client = @import("../providers/client.zig");
const provider = @import("../providers/provider.zig");
const redact = @import("redact.zig");

pub const DebugLog = struct {
    file: std.Io.File,
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,

    fn print(self: *DebugLog, comptime fmt: []const u8, args: anytype) void {
        self.writer.print(fmt, args) catch {};
    }

    fn printBody(self: *DebugLog, body: []const u8) void {
        const formatted = redact.formatBody(self.allocator, body);
        defer if (formatted.owned) self.allocator.free(formatted.text);
        self.print("{s}\n", .{formatted.text});
    }
};

pub fn attachHttpDebugObserver(prov: *provider.Provider, debug_log: *DebugLog) void {
    prov.setConfig(.{ .http_observer = httpDebugObserver(debug_log) });
}

fn httpDebugObserver(debug_log: *DebugLog) http_client.HttpObserver {
    return .{
        .ctx = debug_log,
        .onRequest = &logHttpRequest,
        .onResponse = &logHttpResponse,
        .onError = &logHttpError,
        .on_chunk = &logHttpChunk,
    };
}

fn logHttpRequest(ctx: ?*anyopaque, method: std.http.Method, url: []const u8, headers: []const std.http.Header, body: ?[]const u8) void {
    const log: *DebugLog = @ptrCast(@alignCast(ctx.?));
    log.print("=== REQUEST ===\n", .{});
    logRequestLine(log, method, url);
    log.print("Headers:\n", .{});
    for (headers) |h| {
        log.print("  {s}: {s}\n", .{ h.name, redact.redactHeaderValue(h.name, h.value) });
    }
    if (body) |b| {
        log.print("Body ({d} bytes):\n", .{b.len});
        log.printBody(b);
    }
}

fn logHttpResponse(ctx: ?*anyopaque, method: std.http.Method, url: []const u8, status: std.http.Status, headers: []const std.http.Header, body: []const u8, duration_ns: u64) void {
    const log: *DebugLog = @ptrCast(@alignCast(ctx.?));
    const ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    log.print("=== RESPONSE ===\n", .{});
    logRequestLine(log, method, url);
    log.print("Status: {d} ({s})\n", .{ @intFromEnum(status), @tagName(status) });
    log.print("Duration: {d:.2}ms\n", .{ms});
    log.print("Headers:\n", .{});
    for (headers) |h| {
        log.print("  {s}: {s}\n", .{ h.name, redact.redactHeaderValue(h.name, h.value) });
    }
    if (body.len > 0) {
        log.print("Body ({d} bytes):\n", .{body.len});
        log.printBody(body);
    }
}

fn logHttpError(ctx: ?*anyopaque, method: std.http.Method, url: []const u8, err_name: []const u8) void {
    const log: *DebugLog = @ptrCast(@alignCast(ctx.?));
    log.print("=== ERROR ===\n", .{});
    logRequestLine(log, method, url);
    log.print("Error: {s}\n", .{err_name});
}

fn logHttpChunk(ctx: ?*anyopaque, data: []const u8) void {
    const log: *DebugLog = @ptrCast(@alignCast(ctx.?));
    log.print("=== CHUNK ===\n", .{});
    log.printBody(data);
}

fn logRequestLine(log: *DebugLog, method: std.http.Method, url: []const u8) void {
    if (redact.redactUrl(log.allocator, url)) |masked| {
        log.print("{s} {s}\n", .{ @tagName(method), masked });
        log.allocator.free(masked);
    } else {
        log.print("{s} {s}\n", .{ @tagName(method), url });
    }
}

test "DebugLog printBody writes pretty-printed JSON to the log file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [4096]u8 = undefined;
    var file = try tmp.dir.createFile(std.testing.io, "debug.log", .{});
    defer file.close(std.testing.io);
    var file_writer = std.Io.File.Writer.init(file, std.testing.io, &buffer);
    var log = DebugLog{
        .file = file,
        .writer = &file_writer.interface,
        .allocator = std.testing.allocator,
    };

    log.printBody("{\"a\":1}");

    try file_writer.interface.flush();
    const content = try tmp.dir.readFileAlloc(std.testing.io, "debug.log", std.testing.allocator, std.Io.Limit.limited(64 * 1024));
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("{\n  \"a\": 1\n}\n", content);
}

test "logHttpRequest writes pretty-printed JSON body to the log file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [4096]u8 = undefined;
    var file = try tmp.dir.createFile(std.testing.io, "debug.log", .{});
    defer file.close(std.testing.io);
    var file_writer = std.Io.File.Writer.init(file, std.testing.io, &buffer);
    var log = DebugLog{
        .file = file,
        .writer = &file_writer.interface,
        .allocator = allocator,
    };

    const ctx: ?*anyopaque = @ptrCast(&log);
    logHttpRequest(ctx, .POST, "http://example.com", &.{}, "{\"a\":1}");

    try file_writer.interface.flush();
    const content = try tmp.dir.readFileAlloc(std.testing.io, "debug.log", allocator, std.Io.Limit.limited(64 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, content, "{\n  \"a\": 1\n}") != null);
}

test "logHttpResponse writes pretty-printed JSON body to the log file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [4096]u8 = undefined;
    var file = try tmp.dir.createFile(std.testing.io, "debug.log", .{});
    defer file.close(std.testing.io);
    var file_writer = std.Io.File.Writer.init(file, std.testing.io, &buffer);
    var log = DebugLog{
        .file = file,
        .writer = &file_writer.interface,
        .allocator = allocator,
    };

    const ctx: ?*anyopaque = @ptrCast(&log);
    logHttpResponse(ctx, .POST, "http://example.com", .ok, &.{}, "{\"a\":1}", 1_000_000);

    try file_writer.interface.flush();
    const content = try tmp.dir.readFileAlloc(std.testing.io, "debug.log", allocator, std.Io.Limit.limited(64 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, content, "{\n  \"a\": 1\n}") != null);
}

test "logHttpChunk writes pretty-printed JSON body to the log file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [4096]u8 = undefined;
    var file = try tmp.dir.createFile(std.testing.io, "debug.log", .{});
    defer file.close(std.testing.io);
    var file_writer = std.Io.File.Writer.init(file, std.testing.io, &buffer);
    var log = DebugLog{
        .file = file,
        .writer = &file_writer.interface,
        .allocator = allocator,
    };

    const ctx: ?*anyopaque = @ptrCast(&log);
    logHttpChunk(ctx, "{\"a\":1}");

    try file_writer.interface.flush();
    const content = try tmp.dir.readFileAlloc(std.testing.io, "debug.log", allocator, std.Io.Limit.limited(64 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, content, "{\n  \"a\": 1\n}") != null);
}

test "logHttpRequest redacts the authorization header value" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [4096]u8 = undefined;
    var file = try tmp.dir.createFile(std.testing.io, "debug.log", .{});
    defer file.close(std.testing.io);
    var file_writer = std.Io.File.Writer.init(file, std.testing.io, &buffer);
    var log = DebugLog{
        .file = file,
        .writer = &file_writer.interface,
        .allocator = allocator,
    };

    const headers = [_]std.http.Header{
        .{ .name = "authorization", .value = "Bearer sk-super-secret-123" },
        .{ .name = "content-type", .value = "application/json" },
    };
    logHttpRequest(@ptrCast(&log), .POST, "http://example.com", &headers, null);

    try file_writer.interface.flush();
    const content = try tmp.dir.readFileAlloc(std.testing.io, "debug.log", allocator, std.Io.Limit.limited(64 * 1024));
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "sk-super-secret-123") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "authorization: ***") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "content-type: application/json") != null);
}

test "logHttpRequest redacts api-key style header values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [4096]u8 = undefined;
    var file = try tmp.dir.createFile(std.testing.io, "debug.log", .{});
    defer file.close(std.testing.io);
    var file_writer = std.Io.File.Writer.init(file, std.testing.io, &buffer);
    var log = DebugLog{
        .file = file,
        .writer = &file_writer.interface,
        .allocator = allocator,
    };

    const headers = [_]std.http.Header{
        .{ .name = "x-api-key", .value = "sk-xyz-987" },
        .{ .name = "proxy-authorization", .value = "Basic c2VjcmV0" },
        .{ .name = "content-type", .value = "application/json" },
    };
    logHttpRequest(@ptrCast(&log), .POST, "http://example.com", &headers, null);

    try file_writer.interface.flush();
    const content = try tmp.dir.readFileAlloc(std.testing.io, "debug.log", allocator, std.Io.Limit.limited(64 * 1024));
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "sk-xyz-987") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Basic c2VjcmV0") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "x-api-key: ***") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "proxy-authorization: ***") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "content-type: application/json") != null);
}

test "logHttpRequest redacts secret query parameters in the URL" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [4096]u8 = undefined;
    var file = try tmp.dir.createFile(std.testing.io, "debug.log", .{});
    defer file.close(std.testing.io);
    var file_writer = std.Io.File.Writer.init(file, std.testing.io, &buffer);
    var log = DebugLog{
        .file = file,
        .writer = &file_writer.interface,
        .allocator = allocator,
    };

    logHttpRequest(@ptrCast(&log), .GET, "https://example.com/models?api_key=sk-query-1&token=tok-2&model=gpt-4o", &.{}, null);

    try file_writer.interface.flush();
    const content = try tmp.dir.readFileAlloc(std.testing.io, "debug.log", allocator, std.Io.Limit.limited(64 * 1024));
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "sk-query-1") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "tok-2") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "model=gpt-4o") != null);
}

test "logHttpRequest redacts the cookie header value" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [4096]u8 = undefined;
    var file = try tmp.dir.createFile(std.testing.io, "debug.log", .{});
    defer file.close(std.testing.io);
    var file_writer = std.Io.File.Writer.init(file, std.testing.io, &buffer);
    var log = DebugLog{
        .file = file,
        .writer = &file_writer.interface,
        .allocator = allocator,
    };

    const headers = [_]std.http.Header{
        .{ .name = "Cookie", .value = "session=sekrit-session-1; Path=/" },
        .{ .name = "content-type", .value = "application/json" },
    };
    logHttpRequest(@ptrCast(&log), .POST, "http://example.com", &headers, null);

    try file_writer.interface.flush();
    const content = try tmp.dir.readFileAlloc(std.testing.io, "debug.log", allocator, std.Io.Limit.limited(64 * 1024));
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "sekrit-session-1") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Cookie: ***") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "content-type: application/json") != null);
}

test "logHttpResponse redacts authorization and set-cookie header values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [4096]u8 = undefined;
    var file = try tmp.dir.createFile(std.testing.io, "debug.log", .{});
    defer file.close(std.testing.io);
    var file_writer = std.Io.File.Writer.init(file, std.testing.io, &buffer);
    var log = DebugLog{
        .file = file,
        .writer = &file_writer.interface,
        .allocator = allocator,
    };

    const headers = [_]std.http.Header{
        .{ .name = "Set-Cookie", .value = "session=abc123; HttpOnly" },
        .{ .name = "Authorization", .value = "Bearer sekrit" },
        .{ .name = "date", .value = "Mon, 01 Jan 2024" },
    };
    logHttpResponse(@ptrCast(&log), .POST, "http://example.com", .ok, &headers, "{}", 1_000_000);

    try file_writer.interface.flush();
    const content = try tmp.dir.readFileAlloc(std.testing.io, "debug.log", allocator, std.Io.Limit.limited(64 * 1024));
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "sekrit") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "abc123") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Set-Cookie: ***") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Authorization: ***") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "date: Mon, 01 Jan 2024") != null);
}

test "logHttpResponse skips the body when it is empty" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [4096]u8 = undefined;
    var file = try tmp.dir.createFile(std.testing.io, "debug.log", .{});
    defer file.close(std.testing.io);
    var file_writer = std.Io.File.Writer.init(file, std.testing.io, &buffer);
    var log = DebugLog{
        .file = file,
        .writer = &file_writer.interface,
        .allocator = allocator,
    };

    logHttpResponse(@ptrCast(&log), .GET, "http://example.com", .no_content, &.{}, "", 500_000);

    try file_writer.interface.flush();
    const content = try tmp.dir.readFileAlloc(std.testing.io, "debug.log", allocator, std.Io.Limit.limited(64 * 1024));
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "Body (") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Status: 204") != null);
}

test "logHttpError writes the error name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [4096]u8 = undefined;
    var file = try tmp.dir.createFile(std.testing.io, "debug.log", .{});
    defer file.close(std.testing.io);
    var file_writer = std.Io.File.Writer.init(file, std.testing.io, &buffer);
    var log = DebugLog{
        .file = file,
        .writer = &file_writer.interface,
        .allocator = allocator,
    };

    logHttpError(@ptrCast(&log), .POST, "http://example.com", "ConnectionRefused");

    try file_writer.interface.flush();
    const content = try tmp.dir.readFileAlloc(std.testing.io, "debug.log", allocator, std.Io.Limit.limited(64 * 1024));
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "=== ERROR ===") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "POST http://example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Error: ConnectionRefused") != null);
}

test "attachHttpDebugObserver installs callbacks on the provider" {
    var prov = provider.Provider{ .lmstudio = http_client.Client.init(std.testing.allocator, std.testing.io, "") };
    defer prov.deinit();

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var log = DebugLog{
        .file = undefined,
        .writer = &output.writer,
        .allocator = std.testing.allocator,
    };

    attachHttpDebugObserver(&prov, &log);

    switch (prov) {
        .lmstudio => |c| {
            const observer = c.http_observer orelse return error.MissingObserver;
            try std.testing.expect(observer.onRequest != null);
            try std.testing.expect(observer.onResponse != null);
            try std.testing.expect(observer.onError != null);
            try std.testing.expect(observer.on_chunk != null);
            try std.testing.expect(observer.ctx == @as(?*anyopaque, @ptrCast(&log)));
        },
        else => unreachable,
    }
}
