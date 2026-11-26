const std = @import("std");
const catalog = @import("../cli/command_catalog.zig");
const skills = @import("../skills/skills.zig");

/// Where a completion came from. Skills and commands share one list, so the
/// picker knows whether the entry takes an argument.
pub const Kind = enum { command, skill };

pub const Item = struct {
    /// Name as displayed and inserted, including the leading slash.
    name: []const u8,
    /// Argument hint, or "" for a command that takes none or for a skill.
    hint: []const u8,
    /// One-line description; "" when a skill has no frontmatter description.
    description: []const u8,
    kind: Kind,
    /// True when accepting the entry should append a trailing space.
    takes_arg: bool,
};

/// Where a prompt's completion list comes from: a function pointer plus its
/// context, so a test can supply a list without touching globals.
pub const Source = struct {
    ctx: ?*anyopaque,
    list: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator) std.mem.Allocator.Error![]Item,

    /// Asks the source for its items.
    pub fn items(self: Source, allocator: std.mem.Allocator) std.mem.Allocator.Error![]Item {
        return self.list(self.ctx, allocator);
    }
};

/// Case-insensitive substring match on the name, ignoring nothing: a query of
/// `mod` matches `/model`. An empty query matches every item.
pub fn matches(query: []const u8, item: Item) bool {
    if (query.len == 0) return true;
    if (query.len > item.name.len) return false;
    var i: usize = 0;
    while (i + query.len <= item.name.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(query, item.name[i .. i + query.len])) return true;
    }
    return false;
}

/// Commands in catalog order, then every skill sorted case-insensitively by
/// name. Copies the text so the caller can free the whole list at once.
pub fn buildItems(allocator: std.mem.Allocator, registry: ?*skills.Registry) std.mem.Allocator.Error![]Item {
    const skill_count = if (registry) |r| r.records.items.len else 0;
    const items = try allocator.alloc(Item, catalog.command_completions.len + skill_count);
    errdefer allocator.free(items);

    var index: usize = 0;
    for (catalog.command_completions) |entry| {
        items[index] = .{
            .name = try allocator.dupe(u8, entry.name),
            .hint = try allocator.dupe(u8, entry.hint),
            .description = try allocator.dupe(u8, entry.description),
            .kind = .command,
            .takes_arg = entry.takes_arg,
        };
        index += 1;
    }

    if (registry) |r| {
        for (r.records.items) |skill| {
            items[index] = .{
                .name = try std.fmt.allocPrint(allocator, "/{s}", .{skill.name}),
                .hint = "",
                .description = try allocator.dupe(u8, skill.description orelse ""),
                .kind = .skill,
                .takes_arg = false,
            };
            index += 1;
        }
        std.mem.sort(Item, items[catalog.command_completions.len..], {}, skillBefore);
    }

    return items;
}

fn skillBefore(_: void, a: Item, b: Item) bool {
    const order = std.ascii.orderIgnoreCase(a.name, b.name);
    if (order == .eq) return std.mem.lessThan(u8, a.name, b.name);
    return order == .lt;
}

/// Hands a registry to a prompt as a `Source`. One `Provider` backs one
/// prompt: the editor holds a pointer to it, so it has to outlive the call
/// that made it — `ChatSession.run` keeps one for the whole session.
pub const Provider = struct {
    registry: ?*skills.Registry,

    pub fn init(registry: ?*skills.Registry) Provider {
        return .{ .registry = registry };
    }

    /// The `Source` an editor stores, backed by this provider.
    pub fn source(self: *Provider) Source {
        return .{ .ctx = self, .list = listFromContext };
    }

    fn listFromContext(ctx: ?*anyopaque, allocator: std.mem.Allocator) std.mem.Allocator.Error![]Item {
        const self: *Provider = @ptrCast(@alignCast(ctx.?));
        return buildItems(allocator, self.registry);
    }
};

test "a provider builds the same list its registry describes" {
    var registry = skills.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try addSkill(&registry, "tdd", "Test first");

    var provider = Provider.init(&registry);
    const source = provider.source();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const items = try source.items(arena_state.allocator());

    try std.testing.expectEqual(catalog.command_completions.len + 1, items.len);
    try std.testing.expectEqualStrings("/tdd", items[items.len - 1].name);
    try std.testing.expectEqualStrings("Test first", items[items.len - 1].description);
}

test "a provider without a registry lists commands only" {
    var provider = Provider.init(null);
    const source = provider.source();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const items = try source.items(arena_state.allocator());
    try std.testing.expectEqual(catalog.command_completions.len, items.len);
}

test "matches is a case-insensitive substring search on the name" {
    const item = Item{ .name = "/model", .hint = "[id]", .description = "Switch model", .kind = .command, .takes_arg = true };
    try std.testing.expect(matches("mod", item));
    try std.testing.expect(matches("MOD", item));
    try std.testing.expect(matches("", item));
    try std.testing.expect(matches("/mod", item));
    try std.testing.expect(!matches("zzz", item));
}

/// Adds a skill the registry owns, so `deinit` can free it.
fn addSkill(registry: *skills.Registry, name: []const u8, description: ?[]const u8) !void {
    const allocator = registry.allocator;
    try registry.records.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .description = if (description) |d| try allocator.dupe(u8, d) else null,
        .dir_path = try allocator.dupe(u8, ""),
        .triggers = null,
        .disable_model_invocation = false,
    });
}

test "buildItems lists commands before skills, skills sorted by name" {
    var registry = skills.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try addSkill(&registry, "zebra", "Last");
    try addSkill(&registry, "alpha", null);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const items = try buildItems(arena_state.allocator(), &registry);

    try std.testing.expectEqual(catalog.command_completions.len + 2, items.len);
    try std.testing.expectEqualStrings("/quit", items[0].name);
    try std.testing.expectEqual(Kind.skill, items[catalog.command_completions.len].kind);
    try std.testing.expectEqualStrings("/alpha", items[catalog.command_completions.len].name);
    try std.testing.expectEqualStrings("/zebra", items[catalog.command_completions.len + 1].name);
    // An undescribed skill still lists, with a blank description.
    try std.testing.expectEqualStrings("", items[catalog.command_completions.len].description);
    try std.testing.expectEqualStrings("Last", items[catalog.command_completions.len + 1].description);
    try std.testing.expect(!items[catalog.command_completions.len].takes_arg);
}

test "buildItems lists commands only without a registry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const items = try buildItems(arena_state.allocator(), null);
    try std.testing.expectEqual(catalog.command_completions.len, items.len);
    for (items) |item| try std.testing.expectEqual(Kind.command, item.kind);
}
