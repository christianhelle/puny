const std = @import("std");
const zz = @import("zigzag");
const lmstudio = @import("../providers/lmstudio.zig");

pub fn formatSize(allocator: std.mem.Allocator, bytes: i64) ![]const u8 {
    if (bytes < 0) {
        return try allocator.dupe(u8, "unknown");
    }
    const f: f64 = @floatFromInt(bytes);
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var i: usize = 0;
    var v = f;
    while (v >= 1024.0 and i < units.len - 1) : (i += 1) {
        v /= 1024.0;
    }
    if (i == 0) {
        return try std.fmt.allocPrint(allocator, "{d} {s}", .{ bytes, units[i] });
    }
    return try std.fmt.allocPrint(allocator, "{d:.2} {s}", .{ v, units[i] });
}

pub const DetailsPane = struct {
    viewport: zz.Viewport,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) DetailsPane {
        var viewport = zz.Viewport.init(allocator, width, height);
        viewport.setWrap(true);
        viewport.setShowScrollbar(true);
        return .{
            .viewport = viewport,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DetailsPane) void {
        self.viewport.deinit();
    }

    pub fn setSize(self: *DetailsPane, width: u16, height: u16) void {
        self.viewport.setSize(width, height);
    }

    pub fn update(self: *DetailsPane, model: ?lmstudio.ModelInfo) !void {
        if (model) |m| {
            const content = try formatModel(self.allocator, m);
            defer self.allocator.free(content);
            try self.viewport.setContent(content);
        } else {
            try self.viewport.setContent("No model selected.");
        }
    }

    pub fn handleKey(self: *DetailsPane, key: zz.KeyEvent) void {
        self.viewport.handleKey(key);
    }

    pub fn view(self: *const DetailsPane, allocator: std.mem.Allocator) ![]const u8 {
        return self.viewport.view(allocator);
    }
};

fn formatModel(allocator: std.mem.Allocator, model: lmstudio.ModelInfo) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    const w = &out.writer;

    try w.print("Name: {s}\n", .{model.display_name});
    try w.print("ID:   {s}\n", .{model.key});
    try w.print("Publisher: {s}\n", .{model.publisher});

    if (model.architecture) |arch| {
        try w.print("Architecture: {s}\n", .{arch});
    }

    try w.print("Context length: {d}\n", .{model.max_context_length});

    const size = try formatSize(allocator, model.size_bytes);
    defer allocator.free(size);
    try w.print("Size: {s}\n", .{size});

    if (model.quantization) |q| {
        try w.print("Quantization: {s} ({d:.2} bits/weight)\n", .{ q.name, q.bits_per_weight });
    }

    if (model.capabilities) |caps| {
        try w.writeAll("Capabilities: ");
        var first = true;
        if (caps.trained_for_tool_use == true) {
            if (!first) try w.writeAll(", ");
            try w.writeAll("tool use");
            first = false;
        }
        if (caps.vision == true) {
            if (!first) try w.writeAll(", ");
            try w.writeAll("vision");
            first = false;
        }
        if (caps.reasoning) |r| {
            if (!first) try w.writeAll(", ");
            try w.print("reasoning ({s})", .{r.default});
            first = false;
        }
        if (first) {
            try w.writeAll("none reported");
        }
        try w.writeAll("\n");
    }

    return out.toOwnedSlice();
}

test "formatSize returns bytes for small values" {
    const alloc = std.testing.allocator;
    const result = try formatSize(alloc, 512);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("512 B", result);
}

test "formatSize converts kilobytes" {
    const alloc = std.testing.allocator;
    const result = try formatSize(alloc, 1536);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("1.50 KB", result);
}

test "formatSize converts gigabytes" {
    const alloc = std.testing.allocator;
    const result = try formatSize(alloc, 5 * 1024 * 1024 * 1024);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("5.00 GB", result);
}

test "formatSize handles negative sizes" {
    const alloc = std.testing.allocator;
    const result = try formatSize(alloc, -1);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("unknown", result);
}

fn testModel() lmstudio.ModelInfo {
    return .{
        .params_string = null,
        .publisher = "TestOrg",
        .key = "testorg/model-v1",
        .format = "safetensors",
        .variants = null,
        .selected_variant = null,
        .display_name = "Model V1",
        .size_bytes = 2 * 1024 * 1024 * 1024,
        .architecture = "Transformer",
        .max_context_length = 8192,
        .capabilities = .{
            .trained_for_tool_use = true,
            .reasoning = .{
                .allowed_options = &.{"auto"},
                .default = "auto",
            },
            .vision = true,
        },
        .loaded_instances = &.{},
        .quantization = .{
            .name = "Q4_K_M",
            .bits_per_weight = 4.55,
        },
        .description = null,
        .type = "llm",
    };
}

test "formatModel includes curated fields" {
    const alloc = std.testing.allocator;
    const model = testModel();
    const result = try formatModel(alloc, model);
    defer alloc.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "Model V1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "testorg/model-v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "TestOrg") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Transformer") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "8192") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "2.00 GB") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Q4_K_M") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "tool use") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "vision") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "reasoning") != null);
}

test "DetailsPane renders content" {
    const alloc = std.testing.allocator;
    var pane = DetailsPane.init(alloc, 40, 10);
    defer pane.deinit();

    try pane.update(testModel());
    const view = try pane.view(alloc);
    defer alloc.free(view);

    try std.testing.expect(view.len > 0);
}
