const std = @import("std");
const builtin = @import("builtin");

pub const XChaCha20Poly1305 = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
pub const key_length = XChaCha20Poly1305.key_length;
pub const nonce_length = XChaCha20Poly1305.nonce_length;
pub const tag_length = XChaCha20Poly1305.tag_length;

pub const blob_prefix = "enc:v1:";

const base64 = std.base64.standard;

/// True only when `value` is structurally a valid `enc:v1:` blob: the prefix
/// followed by base64 that decodes to at least nonce + tag bytes. A plaintext
/// key that merely starts with the prefix is treated as plaintext.
pub fn isEncrypted(value: []const u8) bool {
    if (!std.mem.startsWith(u8, value, blob_prefix)) return false;
    const b64 = value[blob_prefix.len..];
    const raw_len = base64.Decoder.calcSizeForSlice(b64) catch return false;
    return raw_len >= nonce_length + tag_length;
}

/// Encrypts `plaintext` with a fresh random nonce and returns the
/// `enc:v1:<base64(nonce ‖ ciphertext ‖ tag)>` blob.
pub fn encrypt(
    allocator: std.mem.Allocator,
    key: [key_length]u8,
    random: std.Random,
    plaintext: []const u8,
) ![]const u8 {
    var nonce: [nonce_length]u8 = undefined;
    random.bytes(&nonce);
    return encryptWithNonce(allocator, key, nonce, plaintext);
}

/// Encrypts `plaintext` with an explicit nonce. Test-only deterministic path.
fn encryptWithNonce(
    allocator: std.mem.Allocator,
    key: [key_length]u8,
    nonce: [nonce_length]u8,
    plaintext: []const u8,
) ![]const u8 {
    const raw_len = nonce.len + plaintext.len + tag_length;
    const raw = try allocator.alloc(u8, raw_len);
    defer allocator.free(raw);

    @memcpy(raw[0..nonce.len], &nonce);
    const ciphertext = raw[nonce.len .. nonce.len + plaintext.len];
    const tag: *[tag_length]u8 = raw[nonce.len + plaintext.len ..][0..tag_length];
    XChaCha20Poly1305.encrypt(ciphertext, tag, plaintext, "", nonce, key);

    const blob = try allocator.alloc(u8, blob_prefix.len + base64.Encoder.calcSize(raw_len));
    @memcpy(blob[0..blob_prefix.len], blob_prefix);
    _ = base64.Encoder.encode(blob[blob_prefix.len..], raw);
    return blob;
}

/// Decrypts an `enc:v1:` blob, returning the plaintext. Any failure
/// (malformed blob, wrong key, corrupted ciphertext) returns
/// `error.DecryptFailed`.
pub fn decrypt(
    allocator: std.mem.Allocator,
    key: [key_length]u8,
    blob: []const u8,
) ![]const u8 {
    if (!isEncrypted(blob)) return error.DecryptFailed;

    const b64 = blob[blob_prefix.len..];
    const raw_len = base64.Decoder.calcSizeForSlice(b64) catch return error.DecryptFailed;
    const raw = try allocator.alloc(u8, raw_len);
    defer allocator.free(raw);
    base64.Decoder.decode(raw, b64) catch return error.DecryptFailed;

    if (raw.len < nonce_length + tag_length) return error.DecryptFailed;
    const nonce: [nonce_length]u8 = raw[0..nonce_length].*;
    const ciphertext = raw[nonce_length .. raw.len - tag_length];
    const tag: [tag_length]u8 = raw[raw.len - tag_length ..][0..tag_length].*;

    const plaintext = try allocator.alloc(u8, ciphertext.len);
    XChaCha20Poly1305.decrypt(plaintext, ciphertext, tag, "", nonce, key) catch {
        allocator.free(plaintext);
        return error.DecryptFailed;
    };
    return plaintext;
}

test "isEncrypted detects enc:v1 blobs" {
    // A valid blob: enc:v1:<base64(nonce ‖ ct ‖ tag)>.
    try std.testing.expect(isEncrypted("enc:v1:AgICAgICAgICAgICAgICAgICAgICAgICqg9Ois5afuAGYNUfoYJVcmZrd+3L"));
    try std.testing.expect(!isEncrypted("sk-12345"));
    try std.testing.expect(!isEncrypted(""));
}

test "isEncrypted treats enc:v1-prefixed plaintext as plaintext" {
    // A real key that merely starts with the prefix must not be mistaken for an
    // encrypted blob: it is neither valid base64 nor long enough to hold a blob.
    try std.testing.expect(!isEncrypted("enc:v1:sk-abc123"));
    try std.testing.expect(!isEncrypted("enc:v1:abc123"));
    try std.testing.expect(!isEncrypted("enc:v1:"));
}

test "encrypt produces an enc:v1 blob" {
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();
    const key = [_]u8{0x42} ** key_length;

    const blob = try encrypt(std.testing.allocator, key, random, "secret-key");
    defer std.testing.allocator.free(blob);

    try std.testing.expect(std.mem.startsWith(u8, blob, "enc:v1:"));
    try std.testing.expect(std.mem.indexOf(u8, blob, "secret-key") == null);
}

test "encrypt then decrypt round-trips the plaintext" {
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();
    const key = [_]u8{0x24} ** key_length;
    const plaintext = "sk-live-9f8a7b6c";

    const blob = try encrypt(std.testing.allocator, key, random, plaintext);
    defer std.testing.allocator.free(blob);

    const decrypted = try decrypt(std.testing.allocator, key, blob);
    defer std.testing.allocator.free(decrypted);

    try std.testing.expectEqualStrings(plaintext, decrypted);
}

test "decrypt with the wrong key fails" {
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();
    const key = [_]u8{0x11} ** key_length;
    const wrong_key = [_]u8{0x22} ** key_length;

    const blob = try encrypt(std.testing.allocator, key, random, "opencode-token");
    defer std.testing.allocator.free(blob);

    try std.testing.expectError(error.DecryptFailed, decrypt(std.testing.allocator, wrong_key, blob));
}

test "decrypt fails on a tampered blob" {
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();
    const key = [_]u8{0x33} ** key_length;

    const blob = try encrypt(std.testing.allocator, key, random, "copilot-token");
    defer std.testing.allocator.free(blob);

    const tampered = try std.testing.allocator.dupe(u8, blob);
    defer std.testing.allocator.free(tampered);
    const last = tampered.len - 1;
    tampered[last] = if (tampered[last] == 'A') 'B' else 'A';

    try std.testing.expectError(error.DecryptFailed, decrypt(std.testing.allocator, key, tampered));
}

test "decrypt rejects a non-encrypted value" {
    const key = [_]u8{0x44} ** key_length;
    try std.testing.expectError(error.DecryptFailed, decrypt(std.testing.allocator, key, "sk-plaintext"));
}

test "decrypt rejects a malformed blob" {
    const key = [_]u8{0x55} ** key_length;
    try std.testing.expectError(error.DecryptFailed, decrypt(std.testing.allocator, key, "enc:v1:!!!not-base64!!!"));
}

test "encryptWithNonce produces a stable deterministic blob" {
    const key = [_]u8{0x01} ** key_length;
    const nonce = [_]u8{0x02} ** nonce_length;

    const blob = try encryptWithNonce(std.testing.allocator, key, nonce, "fixed");
    defer std.testing.allocator.free(blob);

    // Locks the wire format: enc:v1:<base64(nonce ‖ ct ‖ tag)>.
    // Expected value computed independently with PyNaCl
    // crypto_aead_xchacha20poly1305_ietf_encrypt.
    try std.testing.expectEqualStrings(
        "enc:v1:AgICAgICAgICAgICAgICAgICAgICAgICqg9Ois5afuAGYNUfoYJVcmZrd+3L",
        blob,
    );
}

pub fn keyFilePath(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const base = environ_map.get("LOCALAPPDATA") orelse environ_map.get("USERPROFILE") orelse return error.NoConfigDir;
        return std.fs.path.join(allocator, &.{ base, "puny", "encryption.key" });
    }

    if (environ_map.get("XDG_DATA_HOME")) |base| {
        return std.fs.path.join(allocator, &.{ base, "puny", "encryption.key" });
    }

    const home = environ_map.get("HOME") orelse return error.NoConfigDir;
    return std.fs.path.join(allocator, &.{ home, ".local", "share", "puny", "encryption.key" });
}

/// Loads the 32-byte encryption key, or `null` when the key file is missing
/// or malformed. Never creates the file.
pub fn loadKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
) !?[key_length]u8 {
    const path = try keyFilePath(allocator, environ_map);
    defer allocator.free(path);

    const cwd = std.Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, path, allocator, std.Io.Limit.limited(64)) catch |err| switch (err) {
        error.FileNotFound => return null,
        // A file larger than the 64-byte cap is malformed, not an I/O failure.
        error.StreamTooLong => return null,
        else => return err,
    };
    defer allocator.free(data);

    if (data.len != key_length) return null;

    var key: [key_length]u8 = undefined;
    @memcpy(&key, data);
    return key;
}

/// Returns the 32-byte encryption key, creating the key file (0600 on POSIX)
/// when it does not exist. Returns `null` when an existing key file is
/// malformed and cannot be used.
pub fn ensureKeyFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    random: std.Random,
) !?[key_length]u8 {
    if (try loadKey(allocator, io, environ_map)) |key| return key;

    const path = try keyFilePath(allocator, environ_map);
    defer allocator.free(path);

    const cwd = std.Io.Dir.cwd();

    // An existing key file that could not be loaded (wrong size, oversized) is
    // malformed: return null instead of overwriting it, which would make any
    // previously encrypted config values permanently undecryptable.
    if (cwd.statFile(io, path, .{})) |_| {
        return null;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const dir = std.fs.path.dirname(path) orelse return error.BadPath;
    try cwd.createDirPath(io, dir);
    if (comptime builtin.os.tag != .windows) {
        // The key file is 0600; hardening the directory to 0700 stops other
        // local users from even listing the key's presence in a shared data
        // tree (e.g. ~/.local/share with a default 0755 umask).
        try cwd.setFilePermissions(io, dir, @enumFromInt(0o700), .{});
    }

    var key: [key_length]u8 = undefined;
    random.bytes(&key);

    // Stage the key in a sibling temp file, harden it to 0600 before any
    // secret bytes are written, then atomically rename it over the target.
    // A partial/interrupted write can never leave a malformed key at the
    // final path, and the key is never world-readable during the chmod window.
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
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

    try file.writeStreamingAll(io, &key);
    file.close(io);
    file_open = false;

    try cwd.rename(tmp_path, cwd, path, io);
    return key;
}

test "keyFilePath prefers XDG_DATA_HOME on non-windows" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_DATA_HOME", "/xdg");
    try env.put("HOME", "/home/user");

    const path = try keyFilePath(std.testing.allocator, &env);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/xdg/puny/encryption.key", path);
}

test "keyFilePath falls back to .local/share" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/user");

    const path = try keyFilePath(std.testing.allocator, &env);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/home/user/.local/share/puny/encryption.key", path);
}

test "keyFilePath errors without a data dir" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectError(error.NoConfigDir, keyFilePath(std.testing.allocator, &env));
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

test "loadKey returns null when the key file is missing" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var fixture = try tempHomeEnv();
    defer fixture.tmp.cleanup();
    defer fixture.env.deinit();
    defer std.testing.allocator.free(fixture.home);

    const key = try loadKey(std.testing.allocator, std.testing.io, &fixture.env);
    try std.testing.expect(key == null);
}

test "loadKey returns null for a malformed key file" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var fixture = try tempHomeEnv();
    defer fixture.tmp.cleanup();
    defer fixture.env.deinit();
    defer std.testing.allocator.free(fixture.home);

    const path = try keyFilePath(std.testing.allocator, &fixture.env);
    defer std.testing.allocator.free(path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(path).?);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "too-short" });

    const key = try loadKey(std.testing.allocator, std.testing.io, &fixture.env);
    try std.testing.expect(key == null);
}

test "loadKey returns null for an oversized key file" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var fixture = try tempHomeEnv();
    defer fixture.tmp.cleanup();
    defer fixture.env.deinit();
    defer std.testing.allocator.free(fixture.home);

    const path = try keyFilePath(std.testing.allocator, &fixture.env);
    defer std.testing.allocator.free(path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(path).?);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = &([_]u8{0x42} ** 65) });

    const key = try loadKey(std.testing.allocator, std.testing.io, &fixture.env);
    try std.testing.expect(key == null);
}

test "loadKey reads a 32-byte key file" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var fixture = try tempHomeEnv();
    defer fixture.tmp.cleanup();
    defer fixture.env.deinit();
    defer std.testing.allocator.free(fixture.home);

    const path = try keyFilePath(std.testing.allocator, &fixture.env);
    defer std.testing.allocator.free(path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(path).?);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = &([_]u8{0x77} ** 32) });

    const key = try loadKey(std.testing.allocator, std.testing.io, &fixture.env);
    try std.testing.expect(key != null);
    try std.testing.expectEqual([_]u8{0x77} ** 32, key.?);
}

test "ensureKeyFile creates a 32-byte key file with 0600 permissions" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var fixture = try tempHomeEnv();
    defer fixture.tmp.cleanup();
    defer fixture.env.deinit();
    defer std.testing.allocator.free(fixture.home);
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();

    const key = (try ensureKeyFile(std.testing.allocator, std.testing.io, &fixture.env, random)).?;

    const path = try keyFilePath(std.testing.allocator, &fixture.env);
    defer std.testing.allocator.free(path);
    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, path, .{});
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);

    const reloaded = try loadKey(std.testing.allocator, std.testing.io, &fixture.env);
    try std.testing.expectEqual(key, reloaded.?);

    // The staging file is consumed by the atomic rename, never left behind.
    const staging_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.tmp", .{path});
    defer std.testing.allocator.free(staging_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, staging_path, .{}));
}

test "ensureKeyFile hardens the key directory to 0700" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var fixture = try tempHomeEnv();
    defer fixture.tmp.cleanup();
    defer fixture.env.deinit();
    defer std.testing.allocator.free(fixture.home);
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();

    _ = (try ensureKeyFile(std.testing.allocator, std.testing.io, &fixture.env, random)).?;

    const path = try keyFilePath(std.testing.allocator, &fixture.env);
    defer std.testing.allocator.free(path);
    const dir = std.fs.path.dirname(path).?;
    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, dir, .{});
    try std.testing.expectEqual(@as(u32, 0o700), stat.permissions.toMode() & 0o777);
}

test "ensureKeyFile returns the existing key without overwriting" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var fixture = try tempHomeEnv();
    defer fixture.tmp.cleanup();
    defer fixture.env.deinit();
    defer std.testing.allocator.free(fixture.home);
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();

    const path = try keyFilePath(std.testing.allocator, &fixture.env);
    defer std.testing.allocator.free(path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(path).?);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = &([_]u8{0x11} ** 32) });

    const key = (try ensureKeyFile(std.testing.allocator, std.testing.io, &fixture.env, random)).?;
    try std.testing.expectEqual([_]u8{0x11} ** 32, key);
}

test "ensureKeyFile does not overwrite a malformed existing key file" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var fixture = try tempHomeEnv();
    defer fixture.tmp.cleanup();
    defer fixture.env.deinit();
    defer std.testing.allocator.free(fixture.home);
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();

    const path = try keyFilePath(std.testing.allocator, &fixture.env);
    defer std.testing.allocator.free(path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(path).?);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "too-short" });

    const key = try ensureKeyFile(std.testing.allocator, std.testing.io, &fixture.env, random);
    try std.testing.expect(key == null);

    // The malformed file must be left untouched, not replaced by a new key.
    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, std.Io.Limit.limited(64));
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("too-short", data);
}

test "ensureKeyFile stages the key and never leaves the final path on a staging failure" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var fixture = try tempHomeEnv();
    defer fixture.tmp.cleanup();
    defer fixture.env.deinit();
    defer std.testing.allocator.free(fixture.home);
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();

    const path = try keyFilePath(std.testing.allocator, &fixture.env);
    defer std.testing.allocator.free(path);

    // A directory at the staging path forces the staged create to fail. The
    // key must then never have been written straight to the final path.
    const staging_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.tmp", .{path});
    defer std.testing.allocator.free(staging_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(path).?);
    try std.Io.Dir.cwd().createDir(std.testing.io, staging_path, .default_dir);

    try std.testing.expectError(error.IsDir, ensureKeyFile(std.testing.allocator, std.testing.io, &fixture.env, random));

    // The final key file must not exist after the failed staged write.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, path, .{}));
}
