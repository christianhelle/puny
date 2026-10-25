const std = @import("std");
const text_width = @import("markdown/width.zig");

pub const reset = "\x1b[0m";
pub const dim = "\x1b[2m";
pub const bright = "\x1b[1;37m";
pub const green = "\x1b[32m";
pub const yellow = "\x1b[33m";
pub const cyan = "\x1b[36m";
pub const bold_start = "\x1b[1m";
pub const bold_end = "\x1b[22m";

/// Turns every control character in `text` into a space, in place, so
/// untrusted text (anything the model wrote) can't move the cursor or send
/// escape sequences to the terminal. The length never changes.
pub fn scrubControls(text: []u8) void {
    var i: usize = 0;
    while (i < text.len) {
        const decoded = text_width.decodeAt(text, i);
        // Bytes that aren't valid UTF-8 go too: 8-bit terminals may read
        // them as C1 controls.
        const unsafe = if (decoded.cp) |cp| isUnsafeCodePoint(cp) else true;
        if (unsafe) @memset(text[i..][0..decoded.len], ' ');
        i += decoded.len;
    }
}

fn isUnsafeCodePoint(cp: u21) bool {
    return switch (cp) {
        // C0 controls and DEL, plus C1 controls, which some terminals read
        // as escape sequences (U+009B is CSI).
        0x00...0x1f, 0x7f...0x9f => true,
        // Bidirectional text controls, which reorder the text around them.
        0x061c, 0x200e, 0x200f, 0x202a...0x202e, 0x2066...0x2069 => true,
        else => false,
    };
}

test "scrubControls turns control characters into spaces" {
    var text = "a\x1b[2Jb\r\nc\td\x7f".*;
    scrubControls(&text);
    try std.testing.expectEqualStrings("a [2Jb  c d ", &text);
}

test "scrubControls turns UTF-8 encoded C1 controls into spaces" {
    // U+009B is CSI on terminals that read C1 controls; U+0085 is NEL.
    var text = "a\xc2\x9b2Jb\xc2\x85c é".*;
    scrubControls(&text);
    try std.testing.expectEqualStrings("a  2Jb  c é", &text);
}

test "scrubControls turns bytes that aren't valid UTF-8 into spaces" {
    // A raw 0x9B is CSI on 8-bit terminals, and a cut-off sequence must not
    // hide the escape that follows it.
    var text = "a\x9b2Jb\xe2\x1b[2J".*;
    scrubControls(&text);
    try std.testing.expectEqualStrings("a 2Jb  [2J", &text);
}

test "scrubControls turns a character cut off at the end into spaces" {
    var four_byte = "a\xf0\x9f".*;
    scrubControls(&four_byte);
    try std.testing.expectEqualStrings("a  ", &four_byte);
    var three_byte = "a\xe2".*;
    scrubControls(&three_byte);
    try std.testing.expectEqualStrings("a ", &three_byte);
}

test "scrubControls turns bidirectional text controls into spaces" {
    // U+202E (right-to-left override) and U+2066 (left-to-right isolate)
    // can make text display in a different order than it reads.
    var text = "a\u{202e}b\u{2066}c\u{200f}d\u{061c}e".*;
    scrubControls(&text);
    try std.testing.expectEqualStrings("a   b   c   d  e", &text);
}

test "ansi constants are well-formed escape sequences" {
    try std.testing.expectEqualStrings("\x1b[0m", reset);
    try std.testing.expectEqualStrings("\x1b[2m", dim);
    try std.testing.expectEqualStrings("\x1b[1;37m", bright);
    try std.testing.expectEqualStrings("\x1b[32m", green);
    try std.testing.expectEqualStrings("\x1b[33m", yellow);
    try std.testing.expectEqualStrings("\x1b[36m", cyan);
    try std.testing.expectEqualStrings("\x1b[1m", bold_start);
    try std.testing.expectEqualStrings("\x1b[22m", bold_end);
}

test "ansi constants begin with escape and end with m" {
    const all = [_][]const u8{ reset, dim, bright, green, yellow, cyan, bold_start, bold_end };
    for (all) |seq| {
        try std.testing.expect(seq.len >= 3);
        try std.testing.expect(seq[0] == 0x1b);
        try std.testing.expect(seq[1] == '[');
        try std.testing.expect(seq[seq.len - 1] == 'm');
    }
}
