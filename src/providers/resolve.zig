const std = @import("std");
const cli = @import("../cli/args.zig");
const config = @import("../config/config.zig");
const provider = @import("provider.zig");
const http_client = @import("client.zig");
const mock = @import("mock.zig");
const opencode_zen = @import("opencode_zen.zig");
const opencode_go = @import("opencode_go.zig");
const copilot = @import("copilot.zig");

const ModelProvider = provider.ModelProvider;

pub fn effectiveProvider(parsed: cli.Options, cfg: config.Config) ModelProvider {
    if (parsed.provider) |p| {
        const parsed_enum = std.meta.stringToEnum(provider.ModelProvider, p);
        if (parsed_enum) |val| return val;
    }
    return cfg.provider;
}

pub fn baseUrlFor(model_provider: ModelProvider, parsed: cli.Options, cfg: config.Config) []const u8 {
    if (providerHasFixedUrl(model_provider)) return defaultProviderUrl(model_provider);
    if (parsed.url) |url| return url;
    const entry = cfg.providerEntryConst(model_provider);
    if (entry.url.len > 0) return entry.url;
    return config.default_lm_studio_url;
}

pub fn resolveApiKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    parsed: cli.Options,
    cfg: config.Config,
    effective_provider: provider.ModelProvider,
    api_key_env: ?[]const u8,
) ![]const u8 {
    if (parsed.api_key) |key| return key;

    if (parsed.api_key_file) |path| {
        const cwd = std.Io.Dir.cwd();
        const data = try cwd.readFileAlloc(io, path, allocator, std.Io.Limit.limited(1024));
        return std.mem.trim(u8, data, &std.ascii.whitespace);
    }

    if (api_key_env) |key| return key;

    if (effective_provider == .mock) return "";
    return cfg.providerEntryConst(effective_provider).apiKey orelse "";
}

pub fn providerHasFixedUrl(selectedProvider: provider.ModelProvider) bool {
    return selectedProvider == .opencode_zen or
        selectedProvider == .opencode_go or
        selectedProvider == .copilot or
        selectedProvider == .mock;
}

pub fn defaultProviderUrl(selectedProvider: provider.ModelProvider) []const u8 {
    if (selectedProvider == .opencode_zen) return opencode_zen.default_base_url;
    if (selectedProvider == .opencode_go) return opencode_go.default_base_url;
    if (selectedProvider == .copilot) return copilot.default_base_url;
    if (selectedProvider == .mock) return "-";
    return config.default_lm_studio_url;
}

pub fn createProvider(
    is_mock: bool,
    prov: ModelProvider,
    url: []const u8,
    api_key: []const u8,
    arena: std.mem.Allocator,
    io: std.Io,
) provider.Provider {
    if (is_mock) return .{ .mock = mock.MockClient.init(arena, io) };
    switch (prov) {
        .lmstudio => {
            var c = http_client.Client.init(arena, io, api_key);
            c.withBaseUrl(url);
            return .{ .lmstudio = c };
        },
        .opencode_zen => {
            var c = http_client.Client.init(arena, io, api_key);
            c.withBaseUrl(url);
            return .{ .opencode = c };
        },
        .opencode_go => {
            var c = http_client.Client.init(arena, io, api_key);
            c.withBaseUrl(url);
            return .{ .opencode_go = c };
        },
        .copilot => {
            var c = copilot.Client.init(arena, io, api_key);
            c.withBaseUrl(url);
            return .{ .copilot = c };
        },
        .mock => {
            return .{ .mock = mock.MockClient.init(arena, io) };
        },
    }
}

pub fn ensureCopilotAuth(
    arena: std.mem.Allocator,
    io: std.Io,
    init: std.process.Init,
    cfg: *config.Config,
    stdout_writer: *std.Io.Writer,
    prov: *provider.Provider,
) !void {
    const client = prov.asCopilot() orelse return;
    if (client.github_token.len > 0) return;

    if (try copilot.discoverGithubToken(arena, io, init.environ_map)) |token| {
        client.setGithubToken(token);
        return;
    }

    const token = (try copilot.deviceLogin(client, stdout_writer)) orelse return error.MissingApiKey;
    client.setGithubToken(token);

    cfg.providerEntry(.copilot).apiKey = try arena.dupe(u8, token);
    cfg.providerEntry(.copilot).stored_blob = null;
    config.save(arena, io, cfg.*, init.environ_map) catch |err| {
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
        const stderr_writer = &stderr_file_writer.interface;
        stderr_writer.print(
            "Warning: could not persist GitHub Copilot token: {s}\n",
            .{@errorName(err)},
        ) catch {};
        stderr_writer.flush() catch {};
    };
}

test "createProvider returns mock for mock flag or provider name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var by_flag = createProvider(true, .lmstudio, "http://example", "", allocator, std.testing.io);
    defer by_flag.deinit();
    try std.testing.expectEqual(std.meta.activeTag(by_flag), std.meta.Tag(provider.Provider).mock);

    var by_name = createProvider(false, .mock, "-", "", allocator, std.testing.io);
    defer by_name.deinit();
    try std.testing.expectEqual(std.meta.activeTag(by_name), std.meta.Tag(provider.Provider).mock);
}

test "resolveApiKey uses CLI key over env and config" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var cfg = config.Config{};
    cfg.providerEntry(.lmstudio).apiKey = "config-key";
    const parsed = cli.Options{ .api_key = "cli-key" };
    const key = try resolveApiKey(allocator, undefined, parsed, cfg, .lmstudio, "env-key");
    try std.testing.expectEqualStrings("cli-key", key);
}

test "resolveApiKey uses env key over config" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var cfg = config.Config{};
    cfg.providerEntry(.lmstudio).apiKey = "config-key";
    const parsed = cli.Options{};
    const key = try resolveApiKey(allocator, undefined, parsed, cfg, .lmstudio, "env-key");
    try std.testing.expectEqualStrings("env-key", key);
}

test "resolveApiKey falls back to config key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var cfg = config.Config{};
    cfg.providerEntry(.lmstudio).apiKey = "config-key";
    const parsed = cli.Options{};
    const key = try resolveApiKey(allocator, undefined, parsed, cfg, .lmstudio, null);
    try std.testing.expectEqualStrings("config-key", key);
}

test "resolveApiKey reads and trims api key file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "key.txt", .data = "file-key\n" });

    const path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "key.txt" });

    const cfg = config.Config{};
    const parsed = cli.Options{ .api_key_file = path };
    const key = try resolveApiKey(allocator, std.testing.io, parsed, cfg, .lmstudio, "env-key");
    try std.testing.expectEqualStrings("file-key", key);
}

test "effectiveProvider precedence" {
    const cfg_default = config.Config{};
    try std.testing.expectEqual(.lmstudio, effectiveProvider(.{}, cfg_default));

    const cfg_opencode = config.Config{ .provider = .opencode_zen };
    try std.testing.expectEqual(.opencode_zen, effectiveProvider(.{}, cfg_opencode));

    const parsed_flag = cli.Options{ .provider = "opencode_zen" };
    try std.testing.expectEqual(.opencode_zen, effectiveProvider(parsed_flag, config.Config{ .provider = .lmstudio }));
}

test "baseUrlFor uses CLI url for lmstudio only" {
    const cfg = config.Config{};
    const parsed = cli.Options{ .url = "http://cli.example" };
    try std.testing.expectEqualStrings("http://cli.example", baseUrlFor(.lmstudio, parsed, cfg));
    try std.testing.expectEqualStrings(opencode_zen.default_base_url, baseUrlFor(.opencode_zen, parsed, cfg));
    try std.testing.expectEqualStrings(opencode_go.default_base_url, baseUrlFor(.opencode_go, parsed, cfg));
    try std.testing.expectEqualStrings(copilot.default_base_url, baseUrlFor(.copilot, parsed, cfg));
    try std.testing.expectEqualStrings("-", baseUrlFor(.mock, parsed, cfg));
}

test "baseUrlFor uses per-provider url" {
    var cfg = config.Config{};
    cfg.providerEntry(.lmstudio).url = "http://config-lmstudio";
    try std.testing.expectEqualStrings("http://config-lmstudio", baseUrlFor(.lmstudio, .{}, cfg));
    try std.testing.expectEqualStrings(opencode_zen.default_base_url, baseUrlFor(.opencode_zen, .{}, cfg));
}

test "baseUrlFor returns provider defaults" {
    const cfg = config.Config{};
    try std.testing.expectEqualStrings("http://127.0.0.1:1234", baseUrlFor(.lmstudio, .{}, cfg));
    try std.testing.expectEqualStrings(opencode_zen.default_base_url, baseUrlFor(.opencode_zen, .{}, cfg));
    try std.testing.expectEqualStrings(opencode_go.default_base_url, baseUrlFor(.opencode_go, .{}, cfg));
    try std.testing.expectEqualStrings("-", baseUrlFor(.mock, .{}, cfg));
}

test "defaultProviderUrl returns provider-specific defaults" {
    try std.testing.expectEqualStrings(config.default_lm_studio_url, defaultProviderUrl(.lmstudio));
    try std.testing.expectEqualStrings(opencode_zen.default_base_url, defaultProviderUrl(.opencode_zen));
    try std.testing.expectEqualStrings(opencode_go.default_base_url, defaultProviderUrl(.opencode_go));
    try std.testing.expectEqualStrings(copilot.default_base_url, defaultProviderUrl(.copilot));
    try std.testing.expectEqualStrings("-", defaultProviderUrl(.mock));
}

test "providerHasFixedUrl for opencode, opencode-go, copilot and mock" {
    try std.testing.expect(providerHasFixedUrl(.opencode_zen));
    try std.testing.expect(providerHasFixedUrl(.opencode_go));
    try std.testing.expect(providerHasFixedUrl(.copilot));
    try std.testing.expect(providerHasFixedUrl(.mock));
    try std.testing.expect(!providerHasFixedUrl(.lmstudio));
}
