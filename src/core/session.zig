const std = @import("std");

pub fn generateUuid(random: std.Random, arena: std.mem.Allocator) ![]const u8 {
    var bytes: [16]u8 = undefined;
    random.bytes(&bytes);

    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    const hex = "0123456789abcdef";
    var buf: [36]u8 = undefined;
    var i: usize = 0;
    var j: usize = 0;
    while (i < 16) : (i += 1) {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            buf[j] = '-';
            j += 1;
        }
        buf[j] = hex[bytes[i] >> 4];
        buf[j + 1] = hex[bytes[i] & 0x0f];
        j += 2;
    }
    return try arena.dupe(u8, &buf);
}

test "generateUuid produces 36-char string with correct format" {
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();

    const uuid = try generateUuid(random, std.testing.allocator);
    defer std.testing.allocator.free(uuid);

    try std.testing.expectEqual(@as(usize, 36), uuid.len);
    try std.testing.expectEqual('-', uuid[8]);
    try std.testing.expectEqual('-', uuid[13]);
    try std.testing.expectEqual('-', uuid[18]);
    try std.testing.expectEqual('-', uuid[23]);
    try std.testing.expectEqual('4', uuid[14]);
}

test "generateUuid produces unique values" {
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();

    const a = try generateUuid(random, std.testing.allocator);
    defer std.testing.allocator.free(a);

    const b = try generateUuid(random, std.testing.allocator);
    defer std.testing.allocator.free(b);

    try std.testing.expect(!std.mem.eql(u8, a, b));
}
