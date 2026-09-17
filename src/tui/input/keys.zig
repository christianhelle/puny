const std = @import("std");

/// Editing keys recognized in terminal escape sequences.
pub const Key = enum {
    up,
    down,
    left,
    right,
    word_left,
    word_right,
    home,
    end,
    delete,
    delete_word_forward,
    delete_word_backward,
    unknown,
};

/// Decodes a CSI sequence (`ESC [ params final`). An xterm modifier
/// parameter (`1;5D`) with Ctrl or Alt held turns arrows and Delete into
/// their word-wise variants.
pub fn decodeCsi(params: []const u8, final: u8) Key {
    var it = std.mem.splitScalar(u8, params, ';');
    const code = std.fmt.parseInt(u16, it.first(), 10) catch 1;
    const modifier = std.fmt.parseInt(u16, it.next() orelse "1", 10) catch 1;
    // xterm encodes modifiers as 1 + bitmask (shift 1, alt 2, ctrl 4).
    const word = (modifier -| 1) & (2 | 4) != 0;
    return switch (final) {
        'A' => .up,
        'B' => .down,
        'C' => if (word) .word_right else .right,
        'D' => if (word) .word_left else .left,
        'H' => .home,
        'F' => .end,
        '~' => switch (code) {
            1, 7 => .home,
            4, 8 => .end,
            3 => if (word) .delete_word_forward else .delete,
            else => .unknown,
        },
        else => .unknown,
    };
}

/// Decodes an SS3 sequence (`ESC O final`), sent for cursor keys in
/// application mode. rxvt sends lowercase `c`/`d` for Ctrl+Right/Left.
pub fn decodeSs3(final: u8) Key {
    return switch (final) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        'c' => .word_right,
        'd' => .word_left,
        else => .unknown,
    };
}

/// Decodes an Alt-modified key (`ESC byte`) using readline's bindings.
pub fn decodeAlt(byte: u8) Key {
    return switch (byte) {
        'b' => .word_left,
        'f' => .word_right,
        'd' => .delete_word_forward,
        0x7f, 0x08 => .delete_word_backward,
        else => .unknown,
    };
}

/// Word-wise variant of a key sent with an extra `ESC` prefix, which is how
/// rxvt reports Alt with arrows and Delete (`ESC ESC [ D`).
pub fn withAlt(key: Key) Key {
    return switch (key) {
        .left => .word_left,
        .right => .word_right,
        .delete => .delete_word_forward,
        else => key,
    };
}

/// Byte to pass to `decodeAlt` for a Windows Alt key-down record. Consoles
/// may report Alt+letter with a zero character, so a letter virtual-key code
/// (`A`..`Z`) stands in as its lowercase byte. Returns null when the record
/// carries no ASCII byte.
pub fn altByteFromVirtualKey(vk: u16, ch: u16) ?u8 {
    if (ch == 0) {
        if (vk >= 'A' and vk <= 'Z') return std.ascii.toLower(@intCast(vk));
        return null;
    }
    if (ch < 0x80) return @intCast(ch);
    return null;
}

test "decodeCsi maps plain arrow, home, end, and delete keys" {
    try std.testing.expectEqual(Key.up, decodeCsi("", 'A'));
    try std.testing.expectEqual(Key.down, decodeCsi("", 'B'));
    try std.testing.expectEqual(Key.right, decodeCsi("", 'C'));
    try std.testing.expectEqual(Key.left, decodeCsi("", 'D'));
    try std.testing.expectEqual(Key.home, decodeCsi("", 'H'));
    try std.testing.expectEqual(Key.end, decodeCsi("", 'F'));
    try std.testing.expectEqual(Key.home, decodeCsi("1", '~'));
    try std.testing.expectEqual(Key.home, decodeCsi("7", '~'));
    try std.testing.expectEqual(Key.end, decodeCsi("4", '~'));
    try std.testing.expectEqual(Key.end, decodeCsi("8", '~'));
    try std.testing.expectEqual(Key.delete, decodeCsi("3", '~'));
}

test "decodeCsi turns Ctrl and Alt modified keys into word keys" {
    try std.testing.expectEqual(Key.word_left, decodeCsi("1;5", 'D'));
    try std.testing.expectEqual(Key.word_right, decodeCsi("1;5", 'C'));
    try std.testing.expectEqual(Key.word_left, decodeCsi("1;3", 'D'));
    try std.testing.expectEqual(Key.word_right, decodeCsi("1;3", 'C'));
    try std.testing.expectEqual(Key.word_left, decodeCsi("1;7", 'D'));
    try std.testing.expectEqual(Key.delete_word_forward, decodeCsi("3;5", '~'));
    try std.testing.expectEqual(Key.delete_word_forward, decodeCsi("3;3", '~'));
    try std.testing.expectEqual(Key.left, decodeCsi("1;2", 'D'));
    try std.testing.expectEqual(Key.home, decodeCsi("1;5", 'H'));
}

test "decodeCsi ignores unknown sequences" {
    try std.testing.expectEqual(Key.unknown, decodeCsi("", 'Z'));
    try std.testing.expectEqual(Key.unknown, decodeCsi("5", '~'));
    try std.testing.expectEqual(Key.unknown, decodeCsi("200", '~'));
}

test "decodeSs3 maps application-mode cursor keys" {
    try std.testing.expectEqual(Key.up, decodeSs3('A'));
    try std.testing.expectEqual(Key.down, decodeSs3('B'));
    try std.testing.expectEqual(Key.right, decodeSs3('C'));
    try std.testing.expectEqual(Key.left, decodeSs3('D'));
    try std.testing.expectEqual(Key.home, decodeSs3('H'));
    try std.testing.expectEqual(Key.end, decodeSs3('F'));
    try std.testing.expectEqual(Key.word_right, decodeSs3('c'));
    try std.testing.expectEqual(Key.word_left, decodeSs3('d'));
    try std.testing.expectEqual(Key.unknown, decodeSs3('P'));
}

test "decodeAlt maps readline Alt shortcuts" {
    try std.testing.expectEqual(Key.word_left, decodeAlt('b'));
    try std.testing.expectEqual(Key.word_right, decodeAlt('f'));
    try std.testing.expectEqual(Key.delete_word_forward, decodeAlt('d'));
    try std.testing.expectEqual(Key.delete_word_backward, decodeAlt(0x7f));
    try std.testing.expectEqual(Key.delete_word_backward, decodeAlt(0x08));
    try std.testing.expectEqual(Key.unknown, decodeAlt('x'));
}

test "altByteFromVirtualKey keeps the reported character" {
    try std.testing.expectEqual(@as(?u8, 'b'), altByteFromVirtualKey(0x42, 'b'));
    try std.testing.expectEqual(@as(?u8, 'B'), altByteFromVirtualKey(0x42, 'B'));
}

test "altByteFromVirtualKey derives a lowercase letter when the character is zero" {
    try std.testing.expectEqual(@as(?u8, 'b'), altByteFromVirtualKey(0x42, 0));
    try std.testing.expectEqual(@as(?u8, 'f'), altByteFromVirtualKey(0x46, 0));
    try std.testing.expectEqual(@as(?u8, 'd'), altByteFromVirtualKey(0x44, 0));
    try std.testing.expectEqual(Key.word_left, decodeAlt(altByteFromVirtualKey(0x42, 0).?));
}

test "altByteFromVirtualKey rejects non-letter keys without a character" {
    try std.testing.expectEqual(@as(?u8, null), altByteFromVirtualKey(0x70, 0));
    try std.testing.expectEqual(@as(?u8, null), altByteFromVirtualKey(0x41, 0x00E9));
}

test "withAlt turns arrows and Delete into their word-wise variants" {
    try std.testing.expectEqual(Key.word_left, withAlt(.left));
    try std.testing.expectEqual(Key.word_right, withAlt(.right));
    try std.testing.expectEqual(Key.delete_word_forward, withAlt(.delete));
}

test "withAlt leaves other keys unchanged" {
    try std.testing.expectEqual(Key.up, withAlt(.up));
    try std.testing.expectEqual(Key.home, withAlt(.home));
    try std.testing.expectEqual(Key.word_left, withAlt(.word_left));
    try std.testing.expectEqual(Key.unknown, withAlt(.unknown));
}
