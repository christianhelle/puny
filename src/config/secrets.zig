const std = @import("std");
const builtin = @import("builtin");

pub const XChaCha20Poly1305 = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
pub const key_length = XChaCha20Poly1305.key_length;
pub const nonce_length = XChaCha20Poly1305.nonce_length;
pub const tag_length = XChaCha20Poly1305.tag_length;

pub const blob_prefix = "enc:v1:";

const base64 = std.base64.standard;

pub fn isEncrypted(value: []const u8) bool {
    return std.mem.startsWith(u8, value, blob_prefix);
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
pub fn encryptWithNonce(
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
    try std.testing.expect(isEncrypted("enc:v1:abc123"));
    try std.testing.expect(!isEncrypted("sk-12345"));
    try std.testing.expect(!isEncrypted(""));
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
