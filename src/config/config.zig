const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const provider = @import("../providers/provider.zig");
const opencode_zen = @import("../providers/opencode_zen.zig");
const opencode_go = @import("../providers/opencode_go.zig");
const copilot = @import("../providers/copilot.zig");

fn isValidUtf8(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return false;
        if (i + len > s.len) return false;
        _ = std.unicode.utf8Decode(s[i..][0..len]) catch return false;
        i += len;
    }
    return true;
}

pub const default_lm_studio_url =
    if (build_options.docker) "http://host.docker.internal:1234" else "http://127.0.0.1:1234";

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

pub const Provider = struct {
    name: provider.ModelProvider,
    apiKey: ?[]const u8,
    url: []const u8,
    model: []const u8,

    pub fn clone(self: Provider, allocator: std.mem.Allocator) std.mem.Allocator.Error!Provider {
        return .{
            .name = self.name,
            .apiKey = if (self.apiKey) |value| try allocator.dupe(u8, value) else null,
            .url = try allocator.dupe(u8, self.url),
            .model = try allocator.dupe(u8, self.model),
        };
    }

    pub fn deinit(self: *Provider, allocator: std.mem.Allocator) void {
        if (self.apiKey) |key| allocator.free(key);
        allocator.free(self.url);
        allocator.free(self.model);
    }
};

pub const Config = struct {
    provider: provider.ModelProvider = .lmstudio,
    prompts: PromptsConfig = .{},
    providers: [4]Provider = [4]Provider{
        .{ .name = .lmstudio, .url = default_lm_studio_url, .apiKey = null, .model = "" },
        .{ .name = .opencode_zen, .url = opencode_zen.default_base_url, .apiKey = null, .model = "" },
        .{ .name = .opencode_go, .url = opencode_go.default_base_url, .apiKey = null, .model = "" },
        .{ .name = .copilot, .url = copilot.default_base_url, .apiKey = null, .model = "" },
    },

    pub fn default() Config {
        return .{};
    }

    pub fn providerEntry(self: *Config, kind: provider.ModelProvider) *Provider {
        return switch (kind) {
            .lmstudio => &self.providers[0],
            .opencode_zen => &self.providers[1],
            .opencode_go => &self.providers[2],
            .copilot => &self.providers[3],
            .mock => unreachable,
        };
    }

    pub fn providerEntryConst(self: *const Config, kind: provider.ModelProvider) *const Provider {
        return switch (kind) {
            .lmstudio => &self.providers[0],
            .opencode_zen => &self.providers[1],
            .opencode_go => &self.providers[2],
            .copilot => &self.providers[3],
            .mock => unreachable,
        };
    }

    pub fn clone(self: Config, allocator: std.mem.Allocator) std.mem.Allocator.Error!Config {
        var providers: [4]Provider = undefined;
        for (&self.providers, &providers) |src, *dst| {
            dst.* = try src.clone(allocator);
        }
        return .{
            .provider = self.provider,
            .prompts = try self.prompts.clone(allocator),
            .providers = providers,
        };
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (&self.providers) |*p| p.deinit(allocator);
        self.prompts.deinit(allocator);
    }

    pub fn resolvePrompt(
        self: Config,
        allocator: std.mem.Allocator,
        comptime name: []const u8,
        default_prompt: []const u8,
    ) std.mem.Allocator.Error![]const u8 {
        const override: ?[]const u8, const prefix: []const u8, const suffix: []const u8 = switch (comptime std.meta.stringToEnum(
            std.meta.FieldEnum(PromptsConfig),
            name,
        ) orelse @compileError("unknown prompt name: " ++ name)) {
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
    arena: ?std.heap.ArenaAllocator = null,

    pub fn deinit(self: *LoadResult, allocator: std.mem.Allocator) void {
        if (self.arena) |*a| {
            a.deinit();
        } else {
            self.config.deinit(allocator);
        }
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
        .allocate = .alloc_always,
    }) catch |err| {
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
        const stderr_writer = &stderr_file_writer.interface;
        stderr_writer.print("Warning: failed to parse config at {s}: {s}\nUsing defaults.\n", .{ path, @errorName(err) }) catch {};
        stderr_writer.flush() catch {};
        return .{ .config = Config.default(), .had_error = true };
    };

    // Steal the parser's arena: strings live in the arena, not in a clone
    var cfg = parsed.value;
    const model = cfg.providerEntry(cfg.provider).model;
    if (!isValidUtf8(model)) {
        cfg.providerEntry(cfg.provider).model = "";
    }
    const arena = parsed.arena.*;
    allocator.destroy(parsed.arena);
    return .{ .config = cfg, .arena = arena };
}

pub fn save(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    environ_map: *const std.process.Environ.Map,
) !void {
    const path = try configPath(allocator, environ_map);
    defer allocator.free(path);

    const dir = std.fs.path.dirname(path) orelse return error.BadPath;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dir);

    const buffer = try std.json.Stringify.valueAlloc(allocator, config, .{ .whitespace = .indent_2 });
    defer allocator.free(buffer);

    var file = try cwd.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, buffer);
    try file.writeStreamingAll(io, "\n");
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

    const parsed = try std.json.parseFromSlice(
        Config,
        allocator,
        buffer,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed },
    );
    defer parsed.deinit();

    var cloned = try parsed.value.clone(allocator);
    defer cloned.deinit(allocator);

    try std.testing.expectEqual(.lmstudio, cloned.provider);
    try std.testing.expectEqualStrings("http://127.0.0.1:1234", cloned.providerEntryConst(.lmstudio).url);
    try std.testing.expectEqualStrings("", cloned.providerEntryConst(.lmstudio).model);
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

test "isValidUtf8 rejects invalid bytes" {
    try std.testing.expect(isValidUtf8("ornith-1.0-35b"));
    try std.testing.expect(!isValidUtf8(&.{0xaa}));
}

test "can deserialize valid config JSON" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "provider": "lmstudio",
        \\  "providerUrl": "http://127.0.0.1:1234",
        \\  "model": "google/gemma-4-e2b",
        \\  "prompts": {
        \\    "system": {
        \\      "prefix": "",
        \\      "suffix": "",
        \\      "override": null
        \\    },
        \\    "planning": {
        \\      "prefix": "",
        \\      "suffix": "",
        \\      "override": null
        \\    }
        \\  }
        \\}
    ;

    const parsed = try std.json.parseFromSlice(
        Config,
        allocator,
        json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed },
    );
    defer parsed.deinit();
}

test "can serialize config to JSON" {
    const allocator = std.testing.allocator;
    var cfg = Config{
        .provider = .lmstudio,
    };
    cfg.providerEntry(.lmstudio).url = "http://127.0.0.1:1234";
    cfg.providerEntry(.lmstudio).model = "google/gemma-4-e2b";

    const buffer = try std.json.Stringify.valueAlloc(allocator, cfg, .{ .whitespace = .indent_2 });
    defer allocator.free(buffer);
}
