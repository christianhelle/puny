const std = @import("std");
const schema = @import("schema.zig");
const persistence = @import("persistence.zig");

pub const default_lm_studio_url = schema.default_lm_studio_url;
pub const isValidUtf8 = schema.isValidUtf8;
pub const PromptOverride = schema.PromptOverride;
pub const PromptsConfig = schema.PromptsConfig;
pub const Provider = schema.Provider;
pub const Config = schema.Config;
pub const LoadResult = schema.LoadResult;
pub const providerSlot = schema.providerSlot;
pub const load = persistence.load;
pub const save = persistence.save;
pub const configPath = persistence.configPath;

test "providerSlot keeps registry aligned with provider enum" {
    try std.testing.expectEqual(@as(usize, 0), providerSlot(.lmstudio));
    try std.testing.expectEqual(@as(usize, 1), providerSlot(.opencode_zen));
    try std.testing.expectEqual(@as(usize, 2), providerSlot(.opencode_go));
    try std.testing.expectEqual(@as(usize, 3), providerSlot(.copilot));
}

test "provider JSON parsing ignores internal retention fields" {
    const allocator = std.testing.allocator;
    const json = "{ \"name\": \"lmstudio\", \"apiKey\": \"api-key\", \"url\": \"http://example.com\", \"model\": \"qwen3\", \"stored_blob\": \"enc:v1:old\", \"stored_plaintext\": \"api-key\" }";

    const parsed = try std.json.parseFromSlice(
        Provider,
        allocator,
        json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("api-key", parsed.value.apiKey.?);
    try std.testing.expectEqualStrings("http://example.com", parsed.value.url);
    try std.testing.expectEqualStrings("qwen3", parsed.value.model);
    try std.testing.expect(parsed.value.stored_blob == null);
    try std.testing.expect(parsed.value.stored_plaintext == null);
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

test "configPath prefers XDG_CONFIG_HOME on non-windows" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", "/xdg");
    try env.put("HOME", "/home/user");

    const path = try configPath(std.testing.allocator, &env);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/xdg/puny/config.json", path);
}

test "configPath falls back to HOME" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/user");

    const path = try configPath(std.testing.allocator, &env);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/home/user/.config/puny/config.json", path);
}

test "configPath errors without a config dir" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectError(error.NoConfigDir, configPath(std.testing.allocator, &env));
}

test "default config names each provider slot consistently" {
    const cfg = Config.default();
    inline for (.{ .lmstudio, .opencode_zen, .opencode_go, .copilot }) |kind| {
        try std.testing.expectEqual(kind, cfg.providerEntryConst(kind).name);
        try std.testing.expect(cfg.providerEntryConst(kind).url.len > 0);
        try std.testing.expect(cfg.providerEntryConst(kind).apiKey == null);
    }
}

test "providerEntry mutates the matching slot" {
    var cfg = Config.default();
    try std.testing.expect(cfg.providerEntryConst(.lmstudio).apiKey == null);
    cfg.providerEntry(.lmstudio).apiKey = "sk-set";
    try std.testing.expectEqualStrings("sk-set", cfg.providerEntryConst(.lmstudio).apiKey.?);
}

test "save and load round-trip through a temp HOME" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const home = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(home);
    try env.put("HOME", home);

    var cfg = Config.default();
    cfg.provider = .opencode_zen;
    cfg.providerEntry(.opencode_zen).url = "https://example.com";
    cfg.providerEntry(.opencode_zen).model = "gpt-4o";
    try save(std.testing.allocator, std.testing.io, cfg, &env);

    var loaded = try load(std.testing.allocator, std.testing.io, &env);
    defer loaded.deinit();
    try std.testing.expect(loaded.file_existed);
    try std.testing.expect(!loaded.had_error);
    try std.testing.expectEqual(.opencode_zen, loaded.config.provider);
    try std.testing.expectEqualStrings("https://example.com", loaded.config.providerEntryConst(.opencode_zen).url);
    try std.testing.expectEqualStrings("gpt-4o", loaded.config.providerEntryConst(.opencode_zen).model);
}
