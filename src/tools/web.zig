const std = @import("std");
const tools = @import("root.zig");

const WebFetchParams = struct {
    url: []const u8,
};

fn webFetch(allocator: std.mem.Allocator, params: WebFetchParams) ![]const u8 {
    const uri = try std.Uri.parse(params.url);

    var client = std.http.Client{ .allocator = allocator, .io = std.io.getStdOut().handle };
    defer client.deinit();

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    _ = try client.fetch(.{
        .location = .{ .uri = uri },
        .method = .GET,
        .response_writer = &response_body.writer,
    });

    return response_body.toOwnedSlice();
}

pub const web_fetch = tools.defineTool(
    "web_fetch",
    "Fetch the contents of a URL using HTTP GET.",
    WebFetchParams,
    webFetch,
);
