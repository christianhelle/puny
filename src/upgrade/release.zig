const std = @import("std");
const helpers = @import("../tools/helpers.zig");

pub const latest_release_url = "https://api.github.com/repos/christianhelle/puny/releases/latest";

pub const LatestRelease = struct {
    tag: []const u8,
    version: []const u8,
};

/// Extracts the release tag (e.g. `v1.2.0`) and version (e.g. `1.2.0`) from a
/// parsed GitHub `releases/latest` payload. The returned slices reference
/// memory owned by the parsed `std.json.Value`, so the caller must keep it
/// alive.
pub fn latestTagFromRelease(parsed: std.json.Value) !LatestRelease {
    if (parsed != .object) return error.InvalidReleaseResponse;
    const tag_name = parsed.object.get("tag_name") orelse return error.MissingReleaseTag;
    if (tag_name != .string) return error.InvalidReleaseTag;
    const latest_tag = tag_name.string;
    return .{
        .tag = latest_tag,
        .version = if (std.mem.startsWith(u8, latest_tag, "v")) latest_tag[1..] else latest_tag,
    };
}

/// Fetches the latest release version from GitHub. The returned slice
/// references memory owned by `arena` and must stay alive for its lifetime.
pub fn latestReleaseVersion(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    const json_bytes = try helpers.httpGet(arena, io, latest_release_url);
    defer arena.free(json_bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, json_bytes, .{});
    defer parsed.deinit();
    return (try latestTagFromRelease(parsed.value)).version;
}

fn parseTestRelease(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json, .{});
}

test "latestTagFromRelease strips the leading v from the tag" {
    var parsed = try parseTestRelease(std.testing.allocator,
        \\{ "tag_name": "v1.2.0", "assets": [] }
    );
    defer parsed.deinit();
    const latest = try latestTagFromRelease(parsed.value);
    try std.testing.expectEqualStrings("v1.2.0", latest.tag);
    try std.testing.expectEqualStrings("1.2.0", latest.version);
}

test "latestTagFromRelease accepts a tag without a v prefix" {
    var parsed = try parseTestRelease(std.testing.allocator,
        \\{ "tag_name": "1.2.0" }
    );
    defer parsed.deinit();
    const latest = try latestTagFromRelease(parsed.value);
    try std.testing.expectEqualStrings("1.2.0", latest.tag);
    try std.testing.expectEqualStrings("1.2.0", latest.version);
}

test "latestTagFromRelease rejects a payload without tag_name" {
    var parsed = try parseTestRelease(std.testing.allocator,
        \\{ "assets": [] }
    );
    defer parsed.deinit();
    try std.testing.expectError(error.MissingReleaseTag, latestTagFromRelease(parsed.value));
}

test "latestTagFromRelease rejects a non-object payload" {
    var parsed = try parseTestRelease(std.testing.allocator, "[1, 2, 3]");
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidReleaseResponse, latestTagFromRelease(parsed.value));
}

test "latestTagFromRelease rejects a non-string tag_name" {
    var parsed = try parseTestRelease(std.testing.allocator, "{ \"tag_name\": 42 }");
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidReleaseTag, latestTagFromRelease(parsed.value));
}

test "latestTagFromRelease rejects a null tag_name" {
    var parsed = try parseTestRelease(std.testing.allocator, "{ \"tag_name\": null }");
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidReleaseTag, latestTagFromRelease(parsed.value));
}

test "latestTagFromRelease accepts an empty tag" {
    var parsed = try parseTestRelease(std.testing.allocator, "{ \"tag_name\": \"\" }");
    defer parsed.deinit();
    const latest = try latestTagFromRelease(parsed.value);
    try std.testing.expectEqualStrings("", latest.tag);
    try std.testing.expectEqualStrings("", latest.version);
}

test "latestTagFromRelease strips a bare v prefix" {
    var parsed = try parseTestRelease(std.testing.allocator, "{ \"tag_name\": \"v\" }");
    defer parsed.deinit();
    const latest = try latestTagFromRelease(parsed.value);
    try std.testing.expectEqualStrings("v", latest.tag);
    try std.testing.expectEqualStrings("", latest.version);
}
