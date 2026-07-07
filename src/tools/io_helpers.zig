const std = @import("std");

pub fn dupeString(allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]const u8 {
    if (s.len == 0) return "";
    return try allocator.dupe(u8, s);
}

pub fn ownedSliceOrEmpty(list: *std.array_list.Managed(u8)) std.mem.Allocator.Error![]const u8 {
    if (list.items.len == 0) return "";
    return try list.toOwnedSlice();
}

pub fn readFileAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8, max_size: usize) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    return cwd.readFileAlloc(io, path, allocator, std.Io.Limit.limited(max_size));
}

pub fn writeFile(io: std.Io, path: []const u8, content: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(io, path, .{});
    defer file.close(io);
    _ = try file.writeStreaming(io, content, &.{}, 0);
}

pub fn listDirectory(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var list = std.array_list.Managed(u8).init(allocator);
    defer list.deinit();

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        try list.appendSlice(entry.name);
        try list.append('\n');
    }

    return ownedSliceOrEmpty(&list);
}

pub fn runCommand(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: ?[]const u8) ![]const u8 {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |p| .{ .path = p } else .inherit,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    var stdout = std.array_list.Managed(u8).init(allocator);
    defer stdout.deinit();
    var stderr = std.array_list.Managed(u8).init(allocator);
    defer stderr.deinit();

    if (child.stdout) |file| {
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &buffer);
        while (true) {
            const n = try reader.interface.readSliceShort(&buffer);
            if (n == 0) break;
            try stdout.appendSlice(buffer[0..n]);
        }
    }

    if (child.stderr) |file| {
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &buffer);
        while (true) {
            const n = try reader.interface.readSliceShort(&buffer);
            if (n == 0) break;
            try stderr.appendSlice(buffer[0..n]);
        }
    }

    const term = try child.wait(io);

    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();

    switch (term) {
        .exited => |code| {
            try result.appendSlice("Exit code: ");
            var buf: [32]u8 = undefined;
            const n = try std.fmt.bufPrint(&buf, "{d}\n", .{code});
            try result.appendSlice(n);
        },
        else => {
            try result.appendSlice("Terminated\n");
        },
    }

    if (stdout.items.len > 0) {
        try result.appendSlice("STDOUT:\n");
        try result.appendSlice(stdout.items);
        try result.append('\n');
    }
    if (stderr.items.len > 0) {
        try result.appendSlice("STDERR:\n");
        try result.appendSlice(stderr.items);
        try result.append('\n');
    }

    return ownedSliceOrEmpty(&result);
}

pub fn httpGet(allocator: std.mem.Allocator, io: std.Io, url: []const u8) ![]const u8 {
    const uri = try std.Uri.parse(url);
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();
    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();
    _ = try client.fetch(.{
        .location = .{ .uri = uri },
        .method = .GET,
        .response_writer = &response_body.writer,
    });
    if (response_body.written().len == 0) return "";
    return response_body.toOwnedSlice();
}
