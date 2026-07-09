const std = @import("std");
const zz = @import("zigzag");
const chat = @import("../chat.zig");

var global_model_name: []const u8 = "";
var global_working_dir: []const u8 = "";
var global_git_branch: []const u8 = "";
var global_session_stats: ?*const chat.SessionStats = null;

pub fn setModelName(name: []const u8) void {
    global_model_name = name;
}

pub fn setWorkingDir(dir: []const u8) void {
    global_working_dir = dir;
}

pub fn setGitBranch(branch: []const u8) void {
    global_git_branch = branch;
}

pub fn setSessionStats(stats: ?*const chat.SessionStats) void {
    global_session_stats = stats;
}

fn formatTokenCount(count: i64, buf: *[16]u8) []const u8 {
    if (count >= 1_000_000) {
        return std.fmt.bufPrint(buf, "{d:.1}M", .{@as(f64, @floatFromInt(count)) / 1_000_000.0}) catch "?";
    }
    if (count >= 1000) {
        return std.fmt.bufPrint(buf, "{d:.1}k", .{@as(f64, @floatFromInt(count)) / 1000.0}) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d}", .{count}) catch "0";
}

pub const Widget = struct {
    text_area: zz.TextArea,
    submitted: ?[]const u8 = null,
    cancelled: bool = false,

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
        window_size: struct { width: u16, height: u16 },
    };

    pub fn init(self: *Widget, ctx: *zz.Context) zz.Cmd(Msg) {
        self.* = .{
            .text_area = zz.TextArea.init(ctx.persistent_allocator),
        };
        const text_height = ctx.height -| 1;
        self.text_area.setSize(ctx.width, @intCast(text_height));
        return .none;
    }

    pub fn deinit(self: *Widget) void {
        self.text_area.deinit();
    }

    pub fn update(self: *Widget, msg: Msg, ctx: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .key => |k| {
                // Enter without modifiers → submit
                if (k.key == .enter and !k.modifiers.shift and !k.modifiers.ctrl and !k.modifiers.alt) {
                    self.submitted = self.text_area.getValue(ctx.persistent_allocator) catch "";
                    return .quit;
                }
                // Escape → cancel
                if (k.key == .escape) {
                    self.cancelled = true;
                    return .quit;
                }
                // All other keys (including Shift+Enter → newline) → delegate to TextArea
                self.text_area.handleKey(k);
            },
            .window_size => |ws| {
                const text_height = ws.height -| 1;
                self.text_area.setSize(ws.width, @intCast(text_height));
            },
        }
        return .none;
    }

    pub fn view(self: *const Widget, ctx: *const zz.Context) []const u8 {
        var result: std.Io.Writer.Allocating = .init(ctx.allocator);
        const writer = &result.writer;

        writer.print("Model: {s}", .{global_model_name}) catch return "";
        if (global_git_branch.len > 0) {
            writer.print(" | ({s})", .{global_git_branch}) catch return "";
        }
        writer.print(" | {s}", .{global_working_dir}) catch return "";

        if (global_session_stats) |stats| {
            var in_buf: [16]u8 = undefined;
            var out_buf: [16]u8 = undefined;
            const in_str = formatTokenCount(stats.input_tokens, &in_buf);
            const out_str = formatTokenCount(stats.output_tokens, &out_buf);
            writer.print(" | \u{2191}{s} \u{2193}{s}", .{ in_str, out_str }) catch return "";
        }

        writer.print("\n", .{}) catch return "";

        const text_view = self.text_area.view(ctx.allocator) catch return "";
        writer.writeAll(text_view) catch return "";

        return result.toOwnedSlice() catch "";
    }
};
