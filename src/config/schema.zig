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
        return .{
            .prefix = try allocator.dupe(u8, self.prefix),
            .suffix = try allocator.dupe(u8, self.suffix),
            .override = if (self.override) |value| try allocator.dupe(u8, value) else null,
        };
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

    pub fn clone(self: PromptsConfig, allocator: std.mem.Allocator) std.mem.Allocator.Error!PromptsConfig {
        return .{
            .system = try self.system.clone(allocator),
            .planning = try self.planning.clone(allocator),
        };
    }

    pub fn deinit(self: *PromptsConfig, allocator: std.mem.Allocator) void {
        self.system.deinit(allocator);
        self.planning.deinit(allocator);
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

    pub fn jsonStringify(v: Provider, jws: anytype) !void {
        // Serialize the persisted fields only; `stored_blob` and
        // `stored_plaintext` are in-memory retention of the original ciphertext
        // and decrypted key and must not reach config.json.
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
