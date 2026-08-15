const std = @import("std");
const builtin = @import("builtin");
const provider = @import("../providers/provider.zig");
const opencode_zen = @import("../providers/opencode_zen.zig");
const opencode_go = @import("../providers/opencode_go.zig");
const copilot = @import("../providers/copilot.zig");

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
};

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