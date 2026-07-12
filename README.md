# Puny

A minimal local-AI coding agent for the terminal, powered by [LM Studio](https://lmstudio.ai/).

Puny lets you chat with a local LLM and gives it a curated set of coding tools so it can read, edit, search, and inspect your codebase.

## Features

- Local-first: talks to LM Studio running on `http://127.0.0.1:1234`.
- Mock mode (`--mock`): run without a real AI backend for UI/testing work.
- Interactive model picker on startup.
- Multi-turn chat with client-side message history.
- Tool calling via LM Studio's OpenAI-compatible `/v1/chat/completions` endpoint.
- Built-in tools:
  - `read_file`, `write_file`, `list_directory`
  - `execute_shell`
  - `grep_search`
  - `git_status`, `git_diff`
  - `web_fetch`

## Build

Requires [Zig](https://ziglang.org/) 0.16.0 or later.

```bash
zig build
```

## Run

Start LM Studio and load a model with tool-calling support, then:

```bash
zig build run
```

Or run the built binary directly:

```bash
./zig-out/bin/puny
```

Point to a different LM Studio instance:

```bash
zig build run -- --url http://192.168.1.42:1234
```

Run a single prompt and exit (useful for scripting):

```bash
zig build run -- --prompt "List all .zig files" --oneshot
```

### Mock mode (no LM Studio required)

Start without a running AI backend:

```bash
zig build run -- --mock
```

The mock provider returns canned responses and simulates tool calls based on keywords in your prompt:

| Prompt contains | Mock response |
|---|---|
| `read`, `file`, `code` | Calls `read_file` tool |
| `search`, `grep`, `find` | Calls `grep_search` tool |
| `shell`, `run`, `execute` | Calls `execute_shell` tool |
| `error`, `timeout`, `fail` | Simulates a network error |
| _(after a tool result)_ | Returns a completion acknowledging the result |
| _(anything else)_ | Returns a canned text response |

Use `--model` to skip the model picker in mock mode:

```bash
zig build run -- --mock --model mock-model --prompt "search for something" --oneshot
```

## CLI options

| Flag | Description |
|---|---|
| `-u`, `--url <url>` | LM Studio endpoint URL (default: `http://127.0.0.1:1234`) |
| `-m`, `--model <id>` | Model identifier (skips picker if found in running models) |
| `-p`, `--prompt <text>` | Pre-fill prompt as first user message |
| `-1`, `--oneshot` | Exit after processing the prompt (requires `--prompt`) |
| `-M`, `--mock` | Use mock provider (no LM Studio required) |
| `-h`, `--help` | Show help text |
| `-V`, `--version` | Print version |

## Interactive commands

While in a chat session:

- `/quit` or `/exit` — exit Puny
- `/reset` — clear the conversation history

## Tool calling

Puny sends a list of available tools to the model on every request. When the model decides to call a tool, Puny executes it automatically and feeds the result back into the conversation.

Tool-call status lines use concise action-oriented summaries instead of raw JSON:

```text
🔧 Reading "src/main.zig"
🔧 Running "zig test" in "src"
🔧 Writing 12 lines (384 bytes) to "src/main.zig"
```

Large payloads, such as `write_file` content, are summarized rather than printed in full.

### ⚠️ Safety warning

Tools execute **automatically without confirmation**. This includes `write_file` (which overwrites files) and `execute_shell` (which runs arbitrary commands). Only run Puny in directories where you are comfortable with the model making changes.

## Architecture

- `src/main.zig` — terminal loop, message history, tool execution loop
- `src/chat.zig` — stream accumulator for OpenAI-compatible SSE deltas
- `src/providers/provider.zig` — provider union (LM Studio or mock)
- `src/providers/openai.zig` — `/v1/chat/completions` client
- `src/providers/lmstudio.zig` — generated LM Studio REST client (models, load, etc.)
- `src/providers/mock.zig` — mock provider for testing without a backend
- `src/tools/` — tool definitions, schemas, and handlers
- `src/tui/` — interactive model picker

## Tests

```bash
zig build test
```

## License

MIT
