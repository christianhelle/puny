const std = @import("std");

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
        const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(i + seq_len, text.len);
        const cp = std.unicode.utf8Decode(text[i..end]) catch {
            // A byte that starts no valid sequence: 8-bit terminals may read
            // it as a C1 control. Step one byte so what follows still gets
            // checked.
            text[i] = ' ';
            i += 1;
            continue;
        };
        // C0 controls and DEL, plus C1 controls, which some terminals read
        // as escape sequences (U+009B is CSI).
        if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) @memset(text[i..end], ' ');
        i = end;
    }
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
