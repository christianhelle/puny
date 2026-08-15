const std = @import("std");
const builtin = @import("builtin");
const prompts = @import("./prompts.zig");
const provider = @import("./provider.zig");
const load_save = @import("./load_save.zig");

pub const Config = load_save.Config;
pub const LoadResult = load_save.LoadResult;
pub const default_lm_studio_url = load_save.default_lm_studio_url;

pub fn load(allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) !LoadResult {
    return load_save.load(allocator, io, environ_map);
}

pub fn save(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    environ_map: *const std.process.Environ.Map,
) !void {
    return load_save.save(allocator, io, config, environ_map);
}

pub fn configPath(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    return load_save.configPath(allocator, environ_map);
}