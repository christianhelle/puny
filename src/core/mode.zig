const std = @import("std");

pub const AgentMode = enum {
    build,
    planning,
    review,

    pub fn blocksSourceWrites(self: AgentMode) bool {
        return self != .build;
    }
};

test "agent mode controls source write access" {
    try std.testing.expect(!AgentMode.build.blocksSourceWrites());
    try std.testing.expect(AgentMode.planning.blocksSourceWrites());
    try std.testing.expect(AgentMode.review.blocksSourceWrites());
}
