const std = @import("std");
const tools = @import("root.zig");
const helpers = @import("helpers.zig");
const ToolContext = tools.ToolContext;

const WebFetchParams = struct {
    url: []const u8,
};

fn webFetch(ctx: *ToolContext, params: WebFetchParams) ![]const u8 {
    return helpers.httpGet(ctx.allocator, ctx.io, params.url);
}

pub const web_fetch = tools.defineTool(
    "web_fetch",
    "Fetch the contents of a URL using HTTP GET.",
    WebFetchParams,
    webFetch,
);
