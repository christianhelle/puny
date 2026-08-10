const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const provider = @import("../providers/provider.zig");
const opencode_zen = @import("../providers/opencode_zen.zig");
const opencode_go = @import("../providers/opencode_go.zig");
const copilot = @import("../providers/copilot.zig");
const secrets = @import("secrets.zig");

fn isValidUtf8(s: []const u8) bool {
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
    /// Original `enc:v1:` blob retained when decryption failed, so a later
    /// save does not discard the user's stored credential. Internal only:
    /// never serialized; `save` restores it into `apiKey` when unset.
    stored_blob: ?[]const u8 = null,

    pub fn clone(self: Provider, allocator: std.mem.Allocator) std.mem.Allocator.Error!Provider {
        return .{
            .name = self.name,
            .apiKey = if (self.apiKey) |value| try allocator.dupe(u8, value) else null,
            .url = try allocator.dupe(u8, self.url),
            .model = try allocator.dupe(u8, self.model),
            .reasoning_effort = if (self.reasoning_effort) |v| try allocator.dupe(u8, v) else null,
            .stored_blob = if (self.stored_blob) |v| try allocator.dupe(u8, v) else null,
        };
    }

    pub fn deinit(self: *Provider, allocator: std.mem.Allocator) void {
        if (self.apiKey) |key| allocator.free(key);
        allocator.free(self.url);
        allocator.free(self.model);
        if (self.reasoning_effort) |v| allocator.free(v);
        if (self.stored_blob) |v| allocator.free(v);
    }

    pub fn jsonStringify(v: Provider, jws: anytype) !void {
        // Serialize the persisted fields only; `stored_blob` is an in-memory
        // retention of the original ciphertext and must not reach config.json.
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
        return switch (kind) {
            .lmstudio => &self.providers[0],
            .opencode_zen => &self.providers[1],
            .opencode_go => &self.providers[2],
            .copilot => &self.providers[3],
            .mock => unreachable,
        };
    }

    pub fn providerEntryConst(self: *const Config, kind: provider.ModelProvider) *const Provider {
        return switch (kind) {
            .lmstudio => &self.providers[0],
            .opencode_zen => &self.providers[1],
            .opencode_go => &self.providers[2],
            .copilot => &self.providers[3],
            .mock => unreachable,
        };
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

pub fn load(allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) !LoadResult {
    const path = try configPath(allocator, environ_map);
    defer allocator.free(path);

    const cwd = std.Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, path, allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{ .config = Config.default() },
        else => |e| return e,
    };
    defer allocator.free(data);

    const parsed = std.json.parseFromSlice(Config, allocator, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
        const stderr_writer = &stderr_file_writer.interface;
        stderr_writer.print("Warning: failed to parse config at {s}: {s}\nUsing defaults.\n", .{ path, @errorName(err) }) catch {};
        stderr_writer.flush() catch {};
        return .{ .config = Config.default(), .had_error = true, .file_existed = true };
    };

    // Steal the parser's arena: strings live in the arena, not in a clone
    var cfg = parsed.value;
    const model = cfg.providerEntry(cfg.provider).model;
    if (!isValidUtf8(model)) {
        cfg.providerEntry(cfg.provider).model = "";
    }
    var arena = parsed.arena.*;
    const arena_alloc = arena.allocator();
    decryptStoredApiKeys(arena_alloc, io, environ_map, &cfg) catch {};
    allocator.destroy(parsed.arena);
    return .{ .config = cfg, .arena = arena, .file_existed = true };
}

/// Decrypts `enc:v1:` apiKey blobs in place, allocating the plaintext from
/// `allocator`. Fails soft per the PRD: a missing/corrupt key file or an
/// undecryptable blob warns to stderr and leaves that provider's key unset.
/// Legacy plaintext keys are left untouched (lazy migration on save).
fn decryptStoredApiKeys(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    cfg: *Config,
) !void {
    var warned_missing_key = false;
    var key_material: ?[secrets.key_length]u8 = null;

    for (&cfg.providers) |*p| {
        const api_key = p.apiKey orelse continue;
        if (api_key.len == 0 or !secrets.isEncrypted(api_key)) continue;

        // Retain the original ciphertext even on success: it lets `save` write
        // the unmodified key back verbatim instead of re-encrypting it.
        p.stored_blob = api_key;

        if (key_material == null) {
            key_material = secrets.loadKey(allocator, io, environ_map) catch |err| blk: {
                if (!warned_missing_key) {
                    var stderr_buffer: [1024]u8 = undefined;
                    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
                    const stderr_writer = &stderr_file_writer.interface;
                    stderr_writer.print(
                        "Warning: could not decrypt stored API keys: failed to load encryption key file ({s}).\nRun --reconfigure to re-enter your keys.\n",
                        .{@errorName(err)},
                    ) catch {};
                    stderr_writer.flush() catch {};
                    warned_missing_key = true;
                }
                break :blk null;
            };
        }

        const key = key_material orelse {
            if (!warned_missing_key) {
                var stderr_buffer: [1024]u8 = undefined;
                var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
                const stderr_writer = &stderr_file_writer.interface;
                stderr_writer.print(
                    "Warning: could not decrypt stored API keys: encryption key file is missing.\nRun --reconfigure to re-enter your keys.\n",
                    .{},
                ) catch {};
                stderr_writer.flush() catch {};
                warned_missing_key = true;
            }
            p.apiKey = null;
            continue;
        };

        p.apiKey = blk: {
            break :blk secrets.decrypt(allocator, key, api_key) catch |err| {
                var stderr_buffer: [1024]u8 = undefined;
                var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
                const stderr_writer = &stderr_file_writer.interface;
                stderr_writer.print(
                    "Warning: could not decrypt the stored API key for provider '{s}' ({s}). Re-enter it with --reconfigure.\n",
                    .{ @tagName(p.name), @errorName(err) },
                ) catch {};
                stderr_writer.flush() catch {};
                break :blk null;
            };
        };
    }
}

pub fn save(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    environ_map: *const std.process.Environ.Map,
) !void {
    const path = try configPath(allocator, environ_map);
    defer allocator.free(path);

    const dir = std.fs.path.dirname(path) orelse return error.BadPath;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dir);

    var to_write = config;

    // Decide what to persist for each provider key. `stored_blob` is the
    // original ciphertext retained by load, so a provider whose key is unset
    // (undecryptable) or unchanged since decrypt writes that ciphertext back
    // verbatim — an unrelated save must not depend on key material or churn
    // the blobs. Only genuinely fresh plaintext keys (stored_blob == null)
    // need encryption.
    var needs_encryption = false;
    var encrypt_index: [4]bool = .{ false, false, false, false };
    for (&to_write.providers, 0..) |*p, i| {
        const key = p.apiKey orelse {
            if (p.stored_blob) |blob| p.apiKey = blob;
            continue;
        };
        if (key.len == 0 or secrets.isEncrypted(key)) continue;
        if (p.stored_blob) |blob| {
            // Unmodified decrypted key: persist the original ciphertext.
            p.apiKey = blob;
            continue;
        }
        encrypt_index[i] = true;
        needs_encryption = true;
    }

    // Track the encrypted blobs allocated by this save so they can be freed
    // after writing; the caller's apiKey strings are never touched.
    var encrypted_blobs: [4]?[]const u8 = .{ null, null, null, null };
    defer {
        for (encrypted_blobs) |blob| {
            if (blob) |b| allocator.free(b);
        }
    }

    if (needs_encryption) {
        var random_source: std.Random.IoSource = .{ .io = io };
        const random = random_source.interface();
        const key = (try secrets.ensureKeyFile(allocator, io, environ_map, random)) orelse return error.InvalidEncryptionKey;
        for (&to_write.providers, 0..) |*p, i| {
            if (encrypt_index[i]) {
                p.apiKey = try secrets.encrypt(allocator, key, random, p.apiKey.?);
                encrypted_blobs[i] = p.apiKey;
            }
        }
    }

    const buffer = try std.json.Stringify.valueAlloc(allocator, to_write, .{ .whitespace = .indent_2 });
    defer allocator.free(buffer);

    // Write to a uniquely-named temporary file in the same directory and
    // atomically rename it over the target. The unique name keeps concurrent
    // saves (or a stale .tmp from a crashed run) from colliding on the same
    // staging file, and an interrupted save never leaves config.json empty or
    // truncated (it now holds the only copy of the encrypted credentials).
    var random_source: std.Random.IoSource = .{ .io = io };
    const random = random_source.interface();
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.{x}.tmp", .{ path, random.int(u64) });
    defer allocator.free(tmp_path);

    var file = try cwd.createFile(io, tmp_path, .{});
    var file_open = true;
    defer {
        if (file_open) file.close(io);
        cwd.deleteFile(io, tmp_path) catch {};
    }

    // Harden the temp file to 0600 before any encrypted credentials are
    // written, so a permissive umask cannot leak them while staging.
    if (comptime builtin.os.tag != .windows) {
        try cwd.setFilePermissions(io, tmp_path, @enumFromInt(0o600), .{});
    }

    try file.writeStreamingAll(io, buffer);
    try file.writeStreamingAll(io, "\n");
    file.close(io);
    file_open = false;

    try cwd.rename(tmp_path, cwd, path, io);
}

pub fn configPath(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const base = environ_map.get("APPDATA") orelse environ_map.get("USERPROFILE") orelse return error.NoConfigDir;
        return std.fs.path.join(allocator, &.{ base, "puny", "config.json" });
    }

    if (environ_map.get("XDG_CONFIG_HOME")) |base| {
        return std.fs.path.join(allocator, &.{ base, "puny", "config.json" });
    }

    const home = environ_map.get("HOME") orelse return error.NoConfigDir;
    return std.fs.path.join(allocator, &.{ home, ".config", "puny", "config.json" });
}

test "round-trip default config via JSON" {
    const allocator = std.testing.allocator;

    const original = Config.default();
    const buffer = try std.json.Stringify.valueAlloc(allocator, original, .{ .whitespace = .indent_2 });
    defer allocator.free(buffer);

    const parsed = try std.json.parseFromSlice(
        Config,
        allocator,
        buffer,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed },
    );
    defer parsed.deinit();

    var cloned = try parsed.value.clone(allocator);
    defer cloned.deinit(allocator);

    try std.testing.expectEqual(.lmstudio, cloned.provider);
    try std.testing.expectEqualStrings("http://127.0.0.1:1234", cloned.providerEntryConst(.lmstudio).url);
    try std.testing.expectEqualStrings("", cloned.providerEntryConst(.lmstudio).model);
}

test "resolvePrompt applies prefix, suffix, and override" {
    const allocator = std.testing.allocator;
    const cfg = Config{
        .prompts = .{
            .system = .{ .prefix = "[pre]", .suffix = "[suf]" },
            .planning = .{ .override = "overridden" },
        },
    };

    const system = try cfg.resolvePrompt(allocator, "system", "default");
    defer allocator.free(system);
    try std.testing.expectEqualStrings("[pre]default[suf]", system);

    const planning = try cfg.resolvePrompt(allocator, "planning", "default");
    defer allocator.free(planning);
    try std.testing.expectEqualStrings("overridden", planning);
}

test "isValidUtf8 rejects invalid bytes" {
    try std.testing.expect(isValidUtf8("ornith-1.0-35b"));
    try std.testing.expect(!isValidUtf8(&.{0xaa}));
}

test "can deserialize valid config JSON" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "provider": "lmstudio",
        \\  "providerUrl": "http://127.0.0.1:1234",
        \\  "model": "google/gemma-4-e2b",
        \\  "prompts": {
        \\    "system": {
        \\      "prefix": "",
        \\      "suffix": "",
        \\      "override": null
        \\    },
        \\    "planning": {
        \\      "prefix": "",
        \\      "suffix": "",
        \\      "override": null
        \\    }
        \\  }
        \\}
    ;

    const parsed = try std.json.parseFromSlice(
        Config,
        allocator,
        json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed },
    );
    defer parsed.deinit();
}

test "LoadResult.file_existed defaults to false" {
    const result: LoadResult = .{ .config = .{} };
    try std.testing.expect(!result.file_existed);
}

test "LoadResult.file_existed is true when loaded from parse error" {
    const result: LoadResult = .{ .config = .{}, .had_error = true, .file_existed = true };
    try std.testing.expect(result.file_existed);
    try std.testing.expect(result.had_error);
}

test "can serialize config to JSON" {
    const allocator = std.testing.allocator;
    var cfg = Config{
        .provider = .lmstudio,
    };
    cfg.providerEntry(.lmstudio).url = "http://127.0.0.1:1234";
    cfg.providerEntry(.lmstudio).model = "google/gemma-4-e2b";

    const buffer = try std.json.Stringify.valueAlloc(allocator, cfg, .{ .whitespace = .indent_2 });
    defer allocator.free(buffer);
}

test "reasoning_effort round-trip via JSON" {
    const allocator = std.testing.allocator;
    var cfg = Config{
        .provider = .opencode_go,
    };
    const entry = cfg.providerEntry(.opencode_go);
    entry.model = "deepseek-v4-pro";
    entry.reasoning_effort = "high";

    const buffer = try std.json.Stringify.valueAlloc(allocator, cfg, .{ .whitespace = .indent_2 });
    defer allocator.free(buffer);

    const parsed = try std.json.parseFromSlice(
        Config,
        allocator,
        buffer,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed },
    );
    defer parsed.deinit();

    var cloned = try parsed.value.clone(allocator);
    defer cloned.deinit(allocator);

    try std.testing.expectEqual(.opencode_go, cloned.provider);
    try std.testing.expectEqualStrings("deepseek-v4-pro", cloned.providerEntryConst(.opencode_go).model);
    try std.testing.expectEqualStrings("high", cloned.providerEntryConst(.opencode_go).reasoning_effort.?);
}

test "configPath prefers XDG_CONFIG_HOME on non-windows" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", "/xdg");
    try env.put("HOME", "/home/user");

    const path = try configPath(std.testing.allocator, &env);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/xdg/puny/config.json", path);
}

test "configPath falls back to HOME" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/user");

    const path = try configPath(std.testing.allocator, &env);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/home/user/.config/puny/config.json", path);
}

test "configPath errors without a config dir" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectError(error.NoConfigDir, configPath(std.testing.allocator, &env));
}

test "save and load round-trip through a temp HOME" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const home = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(home);
    try env.put("HOME", home);

    var cfg = Config.default();
    cfg.provider = .opencode_zen;
    cfg.providerEntry(.opencode_zen).url = "https://example.com";
    cfg.providerEntry(.opencode_zen).model = "gpt-4o";
    try save(std.testing.allocator, std.testing.io, cfg, &env);

    var loaded = try load(std.testing.allocator, std.testing.io, &env);
    defer loaded.deinit();
    try std.testing.expect(loaded.file_existed);
    try std.testing.expect(!loaded.had_error);
    try std.testing.expectEqual(.opencode_zen, loaded.config.provider);
    try std.testing.expectEqualStrings("https://example.com", loaded.config.providerEntryConst(.opencode_zen).url);
    try std.testing.expectEqualStrings("gpt-4o", loaded.config.providerEntryConst(.opencode_zen).model);
}

fn writeTestKeyFile(env: *const std.process.Environ.Map, key: [32]u8) !void {
    const path = try secrets.keyFilePath(std.testing.allocator, env);
    defer std.testing.allocator.free(path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(path).?);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = &key });
}

fn testConfigJson(api_key: []const u8) ![]const u8 {
    return std.fmt.allocPrint(std.testing.allocator,
        \\{{
        \\  "provider": "opencode_go",
        \\  "providers": [
        \\    {{ "name": "lmstudio", "apiKey": null, "url": "http://127.0.0.1:1234", "model": "", "reasoning_effort": null }},
        \\    {{ "name": "opencode_zen", "apiKey": null, "url": "https://opencode.ai/zen", "model": "", "reasoning_effort": null }},
        \\    {{ "name": "opencode_go", "apiKey": "{s}", "url": "https://opencode.ai/zen/go", "model": "", "reasoning_effort": null }},
        \\    {{ "name": "copilot", "apiKey": null, "url": "https://api.githubcopilot.com", "model": "", "reasoning_effort": null }}
        \\  ]
        \\}}
    , .{api_key});
}

fn writeTestConfig(env: *const std.process.Environ.Map, contents: []const u8) !void {
    const path = try configPath(std.testing.allocator, env);
    defer std.testing.allocator.free(path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(path).?);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = contents });
}

test "load decrypts an enc:v1 api key blob" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const home = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(home);
    try env.put("HOME", home);

    const key = [_]u8{0x5a} ** 32;
    try writeTestKeyFile(&env, key);

    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();
    const blob = try secrets.encrypt(std.testing.allocator, key, random, "sk-decrypted");
    defer std.testing.allocator.free(blob);

    const contents = try testConfigJson(blob);
    defer std.testing.allocator.free(contents);
    try writeTestConfig(&env, contents);

    var loaded = try load(std.testing.allocator, std.testing.io, &env);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("sk-decrypted", loaded.config.providerEntryConst(.opencode_go).apiKey.?);
}

test "load fails soft when the key file is missing" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const home = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(home);
    try env.put("HOME", home);

    const contents = try testConfigJson("enc:v1:AgICAgICAgICAgICAgICAgICAgICAgICqg9Ois5afuAGYNUfoYJVcmZrd+3L");
    defer std.testing.allocator.free(contents);
    try writeTestConfig(&env, contents);

    var loaded = try load(std.testing.allocator, std.testing.io, &env);
    defer loaded.deinit();
    try std.testing.expect(loaded.config.providerEntryConst(.opencode_go).apiKey == null);
    try std.testing.expect(loaded.file_existed);
}

test "save preserves an undecryptable stored api key blob" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const home = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(home);
    try env.put("HOME", home);

    const blob = "enc:v1:AgICAgICAgICAgICAgICAgICAgICAgICqg9Ois5afuAGYNUfoYJVcmZrd+3L";
    const contents = try testConfigJson(blob);
    defer std.testing.allocator.free(contents);
    try writeTestConfig(&env, contents);

    var loaded = try load(std.testing.allocator, std.testing.io, &env);
    defer loaded.deinit();
    try std.testing.expect(loaded.config.providerEntryConst(.opencode_go).apiKey == null);

    // A save after a failed decrypt must round-trip the ciphertext instead of
    // replacing it with null, and must not leak the internal field.
    try save(std.testing.allocator, std.testing.io, loaded.config, &env);

    const cfg_path = try configPath(std.testing.allocator, &env);
    defer std.testing.allocator.free(cfg_path);
    const raw = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, cfg_path, std.testing.allocator, std.Io.Limit.limited(1024 * 1024));
    defer std.testing.allocator.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, blob) != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "stored_blob") == null);
}

test "load fails soft for a single undecryptable provider (G1)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const home = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(home);
    try env.put("HOME", home);

    const key = [_]u8{0x6b} ** 32;
    try writeTestKeyFile(&env, key);

    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();
    const good_blob = try secrets.encrypt(std.testing.allocator, key, random, "good-key");
    defer std.testing.allocator.free(good_blob);

    // A blob that fails with the current key (wrong/stale key material).
    const stale_key = [_]u8{0x01} ** 32;
    const stale_blob = try secrets.encrypt(std.testing.allocator, stale_key, random, "stale-key");
    defer std.testing.allocator.free(stale_blob);

    const contents = try std.fmt.allocPrint(std.testing.allocator,
        \\{{
        \\  "provider": "opencode_go",
        \\  "providers": [
        \\    {{ "name": "lmstudio", "apiKey": null, "url": "http://127.0.0.1:1234", "model": "", "reasoning_effort": null }},
        \\    {{ "name": "opencode_zen", "apiKey": "{s}", "url": "https://opencode.ai/zen", "model": "", "reasoning_effort": null }},
        \\    {{ "name": "opencode_go", "apiKey": "{s}", "url": "https://opencode.ai/zen/go", "model": "", "reasoning_effort": null }},
        \\    {{ "name": "copilot", "apiKey": null, "url": "https://api.githubcopilot.com", "model": "", "reasoning_effort": null }}
        \\  ]
        \\}}
    , .{ stale_blob, good_blob });
    defer std.testing.allocator.free(contents);
    try writeTestConfig(&env, contents);

    var loaded = try load(std.testing.allocator, std.testing.io, &env);
    defer loaded.deinit();
    try std.testing.expect(loaded.config.providerEntryConst(.opencode_zen).apiKey == null);
    try std.testing.expectEqualStrings("good-key", loaded.config.providerEntryConst(.opencode_go).apiKey.?);
}

test "load leaves legacy plaintext api keys untouched (M2)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const home = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(home);
    try env.put("HOME", home);

    const contents = try testConfigJson("sk-legacy-plaintext");
    defer std.testing.allocator.free(contents);
    try writeTestConfig(&env, contents);

    var loaded = try load(std.testing.allocator, std.testing.io, &env);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("sk-legacy-plaintext", loaded.config.providerEntryConst(.opencode_go).apiKey.?);
}

test "save encrypts api keys and creates the key file" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const home = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(home);
    try env.put("HOME", home);

    var cfg = Config.default();
    cfg.providerEntry(.opencode_go).apiKey = "sk-plaintext-to-protect";
    try save(std.testing.allocator, std.testing.io, cfg, &env);

    const cfg_path = try configPath(std.testing.allocator, &env);
    defer std.testing.allocator.free(cfg_path);
    const raw = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, cfg_path, std.testing.allocator, std.Io.Limit.limited(1024 * 1024));
    defer std.testing.allocator.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "sk-plaintext-to-protect") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "enc:v1:") != null);

    const key_path = try secrets.keyFilePath(std.testing.allocator, &env);
    defer std.testing.allocator.free(key_path);
    _ = try std.Io.Dir.cwd().statFile(std.testing.io, key_path, .{});
}

test "save then load round-trips the api key" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const home = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(home);
    try env.put("HOME", home);

    var cfg = Config.default();
    cfg.providerEntry(.opencode_go).apiKey = "sk-roundtrip-key";
    try save(std.testing.allocator, std.testing.io, cfg, &env);

    var loaded = try load(std.testing.allocator, std.testing.io, &env);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("sk-roundtrip-key", loaded.config.providerEntryConst(.opencode_go).apiKey.?);
}

test "save does not re-encrypt an unmodified decrypted key" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const home = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(home);
    try env.put("HOME", home);

    const key = [_]u8{0x5a} ** 32;
    try writeTestKeyFile(&env, key);

    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();
    const blob = try secrets.encrypt(std.testing.allocator, key, random, "sk-decrypted");
    defer std.testing.allocator.free(blob);

    const contents = try testConfigJson(blob);
    defer std.testing.allocator.free(contents);
    try writeTestConfig(&env, contents);

    var loaded = try load(std.testing.allocator, std.testing.io, &env);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("sk-decrypted", loaded.config.providerEntryConst(.opencode_go).apiKey.?);

    // An unrelated save (nothing about the key changed) must write the original
    // ciphertext back verbatim, not re-encrypt with a fresh nonce.
    try save(std.testing.allocator, std.testing.io, loaded.config, &env);

    const cfg_path = try configPath(std.testing.allocator, &env);
    defer std.testing.allocator.free(cfg_path);
    const raw = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, cfg_path, std.testing.allocator, std.Io.Limit.limited(1024 * 1024));
    defer std.testing.allocator.free(raw);
    try std.testing.expect(std.mem.count(u8, raw, blob) == 1);
    try std.testing.expect(std.mem.count(u8, raw, "enc:v1:") == 1);
}

test "save does not create a key file when no api keys are set" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const home = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(home);
    try env.put("HOME", home);

    const cfg = Config.default();
    try save(std.testing.allocator, std.testing.io, cfg, &env);

    const key_path = try secrets.keyFilePath(std.testing.allocator, &env);
    defer std.testing.allocator.free(key_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, key_path, .{}));
}

test "save writes config.json with 0600 permissions" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const home = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(home);
    try env.put("HOME", home);

    var cfg = Config.default();
    cfg.providerEntry(.opencode_zen).apiKey = "sk-perms";
    try save(std.testing.allocator, std.testing.io, cfg, &env);

    const cfg_path = try configPath(std.testing.allocator, &env);
    defer std.testing.allocator.free(cfg_path);
    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, cfg_path, .{});
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
}

test "save leaves a stale config.json.tmp untouched" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const home = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(home);
    try env.put("HOME", home);

    // A stale staging file left behind by a crashed save must not be
    // clobbered or renamed over config.json by a later save.
    const cfg_path = try configPath(std.testing.allocator, &env);
    defer std.testing.allocator.free(cfg_path);
    const stale_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.tmp", .{cfg_path});
    defer std.testing.allocator.free(stale_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(cfg_path).?);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = stale_path, .data = "STALE-CONTENT" });

    try save(std.testing.allocator, std.testing.io, Config.default(), &env);

    // The stale file is untouched and config.json was written fresh.
    const stale = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, stale_path, std.testing.allocator, std.Io.Limit.limited(1024));
    defer std.testing.allocator.free(stale);
    try std.testing.expectEqualStrings("STALE-CONTENT", stale);

    var loaded = try load(std.testing.allocator, std.testing.io, &env);
    defer loaded.deinit();
    try std.testing.expect(loaded.file_existed);
    try std.testing.expect(!loaded.had_error);
}

test "save does not re-encrypt an already encrypted key" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const home = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(home);
    try env.put("HOME", home);

    const key = [_]u8{0x3c} ** 32;
    try writeTestKeyFile(&env, key);

    var cfg = Config.default();
    cfg.providerEntry(.opencode_go).apiKey = "enc:v1:AgICAgICAgICAgICAgICAgICAgICAgICqg9Ois5afuAGYNUfoYJVcmZrd+3L";
    try save(std.testing.allocator, std.testing.io, cfg, &env);

    const cfg_path = try configPath(std.testing.allocator, &env);
    defer std.testing.allocator.free(cfg_path);
    const raw = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, cfg_path, std.testing.allocator, std.Io.Limit.limited(1024 * 1024));
    defer std.testing.allocator.free(raw);
    try std.testing.expect(std.mem.count(u8, raw, "enc:v1:") == 1);
}
