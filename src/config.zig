const std = @import("std");
const builtin = @import("builtin");

pub const PromptOverride = struct {
    prefix: []const u8 = "",
    suffix: []const u8 = "",
    override: ?[]const u8 = null,

    pub fn clone(self: PromptOverride, allocator: std.mem.Allocator) std.mem.Allocator.Error!PromptOverride {
        return .{
            .prefix = try allocator.dupe(u8, self.prefix),
            .suffix = try allocator.dupe(u8, self.suffix),
            .override = if (self.override) |value| try allocator.dupe(u8, value) else null,
        };
    }

    pub fn deinit(self: *PromptOverride, allocator: std.mem.Allocator) void {
        allocator.free(self.prefix);
        allocator.free(self.suffix);
        if (self.override) |value| allocator.free(value);
    }
};

pub const PromptsConfig = struct {
    system: PromptOverride = .{},
    planning: PromptOverride = .{},

    pub fn clone(self: PromptsConfig, allocator: std.mem.Allocator) std.mem.Allocator.Error!PromptsConfig {
        return .{
            .system = try self.system.clone(allocator),
            .planning = try self.planning.clone(allocator),
        };
    }

    pub fn deinit(self: *PromptsConfig, allocator: std.mem.Allocator) void {
        self.system.deinit(allocator);
        self.planning.deinit(allocator);
    }
};

pub const Config = struct {
    provider: []const u8 = "lmstudio",
    providerUrl: []const u8 = "http://127.0.0.1:1234",
    apiKey: []const u8 = "",
    model: []const u8 = "",
    prompts: PromptsConfig = .{},

    pub fn default() Config {
        return .{};
    }

    pub fn clone(self: Config, allocator: std.mem.Allocator) std.mem.Allocator.Error!Config {
        return .{
            .provider = try allocator.dupe(u8, self.provider),
            .providerUrl = try allocator.dupe(u8, self.providerUrl),
            .apiKey = try allocator.dupe(u8, self.apiKey),
            .model = try allocator.dupe(u8, self.model),
            .prompts = try self.prompts.clone(allocator),
        };
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.provider);
        allocator.free(self.providerUrl);
        allocator.free(self.apiKey);
        allocator.free(self.model);
        self.prompts.deinit(allocator);
    }

    pub fn resolvePrompt(self: Config, allocator: std.mem.Allocator, comptime name: []const u8, default_prompt: []const u8) std.mem.Allocator.Error![]const u8 {
        const override: ?[]const u8, const prefix: []const u8, const suffix: []const u8 = switch (comptime std.meta.stringToEnum(std.meta.FieldEnum(PromptsConfig), name) orelse @compileError("unknown prompt name: " ++ name)) {
            .system => .{ self.prompts.system.override, self.prompts.system.prefix, self.prompts.system.suffix },
            .planning => .{ self.prompts.planning.override, self.prompts.planning.prefix, self.prompts.planning.suffix },
        };
        if (override) |value| return allocator.dupe(u8, value);
        if (prefix.len == 0 and suffix.len == 0) return allocator.dupe(u8, default_prompt);
        return std.mem.concat(allocator, u8, &.{ prefix, default_prompt, suffix });
    }
};

pub const LoadResult = struct {
    config: Config,
    had_error: bool = false,

    pub fn deinit(self: *LoadResult, allocator: std.mem.Allocator) void {
        self.config.deinit(allocator);
    }
};

pub fn load(allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) !LoadResult {
    const path = try configPath(allocator, environ_map);
    defer allocator.free(path);

    const cwd = std.Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, path, allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{ .config = Config.default() },
        else => |e| return e,
    };
    defer allocator.free(data);

    const parsed = std.json.parseFromSlice(Config, allocator, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch |err| {
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
        const stderr_writer = &stderr_file_writer.interface;
        stderr_writer.print("Warning: failed to parse config at {s}: {s}\nUsing defaults.\n", .{ path, @errorName(err) }) catch {};
        stderr_writer.flush() catch {};
        return .{ .config = Config.default(), .had_error = true };
    };
    defer parsed.deinit();

    return .{ .config = try parsed.value.clone(allocator) };
}

pub fn save(allocator: std.mem.Allocator, io: std.Io, config: Config, environ_map: *const std.process.Environ.Map) !void {
    const path = try configPath(allocator, environ_map);
    defer allocator.free(path);

    const dir = std.fs.path.dirname(path) orelse return error.BadPath;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dir);

    const buffer = try std.json.Stringify.valueAlloc(allocator, config, .{ .whitespace = .indent_2 });
    defer allocator.free(buffer);

    var file = try cwd.createFile(io, path, .{});
    defer file.close(io);
    _ = try file.writeStreaming(io, buffer, &.{}, 0);
    _ = try file.writeStreaming(io, "\n", &.{}, 0);
}

pub fn configPath(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const base = environ_map.get("APPDATA") orelse environ_map.get("USERPROFILE") orelse return error.NoConfigDir;
        return std.fs.path.join(allocator, &.{ base, "puny", "config.json" });
    }

    if (environ_map.get("XDG_CONFIG_HOME")) |base| {
        return std.fs.path.join(allocator, &.{ base, "puny", "config.json" });
    }

    const home = environ_map.get("HOME") orelse return error.NoConfigDir;
    return std.fs.path.join(allocator, &.{ home, ".config", "puny", "config.json" });
}

test "round-trip default config via JSON" {
    const allocator = std.testing.allocator;

    const original = Config.default();
    const buffer = try std.json.Stringify.valueAlloc(allocator, original, .{ .whitespace = .indent_2 });
    defer allocator.free(buffer);

    const parsed = try std.json.parseFromSlice(Config, allocator, buffer, .{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed });
    defer parsed.deinit();

    var cloned = try parsed.value.clone(allocator);
    defer cloned.deinit(allocator);

    try std.testing.expectEqualStrings("lmstudio", cloned.provider);
    try std.testing.expectEqualStrings("http://127.0.0.1:1234", cloned.providerUrl);
    try std.testing.expectEqualStrings("", cloned.model);
}

test "resolvePrompt applies prefix, suffix, and override" {
    const allocator = std.testing.allocator;
    const cfg = Config{
        .prompts = .{
            .system = .{ .prefix = "[pre]", .suffix = "[suf]" },
            .planning = .{ .override = "overridden" },
        },
    };

    const system = try cfg.resolvePrompt(allocator, "system", "default");
    defer allocator.free(system);
    try std.testing.expectEqualStrings("[pre]default[suf]", system);

    const planning = try cfg.resolvePrompt(allocator, "planning", "default");
    defer allocator.free(planning);
    try std.testing.expectEqualStrings("overridden", planning);
}
