const std = @import("std");
const tools = @import("root.zig");
const question_picker = @import("../tui/question_picker.zig");

const AskUserParams = struct {
    question: []const u8,
    options: []const []const u8,
    recommended: ?[]const u8 = null,
};

fn askUser(allocator: std.mem.Allocator, io: std.Io, params: AskUserParams) ![]const u8 {
    if (params.options.len == 0) return error.MissingOptions;
    // toolResult copies the answer before the parsed params are freed.
    const answer = try question_picker.ask(allocator, io, params.options, params.recommended);
    return question_picker.toolResult(allocator, answer);
}

pub const ask_user = tools.defineTool(
    "ask_user",
    "Ask the user a multiple choice question and wait for their answer. The user picks one of the options from a list, or types their own answer. question is the question to ask. options are short answers of a few words each, without numbering. recommended is the option you recommend, copied exactly. Explain the options and their trade-offs in your message before calling this tool.",
    AskUserParams,
    askUser,
);
