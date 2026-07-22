const std = @import("std");

pub fn dupeString(allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]const u8 {
    if (s.len == 0) return "";
    return try allocator.dupe(u8, s);
}

pub fn ownedSliceOrEmpty(list: *std.ArrayList(u8), allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
    if (list.items.len == 0) return "";
    return try list.toOwnedSlice(allocator);
}

pub fn readFileAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8, max_size: usize) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    return cwd.readFileAlloc(io, path, allocator, std.Io.Limit.limited(max_size));
}

pub fn writeFile(io: std.Io, path: []const u8, content: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

pub fn listDirectory(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        try list.appendSlice(allocator, entry.name);
        try list.append(allocator, '\n');
    }

    return ownedSliceOrEmpty(&list, allocator);
}

pub fn runCommand(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: ?[]const u8) ![]const u8 {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |p| .{ .path = p } else .inherit,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    if (child.stdout) |file| {
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &buffer);
        while (true) {
            const n = try reader.interface.readSliceShort(&buffer);
            if (n == 0) break;
            try stdout.appendSlice(allocator, buffer[0..n]);
        }
    }

    if (child.stderr) |file| {
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &buffer);
        while (true) {
            const n = try reader.interface.readSliceShort(&buffer);
            if (n == 0) break;
            try stderr.appendSlice(allocator, buffer[0..n]);
        }
    }

    const term = try child.wait(io);

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    switch (term) {
        .exited => |code| {
            try result.appendSlice(allocator, "Exit code: ");
            var buf: [32]u8 = undefined;
            const n = try std.fmt.bufPrint(&buf, "{d}", .{code});
            try result.appendSlice(allocator, n);
        },
        else => {
            try result.appendSlice(allocator, "Terminated\n");
        },
    }

    if (stdout.items.len > 0) {
        try result.appendSlice(allocator, "STDOUT:\n");
        try result.appendSlice(allocator, stdout.items);
        try result.append(allocator, '\n');
    }
    if (stderr.items.len > 0) {
        try result.appendSlice(allocator, "STDERR:\n");
        try result.appendSlice(allocator, stderr.items);
        try result.append(allocator, '\n');
    }

    return ownedSliceOrEmpty(&result, allocator);
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
