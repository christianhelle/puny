const std = @import("std");
const zz = @import("zigzag");
const lmstudio = @import("../providers/lmstudio.zig");
const model_details = @import("model_details.zig");

var model_pick_list: []const lmstudio.ModelInfo = &.{};

pub fn setModels(models: []const lmstudio.ModelInfo) void {
    model_pick_list = models;
}

pub const Widget = struct {
    list: zz.List(lmstudio.ModelInfo),
    details: model_details.DetailsPane,
    split: zz.SplitPane,
    focus: Focus,
    last_key: ?[]const u8,
    selected: ?[]const u8 = null,

    pub const Focus = enum {
        list,
        details,
    };

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
    };

    pub fn init(self: *Widget, ctx: *zz.Context) zz.Cmd(Msg) {
        self.* = .{
            .list = zz.List(lmstudio.ModelInfo).init(ctx.persistent_allocator),
            .details = model_details.DetailsPane.init(ctx.persistent_allocator, 40, 10),
            .split = zz.SplitPane.init(.horizontal),
            .focus = .list,
            .last_key = null,
            .selected = null,
        };

        for (model_pick_list) |m| {
            self.list.addItem(.init(m, m.display_name)) catch {};
        }

        self.list.focus();
        self.syncDetails();
        return .none;
    }

    pub fn deinit(self: *Widget) void {
        self.list.deinit();
        self.details.deinit();
    }

    pub fn update(self: *Widget, msg: Msg, _: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .key => |k| {
                if (k.key == .char and k.key.char == 'q') {
                    return .quit;
                }
                if (k.key == .tab) {
                    self.toggleFocus();
                    return .none;
                }
                if (k.key == .enter) {
                    if (self.list.selectedItem()) |item| {
                        self.selected = item.value.key;
                        return .quit;
                    }
                    return .none;
                }

                switch (self.focus) {
                    .list => {
                        self.list.handleKey(k);
                        self.syncDetails();
                    },
                    .details => self.details.handleKey(k),
                }
            },
        }
        return .none;
    }

    pub fn view(self: *Widget, ctx: *const zz.Context) []const u8 {
        const header = self.renderHeader(ctx.allocator, ctx.width) catch return "Error";
        defer ctx.allocator.free(header);

        const pane_height = if (ctx.height > 1) ctx.height - 1 else 1;
        const orientation: zz.SplitPaneOrientation = if (ctx.width < 80) .vertical else .horizontal;
        self.split.orientation = orientation;
        self.split.setSize(ctx.width, pane_height);
        self.split.setRatio(if (orientation == .horizontal) 0.45 else 0.50);
        const dims = self.split.dims();

        const list_height = if (dims.a_height > 1) dims.a_height - 1 else 1;
        self.list.height = list_height;

        const list_view_raw = self.list.view(ctx.allocator) catch return "Error";
        defer ctx.allocator.free(list_view_raw);

        var list_style = zz.style.Style{};
        list_style = list_style.width(dims.a_width)
            .height(dims.a_height)
            .overflow(.ellipsis);
        const list_pane = list_style.render(ctx.allocator, list_view_raw) catch return "Error";
        defer ctx.allocator.free(list_pane);

        self.details.setSize(dims.b_width, dims.b_height);
        const details_pane = self.details.view(ctx.allocator) catch return "Error";
        defer ctx.allocator.free(details_pane);

        const split_view = self.split.compose(ctx.allocator, list_pane, details_pane) catch return "Error";
        defer ctx.allocator.free(split_view);

        return std.fmt.allocPrint(ctx.allocator, "{s}\n{s}", .{ header, split_view }) catch "Error";
    }

    fn toggleFocus(self: *Widget) void {
        switch (self.focus) {
            .list => {
                self.focus = .details;
                self.list.blur();
            },
            .details => {
                self.focus = .list;
                self.list.focus();
            },
        }
    }

    fn syncDetails(self: *Widget) void {
        const item = self.list.selectedItem() orelse return;
        const key = item.value.key;
        if (self.last_key) |last| {
            if (std.mem.eql(u8, last, key)) return;
        }
        self.last_key = key;
        self.details.update(item.value) catch {};
    }

    fn renderHeader(self: *const Widget, allocator: std.mem.Allocator, width: u16) ![]const u8 {
        const focus_text = switch (self.focus) {
            .list => "[list] ↑↓ navigate, Enter select, Tab switch, q quit",
            .details => "[details] ↑↓ scroll, Enter select, Tab switch, q quit",
        };
        const raw = try std.fmt.allocPrint(allocator, "Select a model {s}", .{focus_text});
        defer allocator.free(raw);

        var style = zz.style.Style{};
        style = style.width(width).overflow(.ellipsis);
        return style.render(allocator, raw);
    }
};

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

fn makeContext(alloc: std.mem.Allocator, width: u16, height: u16) zz.Context {
    var env = zz.Environment{};
    var ctx = zz.Context.init(alloc, alloc, std.testing.io, &env);
    ctx.width = width;
    ctx.height = height;
    return ctx;
}

test "model picker initializes focused on the list" {
    const alloc = std.testing.allocator;
    const models = [_]lmstudio.ModelInfo{testModel()};
    setModels(&models);

    var ctx = makeContext(alloc, 100, 20);
    var widget: Widget = undefined;
    _ = widget.init(&ctx);
    defer widget.deinit();

    try std.testing.expectEqual(Widget.Focus.list, widget.focus);
}

test "model picker toggles focus with Tab" {
    const alloc = std.testing.allocator;
    const models = [_]lmstudio.ModelInfo{testModel()};
    setModels(&models);

    var ctx = makeContext(alloc, 100, 20);
    var widget: Widget = undefined;
    _ = widget.init(&ctx);
    defer widget.deinit();

    _ = widget.update(.{ .key = .{ .key = .tab } }, &ctx);
    try std.testing.expectEqual(Widget.Focus.details, widget.focus);

    _ = widget.update(.{ .key = .{ .key = .tab } }, &ctx);
    try std.testing.expectEqual(Widget.Focus.list, widget.focus);
}

test "model picker renders list and details panes" {
    const alloc = std.testing.allocator;
    const models = [_]lmstudio.ModelInfo{testModel()};
    setModels(&models);

    var ctx = makeContext(alloc, 100, 20);
    var widget: Widget = undefined;
    _ = widget.init(&ctx);
    defer widget.deinit();

    const output = widget.view(&ctx);
    defer alloc.free(output);

    try std.testing.expect(output.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, output, "Model V1") != null);
}

test "model picker switches to vertical layout on narrow terminals" {
    const alloc = std.testing.allocator;
    const models = [_]lmstudio.ModelInfo{testModel()};
    setModels(&models);

    var ctx = makeContext(alloc, 60, 20);
    var widget: Widget = undefined;
    _ = widget.init(&ctx);
    defer widget.deinit();

    _ = widget.view(&ctx);
    try std.testing.expectEqual(zz.SplitPaneOrientation.vertical, widget.split.orientation);
}

test "model picker selects model on Enter" {
    const alloc = std.testing.allocator;
    const models = [_]lmstudio.ModelInfo{testModel()};
    setModels(&models);

    var ctx = makeContext(alloc, 100, 20);
    var widget: Widget = undefined;
    const cmd = widget.init(&ctx);
    defer widget.deinit();
    _ = cmd;

    const result = widget.update(.{ .key = .{ .key = .enter } }, &ctx);
    try std.testing.expectEqual(zz.Cmd(Widget.Msg).quit, result);
    try std.testing.expectEqualStrings("testorg/model-v1", widget.selected.?);
}
