const std = @import("std");
const local_time = @import("../local_time.zig");

const zoneinfo_path = "/etc/localtime";

/// Formats the current local time as ISO 8601 (`YYYY-MM-DD HH:MM:SS`). The
/// offset comes from /etc/localtime and falls back to UTC when it is missing
/// or unreadable.
pub fn format(io: std.Io, buf: *local_time.Buffer) []const u8 {
    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    const offset = utcOffsetFromZoneFile(io, now) catch 0;
    return formatIso(now, offset, buf);
}

fn utcOffsetFromZoneFile(io: std.Io, now: i64) !i32 {
    var file = try std.Io.Dir.cwd().openFile(io, zoneinfo_path, .{});
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);

    // Zone files hold a few hundred transitions at most, so a fixed buffer
    // keeps parsing off the heap.
    var alloc_buf: [32 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&alloc_buf);
    const tz = try std.tz.Tz.parse(fba.allocator(), &file_reader.interface);
    return utcOffsetAt(tz, now);
}

/// Returns the UTC offset in seconds that `tz` has at `now`. Times past the
/// last transition follow the POSIX TZ footer, because slim zone files stop
/// listing transitions once a rule repeats every year.
fn utcOffsetAt(tz: std.tz.Tz, now: i64) i32 {
    if (tz.transitions.len == 0 or now >= tz.transitions[tz.transitions.len - 1].ts) {
        if (tz.footer) |footer| {
            if (PosixTz.parse(footer)) |rule| return rule.utcOffsetAt(now);
        }
        if (tz.transitions.len == 0) return tz.timetypes[0].offset;
        return tz.transitions[tz.transitions.len - 1].timetype.offset;
    }
    if (now < tz.transitions[0].ts) return tz.timetypes[0].offset;

    var offset = tz.transitions[0].timetype.offset;
    for (tz.transitions) |transition| {
        if (transition.ts > now) break;
        offset = transition.timetype.offset;
    }
    return offset;
}

/// The subset of a POSIX TZ string that zone file footers use:
/// `STDoffset[DST[offset],Mm.w.d[/time],Mm.w.d[/time]]`.
const PosixTz = struct {
    /// Seconds east of UTC, the opposite sign of the POSIX string.
    std_offset: i32,
    dst: ?Dst,

    const Dst = struct {
        offset: i32,
        start: Rule,
        end: Rule,
    };

    const Rule = struct {
        month: u4,
        week: u3,
        weekday: u3,
        /// Local seconds after midnight; may be negative or past 24h.
        time: i32,
    };

    fn parse(text: []const u8) ?PosixTz {
        var p = Parser{ .text = text };
        if (!p.skipName()) return null;
        const std_offset = -(p.offset() orelse return null);
        if (p.done()) return .{ .std_offset = std_offset, .dst = null };

        if (!p.skipName()) return null;
        var dst_offset = std_offset + 3600;
        if (!p.peekIs(',')) dst_offset = -(p.offset() orelse return null);
        if (!p.eat(',')) return null;
        const start = p.rule() orelse return null;
        if (!p.eat(',')) return null;
        const end = p.rule() orelse return null;
        if (!p.done()) return null;
        return .{ .std_offset = std_offset, .dst = .{ .offset = dst_offset, .start = start, .end = end } };
    }

    fn utcOffsetAt(self: PosixTz, now: i64) i32 {
        const dst = self.dst orelse return self.std_offset;
        const year = civilFromDays(@divFloor(now + self.std_offset, std.time.s_per_day)).year;
        // The start rule is in standard local time and the end rule in
        // daylight local time.
        const start = ruleDay(year, dst.start) * std.time.s_per_day + dst.start.time - self.std_offset;
        const end = ruleDay(year, dst.end) * std.time.s_per_day + dst.end.time - dst.offset;
        const in_dst = if (start < end)
            now >= start and now < end
        else
            now >= start or now < end;
        return if (in_dst) dst.offset else self.std_offset;
    }

    /// Days since the Unix epoch of weekday `d` in week `w` of month `m`,
    /// where week 5 means the last one.
    fn ruleDay(year: i64, rule: Rule) i64 {
        const first = daysFromCivil(year, rule.month, 1);
        // 1970-01-01 was a Thursday.
        const first_weekday = @mod(first + 4, 7);
        var day = first + @mod(@as(i64, rule.weekday) - first_weekday, 7) + (@as(i64, rule.week) - 1) * 7;
        const next_month = if (rule.month == 12) daysFromCivil(year + 1, 1, 1) else daysFromCivil(year, rule.month + 1, 1);
        while (day >= next_month) day -= 7;
        return day;
    }
};

const Parser = struct {
    text: []const u8,
    pos: usize = 0,

    fn done(self: *const Parser) bool {
        return self.pos == self.text.len;
    }

    fn peekIs(self: *const Parser, c: u8) bool {
        return self.pos < self.text.len and self.text[self.pos] == c;
    }

    fn eat(self: *Parser, c: u8) bool {
        if (!self.peekIs(c)) return false;
        self.pos += 1;
        return true;
    }

    /// Skips a zone abbreviation, either alphabetic or quoted as `<...>`.
    fn skipName(self: *Parser) bool {
        if (self.eat('<')) {
            const close = std.mem.indexOfScalarPos(u8, self.text, self.pos, '>') orelse return false;
            self.pos = close + 1;
            return true;
        }
        const start = self.pos;
        while (self.pos < self.text.len and std.ascii.isAlphabetic(self.text[self.pos])) self.pos += 1;
        return self.pos - start >= 3;
    }

    /// Parses `[+-]h[h][:mm[:ss]]` into seconds.
    fn offset(self: *Parser) ?i32 {
        var sign: i32 = 1;
        if (self.eat('-')) sign = -1 else _ = self.eat('+');
        var total = (self.number() orelse return null) * 3600;
        if (self.eat(':')) {
            total += (self.number() orelse return null) * 60;
            if (self.eat(':')) total += self.number() orelse return null;
        }
        return sign * total;
    }

    fn number(self: *Parser) ?i32 {
        const start = self.pos;
        while (self.pos < self.text.len and std.ascii.isDigit(self.text[self.pos])) self.pos += 1;
        if (self.pos == start or self.pos - start > 3) return null;
        return std.fmt.parseInt(i32, self.text[start..self.pos], 10) catch null;
    }

    /// Parses `Mm.w.d[/time]`. Julian-day rules never appear in current
    /// zone files, so they are rejected.
    fn rule(self: *Parser) ?PosixTz.Rule {
        if (!self.eat('M')) return null;
        const month = self.number() orelse return null;
        if (!self.eat('.')) return null;
        const week = self.number() orelse return null;
        if (!self.eat('.')) return null;
        const weekday = self.number() orelse return null;
        if (month < 1 or month > 12 or week < 1 or week > 5 or weekday > 6) return null;
        var time: i32 = 2 * 3600;
        if (self.eat('/')) time = self.offset() orelse return null;
        return .{ .month = @intCast(month), .week = @intCast(week), .weekday = @intCast(weekday), .time = time };
    }
};

/// Formats `unix_secs` shifted by `offset_secs` as `YYYY-MM-DD HH:MM:SS`.
fn formatIso(unix_secs: i64, offset_secs: i32, buf: *local_time.Buffer) []const u8 {
    const local = unix_secs + offset_secs;
    const date = civilFromDays(@divFloor(local, std.time.s_per_day));
    const secs_of_day: u32 = @intCast(@mod(local, std.time.s_per_day));
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u64, @intCast(@max(date.year, 0))),
        date.month,
        date.day,
        secs_of_day / 3600,
        secs_of_day / 60 % 60,
        secs_of_day % 60,
    }) catch "";
}

const CivilDate = struct { year: i64, month: u4, day: u5 };

// Howard Hinnant's days_from_civil and civil_from_days, valid for any day
// count and unlike std.time.epoch not limited to dates after 1970.
fn daysFromCivil(year: i64, month: u4, day: u5) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn civilFromDays(days: i64) CivilDate {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = if (mp < 10) mp + 3 else mp - 9;
    const year = yoe + era * 400 + @as(i64, if (month <= 2) 1 else 0);
    return .{ .year = year, .month = @intCast(month), .day = @intCast(day) };
}

test "formatIso formats UTC" {
    var buf: local_time.Buffer = undefined;
    // 2026-10-23 10:15:00 UTC
    try std.testing.expectEqualStrings("2026-10-23 10:15:00", formatIso(1792750500, 0, &buf));
}

test "formatIso applies a positive offset across midnight" {
    var buf: local_time.Buffer = undefined;
    // 2026-10-23 23:30:00 UTC is 01:30 the next day at UTC+2.
    try std.testing.expectEqualStrings("2026-10-24 01:30:00", formatIso(1792798200, 2 * 3600, &buf));
}

test "formatIso applies a negative offset across midnight and year end" {
    var buf: local_time.Buffer = undefined;
    // 2027-01-01 03:00:00 UTC is 22:00 the previous day at UTC-5.
    try std.testing.expectEqualStrings("2026-12-31 22:00:00", formatIso(1798772400, -5 * 3600, &buf));
}

test "civil date conversion round trips around leap days" {
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    const leap = daysFromCivil(2028, 2, 29);
    const back = civilFromDays(leap);
    try std.testing.expectEqual(@as(i64, 2028), back.year);
    try std.testing.expectEqual(@as(u4, 2), back.month);
    try std.testing.expectEqual(@as(u5, 29), back.day);
}

test "PosixTz without daylight saving uses the standard offset" {
    const tz = PosixTz.parse("<+0530>-5:30").?;
    try std.testing.expectEqual(@as(i32, 5 * 3600 + 30 * 60), tz.utcOffsetAt(1792750500));
}

test "PosixTz switches Central European time on the last Sundays" {
    const tz = PosixTz.parse("CET-1CEST,M3.5.0,M10.5.0/3").?;
    // 2026-03-29 00:59:59 UTC is just before the switch to summer time.
    try std.testing.expectEqual(@as(i32, 3600), tz.utcOffsetAt(1774745999));
    try std.testing.expectEqual(@as(i32, 7200), tz.utcOffsetAt(1774746000));
    // 2026-10-25 00:59:59 UTC is the last second of summer time.
    try std.testing.expectEqual(@as(i32, 7200), tz.utcOffsetAt(1792889999));
    try std.testing.expectEqual(@as(i32, 3600), tz.utcOffsetAt(1792890000));
}

test "PosixTz handles a southern hemisphere rule" {
    const tz = PosixTz.parse("AEST-10AEDT,M10.1.0,M4.1.0/3").?;
    // January is summer in Sydney and July is winter.
    try std.testing.expectEqual(@as(i32, 11 * 3600), tz.utcOffsetAt(1768478400));
    try std.testing.expectEqual(@as(i32, 10 * 3600), tz.utcOffsetAt(1784116800));
}

test "PosixTz rejects Julian day rules" {
    try std.testing.expect(PosixTz.parse("EST5EDT,J60,J300") == null);
}
