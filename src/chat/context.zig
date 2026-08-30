const std = @import("std");
const cli = @import("../cli/args.zig");
const config = @import("../config/config.zig");
const debug_log = @import("debug_log.zig");
const prompt_history = @import("../prompts/history.zig");
const provider = @import("../providers/provider.zig");
const openai = @import("../providers/openai.zig");
const core_session = @import("../core/session.zig");
const stats = @import("stats.zig");
const skills = @import("../skills/skills.zig");

const ModelProvider = provider.ModelProvider;
const DebugLog = debug_log.DebugLog;

pub const ChatLog = struct {
    file: std.Io.File,
    writer: *std.Io.Writer,

    pub fn print(self: *ChatLog, comptime fmt: []const u8, args: anytype) void {
        self.writer.print(fmt, args) catch {};
    }
};

pub const ChatLoopContext = struct {
    arena: std.mem.Allocator,
    messages_arena: *std.heap.ArenaAllocator,
    io: std.Io,
    init: std.process.Init,
    parsed: cli.Options,
    cfg: *config.Config,
    stdout_writer: *std.Io.Writer,
    random: std.Random,
    history: *prompt_history.History,
    prov: *provider.Provider,
    model_provider: *ModelProvider,
    provider_url: *[]const u8,
    model_key: *[]const u8,
    reasoning_effort: *?openai.ReasoningEffort,
    full_tool_definitions: *std.ArrayList(openai.ToolDefinition),
    planning_tool_definitions: *std.ArrayList(openai.ToolDefinition),
    review_tool_definitions: *std.ArrayList(openai.ToolDefinition),
    review_exit_code: *u8,
    messages: *std.ArrayList(openai.Message),
    planning_mode: *bool,
    review_mode: *bool,
    restore_incomplete: bool = false,
    session: *core_session.Session,
    session_stats: *stats.SessionStats,
    debug_log: ?*DebugLog,
    chat_log: ?*ChatLog,
    skill_registry: *skills.Registry,
};
