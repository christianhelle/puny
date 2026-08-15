const std = @import("std");
const builtin = @import("builtin");
const prompts = @import("./prompts.zig");
const provider = @import("./provider.zig");
const model_provider = @import("../providers/provider.zig");
const secrets = @import("secrets.zig");
const opencode_zen = @import("../providers/opencode_zen.zig");
const opencode_go = @import("../providers/opencode_go.zig");
const copilot = @import("../providers/copilot.zig");

pub const default_lm_studio_url = "http://127.0.0.1:1234";

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

pub const Config = struct {
    provider: model_provider.ModelProvider = .lmstudio,
    prompts: prompts.PromptsConfig = .{},
    providers: [4]provider.Provider = [4]provider.Provider{
        .{ .name = .lmstudio, .url = default_lm_studio_url, .apiKey = null, .model = "" },
        .{ .name = .opencode_zen, .url = opencode_zen.default_base_url, .apiKey = null, .model = "" },
        .{ .name = .opencode_go, .url = opencode_go.default_base_url, .apiKey = null, .model = "" },
        .{ .name = .copilot, .url = copilot.default_base_url, .apiKey = null, .model = "" },
    },

    pub fn default() Config {
        return .{};
    }

    pub fn providerEntry(self: *Config, kind: model_provider.ModelProvider) *provider.Provider {
        return switch (kind) {
            .lmstudio => &self.providers[0],
            .opencode_zen => &self.providers[1],
            .opencode_go => &self.providers[2],
            .copilot => &self.providers[3],
            .mock => unreachable,
        };
    }

    pub fn providerEntryConst(self: *const Config, kind: model_provider.ModelProvider) *const provider.Provider {
        return switch (kind) {
            .lmstudio => &self.providers[0],
            .opencode_zen => &self.providers[1],
            .opencode_go => &self.providers[2],
            .copilot => &self.providers[3],
            .mock => unreachable,
        };
    }

    pub fn clone(self: Config, allocator: std.mem.Allocator) std.mem.Allocator.Error!Config {
        var providers: [4]provider.Provider = undefined;
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
            std.meta.FieldEnum(prompts.PromptsConfig),
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
    if (!prompts.isValidUtf8(model)) {
        cfg.providerEntry(cfg.provider).model = "";
    }
    var arena = parsed.arena.*;
    const arena_alloc = arena.allocator();
    decryptStoredApiKeys(arena_alloc, io, environ_map, &cfg) catch {};
    allocator.destroy(parsed.arena);
    return .{ .config = cfg, .arena = arena, .file_existed = true };
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

    // Decide what to persist for each provider key.
    var needs_encryption = false;
    var encrypt_index: [4]bool = .{ false, false, false, false };
    var verbatim_index: [4]bool = .{ false, false, false, false };
    for (&to_write.providers, 0..) |*p, i| {
        const key = p.apiKey orelse {
            if (p.stored_blob) |blob| {
                if (p.stored_plaintext == null) p.apiKey = blob;
            }
            continue;
        };
        if (key.len == 0 or secrets.isEncrypted(key)) continue;
        if (p.stored_blob) |_| {
            if (p.stored_plaintext) |pt| {
                if (std.mem.eql(u8, key, pt)) {
                    verbatim_index[i] = true;
                    continue;
                }
            }
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

        var existing_key: ?[secrets.key_length]u8 = null;
        const KeyFileState = enum { missing, usable, malformed };
        const key_file_state: KeyFileState = blk: {
            const existing = secrets.loadKey(allocator, io, environ_map) catch |err| switch (err) {
                error.MalformedKeyFile => break :blk .malformed,
                else => return err,
            };
            existing_key = existing;
            break :blk if (existing != null) .usable else .missing;
        };

        const encryption_key: ?[secrets.key_length]u8 = switch (key_file_state) {
            .usable => existing_key,
            .missing => try secrets.ensureKeyFile(allocator, io, environ_map, random),
            .malformed => null,
        };

        if (encryption_key) |key| {
            for (&to_write.providers, 0..) |*p, i| {
                const reencrypt = encrypt_index[i] or (verbatim_index[i] and key_file_state == .missing);
                if (reencrypt) {
                    p.apiKey = try secrets.encrypt(allocator, key, random, p.apiKey.?);
                    encrypted_blobs[i] = p.apiKey;
                }
            }
        } else {
            var stderr_buffer: [1024]u8 = undefined;
            var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
            const stderr_writer = &stderr_file_writer.interface;
            stderr_writer.print(
                "Warning: the encryption key file is malformed; new API keys were not saved and stored keys could not be encrypted. Fix or remove it and re-enter your keys.\n",
                .{},
            ) catch {};
            stderr_writer.flush() catch {};
            for (0..4) |i| {
                if (encrypt_index[i]) {
                    const p = &to_write.providers[i];
                    const already_on_disk = p.stored_plaintext != null and std.mem.eql(u8, p.stored_plaintext.?, p.apiKey.?);
                    if (!already_on_disk) p.apiKey = null;
                }
            }
        }
    }

    // Unmodified decrypted keys that were not re-encrypted above write the
    // original ciphertext back verbatim.
    for (&to_write.providers, 0..) |*p, i| {
        if (verbatim_index[i] and encrypted_blobs[i] == null) {
            p.apiKey = p.stored_blob;
        }
    }

    const buffer = try std.json.Stringify.valueAlloc(allocator, to_write, .{ .whitespace = .indent_2 });
    defer allocator.free(buffer);

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

    if (builtin.os.tag != .windows) {
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

pub fn decryptStoredApiKeys(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    cfg: *Config,
) !void {
    var warned_missing_key = false;
    var key_attempted = false;
    var key_load_error: ?anyerror = null;
    var key_material: ?[secrets.key_length]u8 = null;

    for (&cfg.providers) |*p| {
        const api_key = p.apiKey orelse continue;
        if (api_key.len == 0) continue;
        if (!secrets.isEncrypted(api_key)) {
            // Legacy plaintext key read straight from disk. It was already
            // stored in clear text, so remember it: if a later save cannot
            // encrypt (malformed key file) it must preserve this key rather
            // than silently drop it.
            p.stored_plaintext = api_key;
            continue;
        }

        // Retain the original ciphertext even on success: it lets `save` write
        // the unmodified key back verbatim instead of re-encrypting it.
        p.stored_blob = api_key;

        // Attempt the key file load at most once, regardless of how many
        // providers carry a blob. A missing file yields a null key (not an
        // error), so without this guard every provider would re-open the path.
        if (!key_attempted) {
            key_attempted = true;
            if (secrets.loadKey(allocator, io, environ_map)) |key| {
                key_material = key;
            } else |err| {
                key_load_error = err;
            }
        }

        const key = key_material orelse {
            if (!warned_missing_key) {
                var stderr_buffer: [1024]u8 = undefined;
                var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
                const stderr_writer = &stderr_file_writer.interface;
                if (key_load_error) |err| {
                    if (err == error.MalformedKeyFile) {
                        stderr_writer.print(
                            "Warning: could not decrypt stored API keys: the encryption key file is malformed.\nRun --reconfigure to re-enter your keys.\n",
                            .{},
                        ) catch {};
                    } else {
                        stderr_writer.print(
                            "Warning: could not decrypt stored API keys: failed to load encryption key file ({s}).\nRun --reconfigure to re-enter your keys.\n",
                            .{@errorName(err)},
                        ) catch {};
                    }
                } else {
                    stderr_writer.print(
                        "Warning: could not decrypt stored API keys: encryption key file is missing.\nRun --reconfigure to re-enter your keys.\n",
                        .{},
                    ) catch {};
                }
                stderr_writer.flush() catch {};
                warned_missing_key = true;
            }
            p.apiKey = null;
            continue;
        };

        // Keep the decrypted plaintext alongside the blob so `save` can tell an
        // unchanged key from a newly-typed one before writing the blob back.
        const plaintext = secrets.decrypt(allocator, key, api_key) catch |err| {
            var stderr_buffer: [1024]u8 = undefined;
            var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
            const stderr_writer = &stderr_file_writer.interface;
            stderr_writer.print(
                "Warning: could not decrypt the stored API key for provider '{s}' ({s}). Re-enter it with --reconfigure.\n",
                .{ @tagName(p.name), @errorName(err) },
            ) catch {};
            stderr_writer.flush() catch {};
            p.apiKey = null;
            continue;
        };
        p.apiKey = plaintext;
        p.stored_plaintext = plaintext;
    }
}