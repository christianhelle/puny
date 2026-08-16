const std = @import("std");
const builtin = @import("builtin");
const schema = @import("schema.zig");
const secrets = @import("secrets.zig");

pub fn load(allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) !schema.LoadResult {
    const path = try configPath(allocator, environ_map);
    defer allocator.free(path);

    const cwd = std.Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, path, allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{ .config = schema.Config.default() },
        else => |e| return e,
    };
    defer allocator.free(data);

    const parsed = std.json.parseFromSlice(schema.Config, allocator, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
        const stderr_writer = &stderr_file_writer.interface;
        stderr_writer.print("Warning: failed to parse config at {s}: {s}\nUsing defaults.\n", .{ path, @errorName(err) }) catch {};
        stderr_writer.flush() catch {};
        return .{ .config = schema.Config.default(), .had_error = true, .file_existed = true };
    };

    var cfg = parsed.value;
    const model = cfg.providerEntry(cfg.provider).model;
    if (!schema.isValidUtf8(model)) {
        cfg.providerEntry(cfg.provider).model = "";
    }
    var arena = parsed.arena.*;
    const arena_alloc = arena.allocator();
    decryptStoredApiKeys(arena_alloc, io, environ_map, &cfg) catch {};
    allocator.destroy(parsed.arena);
    return .{ .config = cfg, .arena = arena, .file_existed = true };
}

fn decryptStoredApiKeys(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    cfg: *schema.Config,
) !void {
    var warned_missing_key = false;
    var key_attempted = false;
    var key_load_error: ?anyerror = null;
    var key_material: ?[secrets.key_length]u8 = null;

    for (&cfg.providers) |*p| {
        const api_key = p.apiKey orelse continue;
        if (api_key.len == 0) continue;
        if (!secrets.isEncrypted(api_key)) {
            p.stored_plaintext = api_key;
            continue;
        }

        p.stored_blob = api_key;

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

pub fn save(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: schema.Config,
    environ_map: *const std.process.Environ.Map,
) !void {
    const path = try configPath(allocator, environ_map);
    defer allocator.free(path);

    const dir = std.fs.path.dirname(path) orelse return error.BadPath;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dir);

    var to_write = config;

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

    for (&to_write.providers, 0..) |*p, i| {
        if (verbatim_index[i] and encrypted_blobs[i] == null) {
            p.apiKey = p.stored_blob;
        }
    }

    for (to_write.providers) |p| {
        try schema.Provider.validatePersistedStrings(p);
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

fn tempHomeEnv() !struct { tmp: std.testing.TmpDir, env: std.process.Environ.Map, home: []u8 } {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    errdefer env.deinit();
    const home = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    errdefer std.testing.allocator.free(home);
    try env.put("HOME", home);
    return .{ .tmp = tmp, .env = env, .home = home };
}

test "decryptStoredApiKeys decrypts encrypted provider keys" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fixture = try tempHomeEnv();
    defer fixture.tmp.cleanup();
    defer fixture.env.deinit();
    defer std.testing.allocator.free(fixture.home);

    const key = [_]u8{0x42} ** secrets.key_length;
    const path = try secrets.keyFilePath(std.testing.allocator, &fixture.env);
    defer std.testing.allocator.free(path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(path).?);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = &key });

    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();
    const plaintext = "sk-live-0123456789";
    const blob = try secrets.encrypt(std.testing.allocator, key, random, plaintext);
    defer std.testing.allocator.free(blob);

    var cfg = schema.Config.default();
    cfg.providerEntry(.lmstudio).apiKey = blob;
    defer {
        const provider = cfg.providerEntry(.lmstudio);
        if (provider.apiKey) |api_key| {
            std.testing.allocator.free(api_key);
            provider.apiKey = null;
            provider.stored_plaintext = null;
        }
    }

    try decryptStoredApiKeys(std.testing.allocator, std.testing.io, &fixture.env, &cfg);

    try std.testing.expectEqualStrings(plaintext, cfg.providerEntryConst(.lmstudio).apiKey.?);
    try std.testing.expectEqualStrings(blob, cfg.providerEntryConst(.lmstudio).stored_blob.?);
    try std.testing.expectEqualStrings(plaintext, cfg.providerEntryConst(.lmstudio).stored_plaintext.?);
}

test "decryptStoredApiKeys preserves undecryptable blobs when no key exists" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fixture = try tempHomeEnv();
    defer fixture.tmp.cleanup();
    defer fixture.env.deinit();
    defer std.testing.allocator.free(fixture.home);

    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();
    const key = [_]u8{0x11} ** secrets.key_length;
    const plaintext = "sk-live-undecryptable";
    const blob = try secrets.encrypt(std.testing.allocator, key, random, plaintext);
    defer std.testing.allocator.free(blob);

    var cfg = schema.Config.default();
    cfg.providerEntry(.lmstudio).apiKey = blob;

    try decryptStoredApiKeys(std.testing.allocator, std.testing.io, &fixture.env, &cfg);

    try std.testing.expect(cfg.providerEntryConst(.lmstudio).apiKey == null);
    try std.testing.expectEqualStrings(blob, cfg.providerEntryConst(.lmstudio).stored_blob.?);
    try std.testing.expect(cfg.providerEntryConst(.lmstudio).stored_plaintext == null);
}

test "save preserves a stored blob when the key is unchanged" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fixture = try tempHomeEnv();
    defer fixture.tmp.cleanup();
    defer fixture.env.deinit();
    defer std.testing.allocator.free(fixture.home);

    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();
    const key = [_]u8{0x77} ** secrets.key_length;
    const plaintext = "sk-live-unchanged";
    const blob = try secrets.encrypt(std.testing.allocator, key, random, plaintext);
    defer std.testing.allocator.free(blob);

    var cfg = schema.Config.default();
    cfg.providerEntry(.lmstudio).apiKey = plaintext;
    cfg.providerEntry(.lmstudio).stored_blob = blob;
    cfg.providerEntry(.lmstudio).stored_plaintext = plaintext;

    try save(std.testing.allocator, std.testing.io, cfg, &fixture.env);

    const path = try configPath(std.testing.allocator, &fixture.env);
    defer std.testing.allocator.free(path);
    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(data);

    const parsed = try std.json.parseFromSlice(schema.Config, std.testing.allocator, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    defer parsed.deinit();

    try std.testing.expectEqualStrings(blob, parsed.value.providerEntryConst(.lmstudio).apiKey.?);
}

test "save re-encrypts keys when the typed value changes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fixture = try tempHomeEnv();
    defer fixture.tmp.cleanup();
    defer fixture.env.deinit();
    defer std.testing.allocator.free(fixture.home);

    const key = [_]u8{0x88} ** secrets.key_length;
    const path = try secrets.keyFilePath(std.testing.allocator, &fixture.env);
    defer std.testing.allocator.free(path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(path).?);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = &key });

    var cfg = schema.Config.default();
    cfg.providerEntry(.lmstudio).apiKey = "sk-live-new-secret";
    cfg.providerEntry(.lmstudio).stored_blob = "enc:v1:old-blob";
    cfg.providerEntry(.lmstudio).stored_plaintext = "sk-live-old-secret";

    try save(std.testing.allocator, std.testing.io, cfg, &fixture.env);

    const config_path = try configPath(std.testing.allocator, &fixture.env);
    defer std.testing.allocator.free(config_path);
    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, config_path, std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(data);

    const parsed = try std.json.parseFromSlice(schema.Config, std.testing.allocator, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    defer parsed.deinit();

    try std.testing.expect(secrets.isEncrypted(parsed.value.providerEntryConst(.lmstudio).apiKey.?));
    try std.testing.expect(!std.mem.eql(u8, parsed.value.providerEntryConst(.lmstudio).apiKey.?, "sk-live-new-secret"));
}

fn writeConfigFile(fixture: anytype, content: []const u8) !void {
    const path = try configPath(std.testing.allocator, &fixture.env);
    defer std.testing.allocator.free(path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(path).?);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = content });
}

fn readConfigFile(fixture: anytype) !std.json.Parsed(schema.Config) {
    const path = try configPath(std.testing.allocator, &fixture.env);
    defer std.testing.allocator.free(path);
    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, std.Io.Limit.limited(1 << 20));
    defer std.testing.allocator.free(data);
    return try std.json.parseFromSlice(schema.Config, std.testing.allocator, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

/// Wraps a single provider JSON object into a config with all four provider
/// slots filled, matching the shape save() writes.
fn configJsonWithLmstudio(allocator: std.mem.Allocator, lmstudio_json: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{{\"providers\":[{s},{{\"name\":\"opencode_zen\"}},{{\"name\":\"opencode_go\"}},{{\"name\":\"copilot\"}}]}}", .{lmstudio_json});
}

test "load returns defaults when the config file does not exist" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fixture = try tempHomeEnv();
    defer fixture.tmp.cleanup();
    defer fixture.env.deinit();
    defer std.testing.allocator.free(fixture.home);

    var loaded = try load(std.testing.allocator, std.testing.io, &fixture.env);
    defer loaded.deinit();
    try std.testing.expect(!loaded.file_existed);
    try std.testing.expect(!loaded.had_error);
    try std.testing.expectEqual(.lmstudio, loaded.config.provider);
}

test "load falls back to defaults when the config file is malformed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fixture = try tempHomeEnv();
    defer fixture.tmp.cleanup();
    defer fixture.env.deinit();
    defer std.testing.allocator.free(fixture.home);

    try writeConfigFile(&fixture, "not json {{{");

    var loaded = try load(std.testing.allocator, std.testing.io, &fixture.env);
    defer loaded.deinit();
    try std.testing.expect(loaded.file_existed);
    try std.testing.expect(loaded.had_error);
    try std.testing.expectEqual(.lmstudio, loaded.config.provider);
}

test "load treats a config with invalid UTF-8 bytes as a parse failure" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fixture = try tempHomeEnv();
    defer fixture.tmp.cleanup();
    defer fixture.env.deinit();
    defer std.testing.allocator.free(fixture.home);

    // The JSON parser rejects invalid UTF-8 before the model check can run.
    try writeConfigFile(&fixture, "{\"provider\":\"lmstudio\",\"providers\":[{\"name\":\"lmstudio\",\"model\":\"\xff\"}]}");

    var loaded = try load(std.testing.allocator, std.testing.io, &fixture.env);
    defer loaded.deinit();
    try std.testing.expect(loaded.file_existed);
    try std.testing.expect(loaded.had_error);
    try std.testing.expectEqual(.lmstudio, loaded.config.provider);
}

test "load marks legacy plaintext API keys as stored_plaintext" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fixture = try tempHomeEnv();
    defer fixture.tmp.cleanup();
    defer fixture.env.deinit();
    defer std.testing.allocator.free(fixture.home);

    const json = try configJsonWithLmstudio(std.testing.allocator, "{\"name\":\"lmstudio\",\"apiKey\":\"sk-legacy-plain\",\"url\":\"http://127.0.0.1:1234\",\"model\":\"\"}");
    defer std.testing.allocator.free(json);
    try writeConfigFile(&fixture, json);

    var loaded = try load(std.testing.allocator, std.testing.io, &fixture.env);
    defer loaded.deinit();
    const entry = loaded.config.providerEntryConst(.lmstudio);
    try std.testing.expectEqualStrings("sk-legacy-plain", entry.apiKey.?);
    try std.testing.expectEqualStrings("sk-legacy-plain", entry.stored_plaintext.?);
    try std.testing.expect(entry.stored_blob == null);
}

test "load decrypts an encrypted API key via the key file" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fixture = try tempHomeEnv();
    defer fixture.tmp.cleanup();
    defer fixture.env.deinit();
    defer std.testing.allocator.free(fixture.home);

    const key = [_]u8{0x12} ** secrets.key_length;
    const key_path = try secrets.keyFilePath(std.testing.allocator, &fixture.env);
    defer std.testing.allocator.free(key_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(key_path).?);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = key_path, .data = &key });

    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();
    const blob = try secrets.encrypt(std.testing.allocator, key, random, "sk-live-secret");
    defer std.testing.allocator.free(blob);

    const lmstudio_json = try std.fmt.allocPrint(std.testing.allocator, "{{\"name\":\"lmstudio\",\"apiKey\":\"{s}\",\"url\":\"http://127.0.0.1:1234\",\"model\":\"\"}}", .{blob});
    defer std.testing.allocator.free(lmstudio_json);
    const json = try configJsonWithLmstudio(std.testing.allocator, lmstudio_json);
    defer std.testing.allocator.free(json);
    try writeConfigFile(&fixture, json);

    var loaded = try load(std.testing.allocator, std.testing.io, &fixture.env);
    defer loaded.deinit();
    const entry = loaded.config.providerEntryConst(.lmstudio);
    try std.testing.expectEqualStrings("sk-live-secret", entry.apiKey.?);
    try std.testing.expectEqualStrings(blob, entry.stored_blob.?);
    try std.testing.expectEqualStrings("sk-live-secret", entry.stored_plaintext.?);
}

test "load keeps an encrypted blob when the key file is missing" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fixture = try tempHomeEnv();
    defer fixture.tmp.cleanup();
    defer fixture.env.deinit();
    defer std.testing.allocator.free(fixture.home);

    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();
    const key = [_]u8{0x21} ** secrets.key_length;
    const blob = try secrets.encrypt(std.testing.allocator, key, random, "sk-undecryptable");
    defer std.testing.allocator.free(blob);

    const lmstudio_json = try std.fmt.allocPrint(std.testing.allocator, "{{\"name\":\"lmstudio\",\"apiKey\":\"{s}\",\"url\":\"http://127.0.0.1:1234\",\"model\":\"\"}}", .{blob});
    defer std.testing.allocator.free(lmstudio_json);
    const json = try configJsonWithLmstudio(std.testing.allocator, lmstudio_json);
    defer std.testing.allocator.free(json);
    try writeConfigFile(&fixture, json);

    var loaded = try load(std.testing.allocator, std.testing.io, &fixture.env);
    defer loaded.deinit();
    const entry = loaded.config.providerEntryConst(.lmstudio);
    try std.testing.expect(entry.apiKey == null);
    try std.testing.expectEqualStrings(blob, entry.stored_blob.?);
    try std.testing.expect(entry.stored_plaintext == null);
}

test "load clears an API key it cannot decrypt" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fixture = try tempHomeEnv();
    defer fixture.tmp.cleanup();
    defer fixture.env.deinit();
    defer std.testing.allocator.free(fixture.home);

    const wrong_key = [_]u8{0x33} ** secrets.key_length;
    const key_path = try secrets.keyFilePath(std.testing.allocator, &fixture.env);
    defer std.testing.allocator.free(key_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(key_path).?);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = key_path, .data = &wrong_key });

    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();
    const real_key = [_]u8{0x44} ** secrets.key_length;
    const blob = try secrets.encrypt(std.testing.allocator, real_key, random, "sk-mismatched");
    defer std.testing.allocator.free(blob);

    const lmstudio_json = try std.fmt.allocPrint(std.testing.allocator, "{{\"name\":\"lmstudio\",\"apiKey\":\"{s}\",\"url\":\"http://127.0.0.1:1234\",\"model\":\"\"}}", .{blob});
    defer std.testing.allocator.free(lmstudio_json);
    const json = try configJsonWithLmstudio(std.testing.allocator, lmstudio_json);
    defer std.testing.allocator.free(json);
    try writeConfigFile(&fixture, json);

    var loaded = try load(std.testing.allocator, std.testing.io, &fixture.env);
    defer loaded.deinit();
    const entry = loaded.config.providerEntryConst(.lmstudio);
    try std.testing.expect(entry.apiKey == null);
    try std.testing.expectEqualStrings(blob, entry.stored_blob.?);
}

test "save writes an already-encrypted API key verbatim" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fixture = try tempHomeEnv();
    defer fixture.tmp.cleanup();
    defer fixture.env.deinit();
    defer std.testing.allocator.free(fixture.home);

    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();
    const key = [_]u8{0x55} ** secrets.key_length;
    const blob = try secrets.encrypt(std.testing.allocator, key, random, "sk-live-secret");
    defer std.testing.allocator.free(blob);

    var cfg = schema.Config.default();
    cfg.providerEntry(.lmstudio).apiKey = blob;

    try save(std.testing.allocator, std.testing.io, cfg, &fixture.env);

    const written = try readConfigFile(&fixture);
    defer written.deinit();
    try std.testing.expectEqualStrings(blob, written.value.providerEntryConst(.lmstudio).apiKey.?);
}

test "save preserves an undecryptable stored blob when apiKey is null" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fixture = try tempHomeEnv();
    defer fixture.tmp.cleanup();
    defer fixture.env.deinit();
    defer std.testing.allocator.free(fixture.home);

    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();
    const key = [_]u8{0x61} ** secrets.key_length;
    const blob = try secrets.encrypt(std.testing.allocator, key, random, "sk-retained");
    defer std.testing.allocator.free(blob);

    var cfg = schema.Config.default();
    cfg.providerEntry(.lmstudio).apiKey = null;
    cfg.providerEntry(.lmstudio).stored_blob = blob;

    try save(std.testing.allocator, std.testing.io, cfg, &fixture.env);

    const written = try readConfigFile(&fixture);
    defer written.deinit();
    try std.testing.expectEqualStrings(blob, written.value.providerEntryConst(.lmstudio).apiKey.?);
}

test "save does not persist new keys when the key file is malformed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fixture = try tempHomeEnv();
    defer fixture.tmp.cleanup();
    defer fixture.env.deinit();
    defer std.testing.allocator.free(fixture.home);

    const key_path = try secrets.keyFilePath(std.testing.allocator, &fixture.env);
    defer std.testing.allocator.free(key_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(key_path).?);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = key_path, .data = "too-short" });

    var cfg = schema.Config.default();
    cfg.providerEntry(.lmstudio).apiKey = "sk-live-new-secret";

    try save(std.testing.allocator, std.testing.io, cfg, &fixture.env);

    const written = try readConfigFile(&fixture);
    defer written.deinit();
    try std.testing.expect(written.value.providerEntryConst(.lmstudio).apiKey == null);
}

test "save re-encrypts an unchanged key when another provider forces a missing key file" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fixture = try tempHomeEnv();
    defer fixture.tmp.cleanup();
    defer fixture.env.deinit();
    defer std.testing.allocator.free(fixture.home);

    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();
    const old_key = [_]u8{0x71} ** secrets.key_length;
    const blob = try secrets.encrypt(std.testing.allocator, old_key, random, "sk-lm-unchanged");
    defer std.testing.allocator.free(blob);

    var cfg = schema.Config.default();
    cfg.providerEntry(.lmstudio).apiKey = "sk-lm-unchanged";
    cfg.providerEntry(.lmstudio).stored_blob = blob;
    cfg.providerEntry(.lmstudio).stored_plaintext = "sk-lm-unchanged";
    cfg.providerEntry(.opencode_zen).apiKey = "sk-zen-new";

    try save(std.testing.allocator, std.testing.io, cfg, &fixture.env);

    const written = try readConfigFile(&fixture);
    defer written.deinit();
    const lm = written.value.providerEntryConst(.lmstudio).apiKey.?;
    const zen = written.value.providerEntryConst(.opencode_zen).apiKey.?;
    try std.testing.expect(secrets.isEncrypted(lm));
    try std.testing.expect(secrets.isEncrypted(zen));

    // Both keys are decryptable with the key file created by save.
    const loaded_key = (try secrets.loadKey(std.testing.allocator, std.testing.io, &fixture.env)).?;
    const lm_plain = try secrets.decrypt(std.testing.allocator, loaded_key, lm);
    defer std.testing.allocator.free(lm_plain);
    const zen_plain = try secrets.decrypt(std.testing.allocator, loaded_key, zen);
    defer std.testing.allocator.free(zen_plain);
    try std.testing.expectEqualStrings("sk-lm-unchanged", lm_plain);
    try std.testing.expectEqualStrings("sk-zen-new", zen_plain);
}

test "save round-trips an empty API key" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fixture = try tempHomeEnv();
    defer fixture.tmp.cleanup();
    defer fixture.env.deinit();
    defer std.testing.allocator.free(fixture.home);

    var cfg = schema.Config.default();
    cfg.providerEntry(.lmstudio).apiKey = "";

    try save(std.testing.allocator, std.testing.io, cfg, &fixture.env);

    var loaded = try load(std.testing.allocator, std.testing.io, &fixture.env);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("", loaded.config.providerEntryConst(.lmstudio).apiKey.?);
    try std.testing.expect(loaded.config.providerEntryConst(.lmstudio).stored_plaintext == null);
}
