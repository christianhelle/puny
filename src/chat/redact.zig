const std = @import("std");

/// Sanitizes request/response bodies and metadata before they are written to
/// the HTTP debug log, so credentials never leak into `puny_debug.log`.

pub const FormattedBody = struct {
    text: []const u8,
    owned: bool,
};

/// Pretty-prints `body` when it is valid JSON, otherwise returns it unchanged
/// (after a best-effort redaction of `name=value` / `"name": value` pairs).
/// `owned` is true only when `text` was allocated and must be freed.
pub fn formatBody(allocator: std.mem.Allocator, body: []const u8) FormattedBody {
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

/// Returns `"***"` for credential-bearing header names (case-insensitive) so
/// secrets never reach the debug log; everything else passes through.
pub fn redactHeaderValue(name: []const u8, value: []const u8) []const u8 {
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

/// Returns an allocated copy of `url` with the values of secret query
/// parameters replaced by `"***"`, or `null` when there is nothing to redact.
pub fn redactUrl(allocator: std.mem.Allocator, url: []const u8) ?[]const u8 {
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

test "redactHeaderValue masks credential-bearing headers" {
    try std.testing.expectEqualStrings("***", redactHeaderValue("authorization", "Bearer sk-secret"));
    try std.testing.expectEqualStrings("***", redactHeaderValue("x-api-key", "sk-xyz"));
    try std.testing.expectEqualStrings("***", redactHeaderValue("Set-Cookie", "session=abc"));
    try std.testing.expectEqualStrings("application/json", redactHeaderValue("content-type", "application/json"));
}

test "redactUrl masks secret query values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const masked = redactUrl(allocator, "https://example.com/models?api_key=sk-1&token=t-2&model=gpt-4o").?;
    defer allocator.free(masked);
    try std.testing.expect(std.mem.indexOf(u8, masked, "sk-1") == null);
    try std.testing.expect(std.mem.indexOf(u8, masked, "t-2") == null);
    try std.testing.expect(std.mem.indexOf(u8, masked, "model=gpt-4o") != null);
}

test "redactUrl returns null when no secret query is present" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    try std.testing.expectEqual(@as(?[]const u8, null), redactUrl(allocator, "https://example.com/models?model=gpt-4o"));
    try std.testing.expectEqual(@as(?[]const u8, null), redactUrl(allocator, "https://example.com/models"));
}
