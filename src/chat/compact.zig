const std = @import("std");

/// Tracks how large the conversation may grow before it is compacted.
pub const ContextBudget = struct {
    /// Budget set by `/context`, `--max-context`, or `max_context_tokens`.
    explicit: ?usize = null,
    /// Context window the provider reports for the active model, if any.
    model_reported: ?usize = null,

    /// The effective token limit, or null when auto compaction is off.
    pub fn limit(self: *const ContextBudget) ?usize {
        return self.explicit orelse self.model_reported;
    }
};

test "limit prefers the explicit budget over the model's reported window" {
    const budget = ContextBudget{ .explicit = 32000, .model_reported = 128000 };
    try std.testing.expectEqual(@as(?usize, 32000), budget.limit());
}

test "limit falls back to the model's reported window" {
    const budget = ContextBudget{ .model_reported = 128000 };
    try std.testing.expectEqual(@as(?usize, 128000), budget.limit());
}

test "limit is null when nothing is known" {
    const budget = ContextBudget{};
    try std.testing.expectEqual(@as(?usize, null), budget.limit());
}
