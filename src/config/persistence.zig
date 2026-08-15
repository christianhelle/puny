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
