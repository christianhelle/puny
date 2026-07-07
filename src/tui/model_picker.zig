const std = @import("std");
const zz = @import("zigzag");
const lmstudio = @import("../providers/lmstudio.zig");

var model_pick_list: []const lmstudio.ModelInfo = &.{};

pub fn setModels(models: []const lmstudio.ModelInfo) void {
    model_pick_list = models;
}

pub const Widget = struct {
    list: zz.List([]const u8),
    selected: ?[]const u8 = null,

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
    };

    pub fn init(self: *Widget, ctx: *zz.Context) zz.Cmd(Msg) {
        self.* = .{
            .list = zz.List([]const u8).init(ctx.persistent_allocator),
            .selected = null,
        };
        for (model_pick_list) |m| {
            self.list.addItem(.init(m.key, m.display_name)) catch {};
        }
        self.list.height = ctx.height -| 2;
        return .none;
    }

    pub fn deinit(self: *Widget) void {
        self.list.deinit();
    }

    pub fn update(self: *Widget, msg: Msg, _: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .key => |k| {
                if (k.key == .enter) {
                    if (self.list.selectedItem()) |item| {
                        self.selected = item.value;
                        return .quit;
                    }
                } else if (k.key == .char and k.key.char == 'q') {
                    return .quit;
                } else {
                    self.list.handleKey(k);
                }
            },
        }
        return .none;
    }

    pub fn view(self: *const Widget, ctx: *const zz.Context) []const u8 {
        const header = "Select a model (Use arrow keys to navigate, Enter to select, 'q' to quit):\n";
        const list_view = self.list.view(ctx.allocator) catch "Error rendering";
        return std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ header, list_view }) catch "Error";
    }
};
