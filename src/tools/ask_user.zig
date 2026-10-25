const std = @import("std");
const tools = @import("root.zig");
const question_picker = @import("../tui/question_picker.zig");

const AskUserParams = struct {
    question: []const u8,
    options: []const []const u8,
    recommended: ?[]const u8 = null,
};

/// Puts the question to the user; tests swap in a fake so no terminal is
/// needed.
var asker: *const fn (std.mem.Allocator, std.Io, []const u8, []const []const u8, ?[]const u8) anyerror!question_picker.Answer = question_picker.ask;

fn askUser(allocator: std.mem.Allocator, io: std.Io, params: AskUserParams) ![]const u8 {
    // toolResult copies the answer before the parsed params are freed.
    const answer = try asker(allocator, io, params.question, params.options, params.recommended);
    return question_picker.toolResult(allocator, answer);
}

pub const ask_user = tools.defineTool(
    "ask_user",
    "Ask the user a multiple choice question and wait for their answer. The user picks one of the options from a list, or types their own answer. question is the question to ask, in one short sentence. options are short answers of a few words each, without numbering. recommended is the option you recommend, copied exactly. Explain the options and their trade-offs in your message before calling this tool.",
    AskUserParams,
    askUser,
);

const FakeAsker = struct {
    var question: []const u8 = "";
    var options_len: usize = 0;
    var recommended: ?[]const u8 = null;

    fn ask(_: std.mem.Allocator, _: std.Io, q: []const u8, options: []const []const u8, r: ?[]const u8) !question_picker.Answer {
        question = q;
        options_len = options.len;
        recommended = r;
        return .{ .picked = options[1] };
    }
};

test "ask_user asks the question and reports the picked option" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    asker = FakeAsker.ask;
    defer asker = question_picker.ask;

    const args = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"question":"Which database?","options":["SQLite","Postgres"],"recommended":"Postgres"}
    , .{});
    const result = try ask_user.execute(arena, std.testing.io, args);

    try std.testing.expectEqualStrings("The user chose: Postgres", result);
    try std.testing.expectEqualStrings("Which database?", FakeAsker.question);
    try std.testing.expectEqual(@as(usize, 2), FakeAsker.options_len);
    try std.testing.expectEqualStrings("Postgres", FakeAsker.recommended.?);
}

test "ask_user passes no recommendation when the model gives none" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    asker = FakeAsker.ask;
    defer asker = question_picker.ask;

    const args = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"question":"Which database?","options":["SQLite","Postgres"]}
    , .{});
    _ = try ask_user.execute(arena, std.testing.io, args);

    try std.testing.expect(FakeAsker.recommended == null);
}
