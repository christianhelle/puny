const std = @import("std");
const tools = @import("root.zig");
const helpers = @import("helpers.zig");

const WebFetchParams = struct {
    url: []const u8,
};

fn webFetch(allocator: std.mem.Allocator, io: std.Io, params: WebFetchParams) ![]const u8 {
    return helpers.httpGet(allocator, io, params.url);
}

pub const web_fetch = tools.defineTool(
    "web_fetch",
    "Fetch the contents of a URL using HTTP GET.",
    WebFetchParams,
    webFetch,
);
