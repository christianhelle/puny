//! Aggregates the fast test modules run under zig build test.
//! Kept out of the root module so main.zig stays focused on
//! production entry-point and orchestration logic.
test "include core session tests" {
    _ = @import("core/session.zig");
}
test "include core.git_root tests" {
    _ = @import("core/git_root.zig");
}

test "include sessions module tests" {
    _ = @import("sessions/sessions.zig");
    _ = @import("sessions/index.zig");
    _ = @import("sessions/atomic_write.zig");
    _ = @import("sessions/query.zig");
    _ = @import("sessions/types.zig");
    _ = @import("sessions/validate.zig");
}

test "include chat session tests" {
    _ = @import("chat/session.zig");
}
test "include chat.session_commands tests" {
    _ = @import("chat/session_commands.zig");
}
test "include chat.persistence tests" {
    _ = @import("chat/persistence.zig");
}
test "include chat.attachments tests" {
    _ = @import("chat/attachments.zig");
}
test "include chat.debug_log tests" {
    _ = @import("chat/debug_log.zig");
}
test "include chat.redact tests" {
    _ = @import("chat/redact.zig");
}

test "include upgrade module tests" {
    _ = @import("upgrade/release.zig");
    _ = @import("upgrade.zig");
}

test "include stream markdown tests" {
    _ = @import("tui/stream_markdown.zig");
}

test "include welcome tests" {
    _ = @import("tui/welcome.zig");
}

test "include commands tests" {
    _ = @import("cli/commands.zig");
    _ = @import("cli/dispatch.zig");
}

test "include prompt file tests" {
    _ = @import("prompts/prompt_file.zig");
}

test "include prompt history tests" {
    _ = @import("prompts/history.zig");
}
test "include agents.instructions tests" {
    _ = @import("agents/instructions.zig");
}
test "include chat.chat tests" {
    _ = @import("chat/chat.zig");
    _ = @import("chat/accumulator.zig");
}
test "include chat.stats tests" {
    _ = @import("chat/stats.zig");
}
test "include chat.display tests" {
    _ = @import("chat/display.zig");
}
test "include chat.retry tests" {
    _ = @import("chat/retry.zig");
}
test "include chat.usage tests" {
    _ = @import("chat/usage.zig");
}
test "include cli.args tests" {
    _ = @import("cli/args.zig");
}
test "include config.config tests" {
    _ = @import("config/config.zig");
}
test "include config.secrets tests" {
    _ = @import("config/secrets.zig");
}
test "include core.cancel tests" {
    _ = @import("core/cancel.zig");
}
test "include core.memory tests" {
    _ = @import("core/memory.zig");
}
test "include core.retry tests" {
    _ = @import("core/retry.zig");
}
test "include core.sigint tests" {
    _ = @import("core/sigint.zig");
}
test "include models.select tests" {
    _ = @import("models/select.zig");
}
test "include providers.client tests" {
    _ = @import("providers/client.zig");
}
test "include providers.copilot tests" {
    _ = @import("providers/copilot.zig");
}
test "include providers.lmstudio tests" {
    _ = @import("providers/lmstudio/client.zig");
    _ = @import("providers/lmstudio/contracts.zig");
}
test "include providers.lmstudio_shim tests" {
    _ = @import("providers/lmstudio_shim.zig");
}
test "include providers.mock tests" {
    _ = @import("providers/mock.zig");
}
test "include providers.models tests" {
    _ = @import("providers/models.zig");
}
test "include providers.openai tests" {
    _ = @import("providers/openai.zig");
}
test "include providers.message tests" {
    _ = @import("providers/message.zig");
}
test "include providers.opencode_go tests" {
    _ = @import("providers/opencode_go.zig");
}
test "include providers.opencode_zen tests" {
    _ = @import("providers/opencode_zen.zig");
}
test "include providers.anthropic tests" {
    _ = @import("providers/anthropic.zig");
}

test "include providers.google tests" {
    _ = @import("providers/google.zig");
}
test "include providers.provider tests" {
    _ = @import("providers/provider.zig");
}

test "include providers.resolver tests" {
    _ = @import("providers/resolver.zig");
}
test "include skills.skills tests" {
    _ = @import("skills/frontmatter.zig");
    _ = @import("skills/triggers.zig");
    _ = @import("skills/skills.zig");
}
test "include tools.filesystem tests" {
    _ = @import("tools/filesystem.zig");
}
test "include tools.git tests" {
    _ = @import("tools/git.zig");
}
test "include tools.helpers tests" {
    _ = @import("tools/helpers.zig");
}
test "include tools.http tests" {
    _ = @import("tools/http.zig");
}
test "include tools.root tests" {
    _ = @import("tools/root.zig");
}
test "include tools.schema tests" {
    _ = @import("tools/schema.zig");
}
test "include tools.shell tests" {
    _ = @import("tools/shell.zig");
}
test "include tools.web tests" {
    _ = @import("tools/web.zig");
}
test "include tui.ansi tests" {
    _ = @import("tui/ansi.zig");
}
test "include tui.effort_picker tests" {
    _ = @import("tui/effort_picker.zig");
}
test "include tui.file_picker tests" {
    _ = @import("tui/file_picker.zig");
}
test "include tui.help tests" {
    _ = @import("tui/help.zig");
}
test "include tui.indicator tests" {
    _ = @import("tui/indicator.zig");
}
test "include tui.input.common tests" {
    _ = @import("tui/input/common.zig");
    _ = @import("tui/input/line_editor.zig");
    _ = @import("tui/input/mention.zig");
}
test "include tui.list_picker tests" {
    _ = @import("tui/list_picker.zig");
}
test "include tui.markdown tests" {
    _ = @import("tui/markdown/markdown.zig");
}

test "include tui.width tests" {
    _ = @import("tui/markdown/width.zig");
}

test "include tui.table tests" {
    _ = @import("tui/markdown/table.zig");
}
test "include tui.model_picker tests" {
    _ = @import("tui/model_picker.zig");
}
test "include tui.provider_picker tests" {
    _ = @import("tui/provider_picker.zig");
}
test "include tui.terminal tests" {
    _ = @import("tui/terminal.zig");
}
test "include tui.vt tests" {
    _ = @import("tui/vt.zig");
}

test "include tui.token_stats tests" {
    _ = @import("tui/token_stats.zig");
}
test "include version tests" {
    _ = @import("version.zig");
}
