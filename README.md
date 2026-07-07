# Puny

A minimal local-AI coding agent for the terminal, powered by [LM Studio](https://lmstudio.ai/).

Puny lets you chat with a local LLM and gives it a curated set of coding tools so it can read, edit, search, and inspect your codebase.

## Features

- Local-first: talks to LM Studio running on `http://127.0.0.1:1234`.
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

## Commands

- `/quit` or `/exit` — exit Puny
- `/reset` — clear the conversation history

## Tool calling

Puny sends a list of available tools to the model on every request. When the model decides to call a tool, Puny executes it automatically and feeds the result back into the conversation.

### ⚠️ Safety warning

Tools execute **automatically without confirmation**. This includes `write_file` (which overwrites files) and `execute_shell` (which runs arbitrary commands). Only run Puny in directories where you are comfortable with the model making changes.

## Architecture

- `src/main.zig` — terminal loop, message history, tool execution loop
- `src/chat.zig` — stream accumulator for OpenAI-compatible SSE deltas
- `src/providers/openai.zig` — `/v1/chat/completions` client
- `src/providers/lmstudio.zig` — generated LM Studio REST client (models, load, etc.)
- `src/tools/` — tool definitions, schemas, and handlers
- `src/tui/` — interactive model picker

## Tests

```bash
zig build test
```

## License

MIT
