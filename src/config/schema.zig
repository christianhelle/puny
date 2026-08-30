const std = @import("std");
const build_options = @import("build_options");
const provider = @import("../providers/provider.zig");
const opencode_zen = @import("../providers/opencode_zen.zig");
const opencode_go = @import("../providers/opencode_go.zig");
const copilot = @import("../providers/copilot.zig");

pub fn isValidUtf8(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return false;
        if (i + len > s.len) return false;
        _ = std.unicode.utf8Decode(s[i..][0..len]) catch return false;
        i += len;
    }
    return true;
}

pub const default_lm_studio_url =
    if (build_options.docker) "http://host.docker.internal:1234" else "http://127.0.0.1:1234";

pub const PromptOverride = struct {
    prefix: []const u8 = "",
    suffix: []const u8 = "",
    override: ?[]const u8 = null,

    pub fn clone(self: PromptOverride, allocator: std.mem.Allocator) std.mem.Allocator.Error!PromptOverride {
        const prefix = try allocator.dupe(u8, self.prefix);
        errdefer allocator.free(prefix);
        const suffix = try allocator.dupe(u8, self.suffix);
        errdefer allocator.free(suffix);
        const override = if (self.override) |value| try allocator.dupe(u8, value) else null;
        return .{ .prefix = prefix, .suffix = suffix, .override = override };
    }

    pub fn deinit(self: *PromptOverride, allocator: std.mem.Allocator) void {
        allocator.free(self.prefix);
        allocator.free(self.suffix);
        if (self.override) |value| allocator.free(value);
    }
};

pub const PromptsConfig = struct {
    system: PromptOverride = .{},
    planning: PromptOverride = .{},
    review: PromptOverride = .{},

    pub fn clone(self: PromptsConfig, allocator: std.mem.Allocator) std.mem.Allocator.Error!PromptsConfig {
        var system = try self.system.clone(allocator);
        errdefer system.deinit(allocator);
        var planning = try self.planning.clone(allocator);
        errdefer planning.deinit(allocator);
        const review = try self.review.clone(allocator);
        return .{ .system = system, .planning = planning, .review = review };
    }

    pub fn deinit(self: *PromptsConfig, allocator: std.mem.Allocator) void {
        self.system.deinit(allocator);
        self.planning.deinit(allocator);
        self.review.deinit(allocator);
    }
};

pub const Provider = struct {
    name: provider.ModelProvider,
    apiKey: ?[]const u8,
    url: []const u8,
    model: []const u8,
    reasoning_effort: ?[]const u8 = null,
    /// Original `enc:v1:` blob retained by load, so a later save writes an
    /// unchanged key back verbatim and does not discard an undecryptable
    /// credential. Internal only: never serialized.
    stored_blob: ?[]const u8 = null,
    /// Plaintext that was already on disk for this provider: the plaintext the
    /// retained `stored_blob` was decrypted to, or a legacy clear-text key read
    /// directly. Lets `save` tell an unchanged key from a newly-typed one and
    /// preserve keys that were already persisted when encryption is impossible.
    /// Internal only: never serialized; null for a freshly-entered key.
    stored_plaintext: ?[]const u8 = null,

    pub fn clone(self: Provider, allocator: std.mem.Allocator) std.mem.Allocator.Error!Provider {
        return .{
            .name = self.name,
            .apiKey = if (self.apiKey) |value| try allocator.dupe(u8, value) else null,
            .url = try allocator.dupe(u8, self.url),
            .model = try allocator.dupe(u8, self.model),
            .reasoning_effort = if (self.reasoning_effort) |v| try allocator.dupe(u8, v) else null,
            .stored_blob = if (self.stored_blob) |v| try allocator.dupe(u8, v) else null,
            .stored_plaintext = if (self.stored_plaintext) |v| try allocator.dupe(u8, v) else null,
        };
    }

    pub fn deinit(self: *Provider, allocator: std.mem.Allocator) void {
        if (self.apiKey) |key| allocator.free(key);
        allocator.free(self.url);
        allocator.free(self.model);
        if (self.reasoning_effort) |v| allocator.free(v);
        if (self.stored_blob) |v| allocator.free(v);
        if (self.stored_plaintext) |v| allocator.free(v);
    }

    fn validateString(value: []const u8) !void {
        if (!isValidUtf8(value)) return error.InvalidUtf8;
    }

    fn validateOptionalString(value: ?[]const u8) !void {
        if (value) |inner| try validateString(inner);
    }

    pub fn validatePersistedStrings(v: Provider) !void {
        try validateString(v.url);
        try validateString(v.model);
        try validateOptionalString(v.apiKey);
        try validateOptionalString(v.reasoning_effort);
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const value = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, value, options);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !@This() {
        if (source != .object) return error.UnexpectedToken;

        var result: @This() = .{
            .name = .lmstudio,
            .apiKey = null,
            .url = default_lm_studio_url,
            .model = "",
        };

        var it = source.object.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.eql(u8, key, "stored_blob") or std.mem.eql(u8, key, "stored_plaintext")) {
                continue;
            }
            if (std.mem.eql(u8, key, "name")) {
                result.name = try std.json.parseFromValueLeaky(provider.ModelProvider, allocator, entry.value_ptr.*, options);
            } else if (std.mem.eql(u8, key, "apiKey")) {
                result.apiKey = try std.json.parseFromValueLeaky(?[]const u8, allocator, entry.value_ptr.*, options);
            } else if (std.mem.eql(u8, key, "url")) {
                result.url = try std.json.parseFromValueLeaky([]const u8, allocator, entry.value_ptr.*, options);
            } else if (std.mem.eql(u8, key, "model")) {
                result.model = try std.json.parseFromValueLeaky([]const u8, allocator, entry.value_ptr.*, options);
            } else if (std.mem.eql(u8, key, "reasoning_effort")) {
                result.reasoning_effort = try std.json.parseFromValueLeaky(?[]const u8, allocator, entry.value_ptr.*, options);
            }
        }

        return result;
    }

    pub fn jsonStringify(v: Provider, jws: anytype) !void {
        // Serialize the persisted fields only; `stored_blob` and
        // `stored_plaintext` are in-memory retention of the original ciphertext
        // and decrypted key and must not reach config.json.
        validatePersistedStrings(v) catch return error.WriteFailed;
        try jws.beginObject();
        try jws.objectField("name");
        try jws.write(v.name);
        try jws.objectField("apiKey");
        try jws.write(v.apiKey);
        try jws.objectField("url");
        try jws.write(v.url);
        try jws.objectField("model");
        try jws.write(v.model);
        try jws.objectField("reasoning_effort");
        try jws.write(v.reasoning_effort);
        try jws.endObject();
    }
};

pub fn providerSlot(kind: provider.ModelProvider) usize {
    return switch (kind) {
        .lmstudio => 0,
        .opencode_zen => 1,
        .opencode_go => 2,
        .copilot => 3,
        .mock => unreachable,
    };
}

pub const Config = struct {
    provider: provider.ModelProvider = .lmstudio,
    prompts: PromptsConfig = .{},
    providers: [4]Provider = [4]Provider{
        .{ .name = .lmstudio, .url = default_lm_studio_url, .apiKey = null, .model = "" },
        .{ .name = .opencode_zen, .url = opencode_zen.default_base_url, .apiKey = null, .model = "" },
        .{ .name = .opencode_go, .url = opencode_go.default_base_url, .apiKey = null, .model = "" },
        .{ .name = .copilot, .url = copilot.default_base_url, .apiKey = null, .model = "" },
    },

    pub fn default() Config {
        return .{};
    }

    pub fn providerEntry(self: *Config, kind: provider.ModelProvider) *Provider {
        return &self.providers[providerSlot(kind)];
    }

    pub fn providerEntryConst(self: *const Config, kind: provider.ModelProvider) *const Provider {
        return &self.providers[providerSlot(kind)];
    }

    pub fn clone(self: Config, allocator: std.mem.Allocator) std.mem.Allocator.Error!Config {
        var providers: [4]Provider = undefined;
        for (&self.providers, &providers) |src, *dst| {
            dst.* = try src.clone(allocator);
        }
        return .{
            .provider = self.provider,
            .prompts = try self.prompts.clone(allocator),
            .providers = providers,
        };
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (&self.providers) |*p| p.deinit(allocator);
        self.prompts.deinit(allocator);
    }

    pub fn resolvePrompt(
        self: Config,
        allocator: std.mem.Allocator,
        comptime name: []const u8,
        default_prompt: []const u8,
    ) std.mem.Allocator.Error![]const u8 {
        const override: ?[]const u8, const prefix: []const u8, const suffix: []const u8 = switch (comptime std.meta.stringToEnum(
            std.meta.FieldEnum(PromptsConfig),
            name,
        ) orelse @compileError("unknown prompt name: " ++ name)) {
            .system => .{ self.prompts.system.override, self.prompts.system.prefix, self.prompts.system.suffix },
            .planning => .{ self.prompts.planning.override, self.prompts.planning.prefix, self.prompts.planning.suffix },
            .review => .{ self.prompts.review.override, self.prompts.review.prefix, self.prompts.review.suffix },
        };
        if (override) |value| return allocator.dupe(u8, value);
        if (prefix.len == 0 and suffix.len == 0) return allocator.dupe(u8, default_prompt);
        return std.mem.concat(allocator, u8, &.{ prefix, default_prompt, suffix });
    }
};

pub const LoadResult = struct {
    config: Config,
    had_error: bool = false,
    file_existed: bool = false,
    arena: ?std.heap.ArenaAllocator = null,

    pub fn deinit(self: *LoadResult) void {
        if (self.arena) |*a| {
            a.deinit();
        }
    }
};

test "isValidUtf8 accepts empty and multibyte strings" {
    try std.testing.expect(isValidUtf8(""));
    try std.testing.expect(isValidUtf8("héllo wörld"));
    try std.testing.expect(isValidUtf8("emoji: \xf0\x9f\x98\x80"));
}

test "isValidUtf8 rejects truncated and overlong sequences" {
    try std.testing.expect(!isValidUtf8(&.{ 0xE2, 0x82 }));
    try std.testing.expect(!isValidUtf8(&.{ 0xC0, 0x80 }));
    try std.testing.expect(!isValidUtf8(&.{ 0xF0, 0x9F, 0x98 }));
}

test "PromptOverride clone is a deep copy of every field" {
    const allocator = std.testing.allocator;
    const original = PromptOverride{ .prefix = "pre", .suffix = "suf", .override = "over" };

    var cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);
    try std.testing.expectEqualStrings("pre", cloned.prefix);
    try std.testing.expectEqualStrings("suf", cloned.suffix);
    try std.testing.expectEqualStrings("over", cloned.override.?);
    try std.testing.expect(cloned.prefix.ptr != original.prefix.ptr);
    try std.testing.expect(cloned.override.?.ptr != original.override.?.ptr);
}

test "PromptOverride clone handles a null override" {
    const allocator = std.testing.allocator;
    const original = PromptOverride{ .prefix = "", .suffix = "", .override = null };

    var cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);
    try std.testing.expect(cloned.override == null);
    try std.testing.expectEqualStrings("", cloned.prefix);
}

test "PromptsConfig clone deep-copies all entries" {
    const allocator = std.testing.allocator;
    const original = PromptsConfig{
        .system = .{ .prefix = "sys-pre" },
        .planning = .{ .override = "plan-over" },
        .review = .{ .suffix = "review-suffix" },
    };

    var cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);
    try std.testing.expectEqualStrings("sys-pre", cloned.system.prefix);
    try std.testing.expectEqualStrings("plan-over", cloned.planning.override.?);
    try std.testing.expectEqualStrings("review-suffix", cloned.review.suffix);
}

test "PromptsConfig clone releases earlier entries when review cloning fails" {
    const original = PromptsConfig{
        .system = .{ .prefix = "a", .suffix = "b", .override = "c" },
        .planning = .{ .prefix = "d", .suffix = "e", .override = "f" },
        .review = .{ .prefix = "g", .suffix = "h", .override = "i" },
    };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 6 });
    try std.testing.expectError(error.OutOfMemory, original.clone(failing.allocator()));
}

test "Provider clone deep-copies all fields" {
    const allocator = std.testing.allocator;
    const original = Provider{
        .name = .opencode_zen,
        .apiKey = "key-1",
        .url = "https://example.com",
        .model = "gpt-4o",
        .reasoning_effort = "high",
        .stored_blob = "enc:v1:blob",
        .stored_plaintext = "key-1",
    };

    var cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);
    try std.testing.expectEqual(.opencode_zen, cloned.name);
    try std.testing.expectEqualStrings("key-1", cloned.apiKey.?);
    try std.testing.expectEqualStrings("https://example.com", cloned.url);
    try std.testing.expectEqualStrings("gpt-4o", cloned.model);
    try std.testing.expectEqualStrings("high", cloned.reasoning_effort.?);
    try std.testing.expectEqualStrings("enc:v1:blob", cloned.stored_blob.?);
    try std.testing.expectEqualStrings("key-1", cloned.stored_plaintext.?);
}

test "Provider clone handles null optional fields" {
    const allocator = std.testing.allocator;
    const original = Provider{ .name = .copilot, .apiKey = null, .url = "", .model = "" };

    var cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);
    try std.testing.expect(cloned.apiKey == null);
    try std.testing.expect(cloned.reasoning_effort == null);
    try std.testing.expect(cloned.stored_blob == null);
    try std.testing.expect(cloned.stored_plaintext == null);
    try std.testing.expectEqualStrings("", cloned.url);
}

test "validatePersistedStrings accepts valid strings" {
    const v = Provider{ .name = .lmstudio, .apiKey = "k", .url = "u", .model = "m", .reasoning_effort = "r" };
    try v.validatePersistedStrings();
}

test "validatePersistedStrings rejects invalid UTF-8 in required and optional fields" {
    const bad_model = Provider{ .name = .lmstudio, .apiKey = null, .url = "ok", .model = &[_]u8{0xff} };
    try std.testing.expectError(error.InvalidUtf8, bad_model.validatePersistedStrings());

    const bad_url = Provider{ .name = .lmstudio, .apiKey = null, .url = &[_]u8{0xfe}, .model = "" };
    try std.testing.expectError(error.InvalidUtf8, bad_url.validatePersistedStrings());

    const bad_key = Provider{ .name = .lmstudio, .apiKey = &[_]u8{0x80}, .url = "ok", .model = "" };
    try std.testing.expectError(error.InvalidUtf8, bad_key.validatePersistedStrings());

    const bad_effort = Provider{ .name = .lmstudio, .apiKey = null, .url = "ok", .model = "", .reasoning_effort = &[_]u8{0x81} };
    try std.testing.expectError(error.InvalidUtf8, bad_effort.validatePersistedStrings());
}

test "jsonStringify fails on invalid UTF-8 instead of writing bad bytes" {
    const v = Provider{ .name = .lmstudio, .apiKey = null, .url = "ok", .model = &[_]u8{0xff} };

    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    try std.testing.expectError(error.WriteFailed, std.json.Stringify.value(v, .{}, &writer.writer));
}

test "Provider jsonParse applies defaults for missing fields" {
    const allocator = std.testing.allocator;
    const json = "{\"name\":\"opencode_go\"}";

    const parsed = try std.json.parseFromSlice(Provider, allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    try std.testing.expectEqual(.opencode_go, parsed.value.name);
    // The url default is the lmstudio base url regardless of the parsed name.
    try std.testing.expectEqualStrings(default_lm_studio_url, parsed.value.url);
    try std.testing.expectEqualStrings("", parsed.value.model);
    try std.testing.expect(parsed.value.apiKey == null);
}

test "Provider jsonParse reads all persisted fields" {
    const allocator = std.testing.allocator;
    const json = "{\"name\":\"copilot\",\"apiKey\":null,\"url\":\"https://api.example.com\",\"model\":\"gpt-5\",\"reasoning_effort\":\"low\"}";

    const parsed = try std.json.parseFromSlice(Provider, allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    try std.testing.expectEqual(.copilot, parsed.value.name);
    try std.testing.expect(parsed.value.apiKey == null);
    try std.testing.expectEqualStrings("https://api.example.com", parsed.value.url);
    try std.testing.expectEqualStrings("gpt-5", parsed.value.model);
    try std.testing.expectEqualStrings("low", parsed.value.reasoning_effort.?);
}

test "Provider jsonParseFromValue rejects non-object roots" {
    const value: std.json.Value = .{ .string = "not an object" };
    try std.testing.expectError(error.UnexpectedToken, Provider.jsonParseFromValue(std.testing.allocator, value, .{}));
}

test "Config clone is a deep copy independent of the original" {
    const allocator = std.testing.allocator;
    var src = Config.default();
    src.provider = .copilot;
    src.providerEntry(.copilot).apiKey = "sk-key";
    src.providerEntry(.copilot).model = "claude";
    src.prompts.system.prefix = "pre";
    src.prompts.planning.override = "ov";

    var cloned = try src.clone(allocator);
    defer cloned.deinit(allocator);

    try std.testing.expectEqual(.copilot, cloned.provider);
    try std.testing.expectEqualStrings("sk-key", cloned.providerEntryConst(.copilot).apiKey.?);
    try std.testing.expectEqualStrings("claude", cloned.providerEntryConst(.copilot).model);
    try std.testing.expectEqualStrings("pre", cloned.prompts.system.prefix);
    try std.testing.expectEqualStrings("ov", cloned.prompts.planning.override.?);

    try std.testing.expect(cloned.providerEntryConst(.copilot).apiKey.?.ptr != src.providerEntryConst(.copilot).apiKey.?.ptr);
    try std.testing.expect(cloned.providerEntryConst(.copilot).model.ptr != src.providerEntryConst(.copilot).model.ptr);
}

test "resolvePrompt returns the default when there is no decoration" {
    const allocator = std.testing.allocator;
    const cfg = Config.default();

    const result = try cfg.resolvePrompt(allocator, "planning", "default-prompt");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("default-prompt", result);
}

test "LoadResult deinit is a no-op without an arena" {
    var result = LoadResult{ .config = Config.default() };
    result.deinit();
    var with_error = LoadResult{ .config = Config.default(), .had_error = true, .file_existed = true };
    with_error.deinit();
}

test "resolvePrompt returns the override when set" {
    const allocator = std.testing.allocator;
    var cfg = Config.default();
    cfg.prompts.system.override = "custom system prompt";
    cfg.prompts.planning.override = "custom planning prompt";

    const system_result = try cfg.resolvePrompt(allocator, "system", "default-system");
    defer allocator.free(system_result);
    try std.testing.expectEqualStrings("custom system prompt", system_result);

    const planning_result = try cfg.resolvePrompt(allocator, "planning", "default-planning");
    defer allocator.free(planning_result);
    try std.testing.expectEqualStrings("custom planning prompt", planning_result);
}

test "resolvePrompt concatenates prefix and suffix around the default" {
    const allocator = std.testing.allocator;
    var cfg = Config.default();
    cfg.prompts.planning.prefix = "[pre] ";
    cfg.prompts.planning.suffix = " [/suf]";

    const result = try cfg.resolvePrompt(allocator, "planning", "default-prompt");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("[pre] default-prompt [/suf]", result);
}

test "resolvePrompt returns the plain default when only a prefix is set" {
    const allocator = std.testing.allocator;
    var cfg = Config.default();
    cfg.prompts.system.prefix = "[pre] ";

    const result = try cfg.resolvePrompt(allocator, "system", "default-prompt");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("[pre] default-prompt", result);
}

test "Provider jsonParseFromValue ignores internal stored fields" {
    const allocator = std.testing.allocator;
    const json = "{\"name\":\"lmstudio\",\"apiKey\":null,\"stored_blob\":\"enc:v1:secret\",\"stored_plaintext\":\"secret\"}";

    const parsed = try std.json.parseFromSlice(Provider, allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    try std.testing.expectEqual(.lmstudio, parsed.value.name);
    try std.testing.expect(parsed.value.stored_blob == null);
    try std.testing.expect(parsed.value.stored_plaintext == null);
}
