const std = @import("std");
const http_client = @import("../providers/client.zig");
const provider = @import("../providers/provider.zig");

pub const DebugLog = struct {
    file: std.Io.File,
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,

    fn print(self: *DebugLog, comptime fmt: []const u8, args: anytype) void {
        self.writer.print(fmt, args) catch {};
    }

    fn printBody(self: *DebugLog, body: []const u8) void {
        const formatted = formatBody(self.allocator, body);
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
        log.print("  {s}: {s}\n", .{ h.name, redactHeaderValue(h.name, h.value) });
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
        log.print("  {s}: {s}\n", .{ h.name, redactHeaderValue(h.name, h.value) });
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

const FormattedBody = struct {
    text: []const u8,
    owned: bool,
};

/// Pretty-prints `body` when it is valid JSON, otherwise returns it unchanged.
/// `owned` is true only when `text` was allocated and must be freed.
/// Returns `"***"` for credential-bearing header names (case-insensitive)
/// so secrets never reach the debug log; everything else passes through.
fn redactHeaderValue(name: []const u8, value: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(name, "authorization") or
        std.ascii.eqlIgnoreCase(name, "cookie") or
        std.ascii.eqlIgnoreCase(name, "set-cookie") or
        std.ascii.eqlIgnoreCase(name, "proxy-authorization") or
        std.ascii.eqlIgnoreCase(name, "x-api-key") or
        std.ascii.eqlIgnoreCase(name, "api-key") or
        std.ascii.eqlIgnoreCase(name, "x-auth-token") or
        std.ascii.eqlIgnoreCase(name, "x-api-token") or
        std.ascii.eqlIgnoreCase(name, "x-access-token") or
        std.ascii.eqlIgnoreCase(name, "x-copilot-auth"))
    {
        return "***";
    }
    return value;
}

fn isSecretMemberName(name: []const u8) bool {
    const secret_names = [_][]const u8{
        "api_key",
        "apiKey",
        "api-key",
        "x-api-key",
        "token",
        "access_token",
        "authorization",
        "proxy-authorization",
        "secret",
        "password",
    };
    for (secret_names) |n| {
        if (std.ascii.eqlIgnoreCase(name, n)) return true;
    }
    return false;
}

fn isSecretQueryName(name: []const u8) bool {
    const secret_names = [_][]const u8{
        "api_key",
        "apikey",
        "api-key",
        "x-api-key",
        "key",
        "token",
        "access_token",
        "auth",
        "authorization",
        "signature",
        "secret",
        "password",
    };
    for (secret_names) |n| {
        if (std.ascii.eqlIgnoreCase(name, n)) return true;
    }
    return false;
}

/// Returns an allocated copy of `url` with the values of secret query
/// parameters replaced by `"***"`, or `null` when there is nothing to redact.
fn redactUrl(allocator: std.mem.Allocator, url: []const u8) ?[]const u8 {
    const query_start = std.mem.indexOfScalar(u8, url, '?') orelse return null;
    const query = url[query_start + 1 ..];

    var has_secret = false;
    var parts = std.mem.splitScalar(u8, query, '&');
    while (parts.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (isSecretQueryName(pair[0..eq])) {
            has_secret = true;
            break;
        }
    }
    if (!has_secret) return null;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    out.appendSlice(allocator, url[0 .. query_start + 1]) catch return null;
    var first = true;
    parts = std.mem.splitScalar(u8, query, '&');
    while (parts.next()) |pair| {
        if (!first) out.append(allocator, '&') catch return null;
        first = false;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse {
            out.appendSlice(allocator, pair) catch return null;
            continue;
        };
        if (isSecretQueryName(pair[0..eq])) {
            out.appendSlice(allocator, pair[0 .. eq + 1]) catch return null;
            out.appendSlice(allocator, "***") catch return null;
        } else {
            out.appendSlice(allocator, pair) catch return null;
        }
    }
    return out.toOwnedSlice(allocator) catch null;
}

fn logRequestLine(log: *DebugLog, method: std.http.Method, url: []const u8) void {
    if (redactUrl(log.allocator, url)) |masked| {
        log.print("{s} {s}\n", .{ @tagName(method), masked });
        log.allocator.free(masked);
    } else {
        log.print("{s} {s}\n", .{ @tagName(method), url });
    }
}

/// Replaces the values of credential-named JSON members with `"***"`,
/// recursively, so request/response bodies cannot leak secrets to the log.
fn redactSecretValues(value: *std.json.Value) void {
    switch (value.*) {
        .object => |obj| {
            const keys = obj.keys();
            const values = obj.values();
            for (keys, values) |key, *val| {
                if (isSecretMemberName(key)) {
                    val.* = .{ .string = "***" };
                } else {
                    redactSecretValues(val);
                }
            }
        },
        .array => |arr| {
            for (arr.items) |*item| redactSecretValues(item);
        },
        else => {},
    }
}

fn isPlainBoundary(c: u8) bool {
    return switch (c) {
        '&', ';', '{', '[', ',', '"', '\'', '(', '=', '\n', '\r', '\t', ' ', '*', ':' => true,
        else => false,
    };
}

fn isPlainValueTerminator(c: u8) bool {
    return switch (c) {
        '&', ';', ' ', '\n', '\r', '\t' => true,
        else => false,
    };
}

/// Masks the values of secret `name=value` and `"name": value` pairs in a body
/// that failed JSON parsing (e.g. form-encoded or truncated JSON), returning an
/// owned copy with the secrets starred out, or `null` when nothing matched.
fn redactPlainBody(allocator: std.mem.Allocator, body: []const u8) ?[]const u8 {
    const secret_names = [_][]const u8{
        "api_key",      "apiKey",   "api-key",       "x-api-key",
        "access_token", "token",    "authorization", "proxy-authorization",
        "secret",       "password", "key",           "signature",
        "auth",
    };

    const masked = allocator.dupe(u8, body) catch return null;

    var redacted = false;
    var i: usize = 0;
    while (i < masked.len) {
        // A name must sit at a token boundary so substrings inside words
        // (e.g. "key" in "monkey") never match.
        if (i > 0 and !isPlainBoundary(masked[i - 1])) {
            i += 1;
            continue;
        }

        const name = blk: {
            for (secret_names) |n| {
                if (std.ascii.startsWithIgnoreCase(masked[i..], n)) break :blk n;
            }
            break :blk null;
        } orelse {
            i += 1;
            continue;
        };

        var j = i + name.len;
        while (j < masked.len and (masked[j] == '"' or masked[j] == ' ' or masked[j] == '\t')) j += 1;
        if (j >= masked.len or (masked[j] != '=' and masked[j] != ':')) {
            i += 1;
            continue;
        }
        const delim = masked[j];
        j += 1;
        if (delim == '=') {
            while (j < masked.len and !isPlainValueTerminator(masked[j])) {
                masked[j] = '*';
                j += 1;
            }
        } else {
            while (j < masked.len and masked[j] == ' ') j += 1;
            if (j < masked.len and masked[j] == '"') {
                j += 1;
                while (j < masked.len and masked[j] != '"') {
                    masked[j] = '*';
                    j += 1;
                }
            } else {
                while (j < masked.len and !isPlainValueTerminator(masked[j]) and masked[j] != ',' and masked[j] != '}') {
                    masked[j] = '*';
                    j += 1;
                }
            }
        }
        redacted = true;
        i = j;
    }

    if (!redacted) {
        allocator.free(masked);
        return null;
    }
    return masked;
}

fn formatBody(allocator: std.mem.Allocator, body: []const u8) FormattedBody {
    if (body.len == 0) return .{ .text = body, .owned = false };
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        // Not valid JSON (e.g. form-encoded or truncated): best-effort redact
        // secret name=value / "name": value pairs before logging.
        if (redactPlainBody(allocator, body)) |masked| return .{ .text = masked, .owned = true };
        return .{ .text = body, .owned = false };
    };
    defer parsed.deinit();
    redactSecretValues(&parsed.value);
    const formatted = std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 }) catch return .{ .text = body, .owned = false };
    return .{ .text = formatted, .owned = true };
}

test "formatBody pretty-prints valid JSON" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const formatted = formatBody(allocator, "{\"a\":1,\"b\":[true,null,\"x\"]}");
    defer if (formatted.owned) allocator.free(formatted.text);
    try std.testing.expectEqualStrings(
        \\{
        \\  "a": 1,
        \\  "b": [
        \\    true,
        \\    null,
        \\    "x"
        \\  ]
        \\}
    , formatted.text);
    try std.testing.expect(formatted.owned);
}

test "formatBody returns plain text unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const body = "data: {\"hello\":\"world\"}\n\n";
    const formatted = formatBody(allocator, body);
    try std.testing.expectEqualStrings(body, formatted.text);
    try std.testing.expect(!formatted.owned);
}

test "formatBody returns malformed JSON unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const body = "{\"a\":1,}";
    const formatted = formatBody(allocator, body);
    try std.testing.expectEqualStrings(body, formatted.text);
    try std.testing.expect(!formatted.owned);
}

test "formatBody returns empty body unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const formatted = formatBody(allocator, "");
    try std.testing.expectEqualStrings("", formatted.text);
    try std.testing.expect(!formatted.owned);
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

test "formatBody redacts key-named JSON members" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const body = "{\"model\":\"gpt-4o\",\"api_key\":\"sk-leak\",\"nested\":{\"token\":\"t-1\",\"access_token\":\"at-2\",\"ok\":1},\"list\":[{\"apiKey\":\"k-3\"}],\"authorization\":\"Bearer hdr\"}";
    const formatted = formatBody(allocator, body);
    defer if (formatted.owned) allocator.free(formatted.text);

    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "sk-leak") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "t-1") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "at-2") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "k-3") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "hdr") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "\"model\": \"gpt-4o\"") != null);
    try std.testing.expect(std.mem.count(u8, formatted.text, "\"***\"") >= 5);
}

test "formatBody redacts secret member names case-insensitively" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const body = "{\"API_KEY\":\"sk-upper\",\"Access_Token\":\"tok-x\",\"Nested\":{\"Authorization\":\"Bearer hdr2\"},\"ok\":1}";
    const formatted = formatBody(allocator, body);
    defer if (formatted.owned) allocator.free(formatted.text);

    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "sk-upper") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "tok-x") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "hdr2") == null);
    try std.testing.expect(std.mem.count(u8, formatted.text, "\"***\"") >= 3);
}

test "formatBody redacts x-api-key and credential members" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const body = "{\"x-api-key\":\"sk-hdr\",\"api-key\":\"k-dash\",\"password\":\"p-1\",\"secret\":\"s-2\",\"ok\":1}";
    const formatted = formatBody(allocator, body);
    defer if (formatted.owned) allocator.free(formatted.text);

    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "sk-hdr") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "k-dash") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "p-1") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "s-2") == null);
    try std.testing.expect(std.mem.count(u8, formatted.text, "\"***\"") >= 4);
}

test "formatBody redacts secret pairs in a non-JSON body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    // Not valid JSON, so it falls through to plain-text redaction.
    const body = "api_key=sk-form-1&token=tok-9&model=gpt-4o";
    const formatted = formatBody(allocator, body);
    defer if (formatted.owned) allocator.free(formatted.text);

    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "sk-form-1") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "tok-9") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "model=gpt-4o") != null);
}

test "formatBody redacts secret pairs case-insensitively in a non-JSON body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    // Not valid JSON, so it falls through to plain-text redaction. Secret
    // names must match regardless of case, like the JSON and query paths.
    const body = "API_KEY=sk-form-upper&Token=tok-upper&model=gpt-4o";
    const formatted = formatBody(allocator, body);
    defer if (formatted.owned) allocator.free(formatted.text);

    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "sk-form-upper") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "tok-upper") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "model=gpt-4o") != null);
}

test "formatBody redacts secret pairs in a truncated JSON body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    // Truncated JSON: parse fails, but the credential must still be masked.
    const body = "{\"api_key\":\"sk-truncated\",\"model\":\"gpt-4o\"";
    const formatted = formatBody(allocator, body);
    defer if (formatted.owned) allocator.free(formatted.text);

    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "sk-truncated") == null);
}
