const std = @import("std");

fn isWideCodePoint(cp: u21) bool {
    return switch (cp) {
        0x1100...0x115F, // Hangul Jamo
        0x2329,
        0x232A, // Angle brackets
        0x2E80...0x303E, // CJK Radicals, Kangxi, CJK Symbols
        0x3040...0x33FF, // Hiragana, Katakana, Bopomofo, CJK Compatibility
        0x3400...0x4DBF, // CJK Extension A
        0x4E00...0x9FFF, // CJK Unified Ideographs
        0xA000...0xA4CF, // Yi
        0xAC00...0xD7AF, // Hangul Syllables
        0xF900...0xFAFF, // CJK Compatibility Ideographs
        0xFE10...0xFE1F, // Vertical forms
        0xFE30...0xFE6F, // CJK Compatibility Forms, Small Form Variants
        0xFF01...0xFF60, // Fullwidth Forms
        0xFFE0...0xFFE6, // Fullwidth Signs
        0x1F000...0x1F9FF, // Mahjong, Domino, Enclosed Alphanumeric, Emoticons, Transport
        0x20000...0x2FFFF, // CJK Extension B–G
        => true,
        else => false,
    };
}

fn isZeroWidthCodePoint(cp: u21) bool {
    return switch (cp) {
        0x0300...0x036F, // Combining Diacritical Marks
        0x0483...0x0489, // Cyrillic combining marks
        0x0591...0x05BD, // Hebrew combining marks
        0x0610...0x061A, // Arabic combining marks
        0x064B...0x065F, // Arabic combining marks
        0x0670,
        0x06D6...0x06DC,
        0x06DF...0x06E4,
        0x06E7...0x06E8,
        0x06EA...0x06ED,
        0x0711,
        0x0730...0x074A,
        0x07A6...0x07B0,
        0x0901...0x0903, // Devanagari
        0x093C,
        0x093E...0x094D,
        0x0951...0x0954,
        0x0962...0x0963,
        0x0981...0x0983,
        0x09BC,
        0x09BE...0x09C4,
        0x09C7...0x09C8,
        0x09CB...0x09CD,
        0x09D7,
        0x09E2...0x09E3,
        0x0A01...0x0A03,
        0x0A3C,
        0x0A3E...0x0A42,
        0x0A47...0x0A48,
        0x0A4B...0x0A4D,
        0x0A70...0x0A71,
        0x0A81...0x0A83,
        0x0ABC,
        0x0ABE...0x0AC5,
        0x0AC7...0x0AC9,
        0x0ACB...0x0ACD,
        0x0AE2...0x0AE3,
        0x0B01...0x0B03,
        0x0B3C,
        0x0B3E...0x0B43,
        0x0B47...0x0B48,
        0x0B4B...0x0B4D,
        0x0B56...0x0B57,
        0x0B82,
        0x0BBE...0x0BC2,
        0x0BC6...0x0BC8,
        0x0BCA...0x0BCD,
        0x0BD7,
        0x0C01...0x0C03,
        0x0C3E...0x0C44,
        0x0C46...0x0C48,
        0x0C4A...0x0C4D,
        0x0C55...0x0C56,
        0x0C82...0x0C83,
        0x0CBC,
        0x0CBE...0x0CC4,
        0x0CC6...0x0CC8,
        0x0CCA...0x0CCD,
        0x0CD5...0x0CD6,
        0x0D02...0x0D03,
        0x0D3E...0x0D44,
        0x0D46...0x0D48,
        0x0D4A...0x0D4D,
        0x0D57,
        0x0D82...0x0D83,
        0x0DCA,
        0x0DCF...0x0DD4,
        0x0DD6,
        0x0DD8...0x0DDF,
        0x0DF2...0x0DF3,
        0x0E31,
        0x0E34...0x0E3A,
        0x0E47...0x0E4E,
        0x0EB1,
        0x0EB4...0x0EB9,
        0x0EBB...0x0EBC,
        0x0EC8...0x0ECD,
        0x0F18...0x0F19,
        0x0F35,
        0x0F37,
        0x0F39,
        0x0F3E...0x0F3F,
        0x0F71...0x0F84,
        0x0F86...0x0F87,
        0x0F90...0x0F97,
        0x0F99...0x0FBC,
        0x0FC6,
        0x102B...0x103E,
        0x1056...0x1059,
        0x105E...0x1060,
        0x1062...0x1064,
        0x1067...0x106D,
        0x1071...0x1074,
        0x1082...0x108D,
        0x108F,
        0x109A...0x109D,
        0x200B...0x200F, // ZWSP, ZWNJ, ZWJ, LRM, RLM
        0x2028...0x202E,
        0x2060...0x2064, // Word joiner, invisible operators
        0x2066...0x206F,
        0xFE00...0xFE0F, // Variation selectors
        0xFEFF,
        0xFFF9...0xFFFB,
        => true,
        else => false,
    };
}

/// Display width of a single code point: 0 for combining/format marks, 2 for
/// wide (CJK/emoji) code points, otherwise 1.
pub fn codePointWidth(cp: u21) usize {
    if (isZeroWidthCodePoint(cp)) return 0;
    if (isWideCodePoint(cp)) return 2;
    return 1;
}

pub fn displayWidth(text: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const cp = std.unicode.utf8Decode(text[i..][0..seq_len]) catch {
            i += seq_len;
            width += 1;
            continue;
        };
        width += codePointWidth(cp);
        i += seq_len;
    }
    return width;
}

/// Visible display width of a rendered line, ignoring ANSI escape sequences.
/// CSI sequences are skipped to their final byte (0x40-0x7E), so escape
/// sequences like cursor movement cannot consume the remaining text.
pub fn ansiVisibleWidth(text: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            i += 1;
            if (i < text.len and text[i] == '[') {
                i += 1;
                while (i < text.len and !(text[i] >= 0x40 and text[i] <= 0x7e)) i += 1;
                if (i < text.len) i += 1;
            }
            continue;
        }
        const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const cp = std.unicode.utf8Decode(text[i..][0..seq_len]) catch {
            i += seq_len;
            width += 1;
            continue;
        };
        width += codePointWidth(cp);
        i += seq_len;
    }
    return width;
}

test "displayWidth counts code points not bytes" {
    try std.testing.expectEqual(@as(usize, 3), displayWidth("abc"));
    try std.testing.expectEqual(@as(usize, 0), displayWidth(""));
    try std.testing.expectEqual(@as(usize, 5), displayWidth("héllo"));
    try std.testing.expectEqual(@as(usize, 4), displayWidth("中文"));
    try std.testing.expectEqual(@as(usize, 2), displayWidth("😀"));
}

test "ansiVisibleWidth ignores ANSI escapes" {
    try std.testing.expectEqual(@as(usize, 5), ansiVisibleWidth("\x1b[1mhello\x1b[0m"));
    try std.testing.expectEqual(@as(usize, 3), ansiVisibleWidth("a\x1b[36mb\x1b[0mc"));
    try std.testing.expectEqual(@as(usize, 2), ansiVisibleWidth("\x1b[2m中\x1b[0m"));
    try std.testing.expectEqual(@as(usize, 0), ansiVisibleWidth(""));
    try std.testing.expectEqual(@as(usize, 0), ansiVisibleWidth("\x1b[38;5;237m\x1b[0m"));
}

test "ansiVisibleWidth counts table borders and styling separately" {
    const styled = "┌───┐\x1b[0m";
    try std.testing.expectEqual(@as(usize, 5), ansiVisibleWidth(styled));
}

test "codePointWidth classifies zero-width and wide code points" {
    try std.testing.expectEqual(@as(usize, 0), codePointWidth(0x0301)); // combining acute
    try std.testing.expectEqual(@as(usize, 0), codePointWidth(0x200D)); // ZWJ
    try std.testing.expectEqual(@as(usize, 0), codePointWidth(0xFEFF)); // BOM
    try std.testing.expectEqual(@as(usize, 2), codePointWidth(0x4E2D)); // CJK
    try std.testing.expectEqual(@as(usize, 2), codePointWidth(0x1F600)); // emoji
    try std.testing.expectEqual(@as(usize, 2), codePointWidth(0xFF01)); // fullwidth
    try std.testing.expectEqual(@as(usize, 1), codePointWidth('a'));
    try std.testing.expectEqual(@as(usize, 1), codePointWidth(0x00E9)); // é
}

test "displayWidth treats combining marks as zero-width" {
    try std.testing.expectEqual(@as(usize, 1), displayWidth("e\u{301}"));
    try std.testing.expectEqual(@as(usize, 2), displayWidth("a\u{200D}b"));
}

test "displayWidth counts invalid UTF-8 bytes as one column each" {
    try std.testing.expectEqual(@as(usize, 1), displayWidth(&.{0xff}));
    try std.testing.expectEqual(@as(usize, 2), displayWidth(&.{ 0x80, 0x80 }));
}

test "ansiVisibleWidth ignores dangling and truncated escapes" {
    try std.testing.expectEqual(@as(usize, 0), ansiVisibleWidth("\x1b"));
    try std.testing.expectEqual(@as(usize, 0), ansiVisibleWidth("\x1b["));
    try std.testing.expectEqual(@as(usize, 0), ansiVisibleWidth("\x1b[31"));
    try std.testing.expectEqual(@as(usize, 1), ansiVisibleWidth("\x1bX"));
    try std.testing.expectEqual(@as(usize, 2), ansiVisibleWidth("\x1b[31m中\x1b[0m"));
    try std.testing.expectEqual(@as(usize, 2), ansiVisibleWidth("a\x1bb"));
}

test "ansiVisibleWidth counts invalid UTF-8 bytes as one column each" {
    try std.testing.expectEqual(@as(usize, 1), ansiVisibleWidth(&.{0xff}));
    try std.testing.expectEqual(@as(usize, 2), ansiVisibleWidth(&.{ 0x80, 0x80 }));
}
