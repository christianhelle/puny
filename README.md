# Puny

A minimal local-AI coding agent for the terminal, powered by [LM Studio](https://lmstudio.ai/).

Puny lets you chat with a local LLM and gives it a curated set of coding tools so it can read, edit, search, and inspect your codebase.

## Features

- **Local-first**: talks to LM Studio running on your own machine at `http://127.0.0.1:1234`.
- **Interactive model picker**: choose the model to load when Puny starts.
- **Multi-turn chat**: keeps the conversation history across messages.
- **Tool calling**: the LLM can use built-in tools to work with your project.
- **Built-in tools**:
  - Read, write, and list files in your project
  - Run shell commands
  - Search your codebase
  - Check git status and diff
  - Fetch web pages

## Quick start

Start LM Studio and load a model with tool-calling support, then:

```bash
puny
```

Or, if you are running from the source tree:

```bash
zig build run
```

## Usage

Make sure LM Studio is running and a tool-capable model is loaded, then start Puny:

```bash
puny
```

Puny shows the model picker, connects to LM Studio, and drops you into a chat prompt.

### Interactive chat

Type your request and press Enter:

```text
Prompt: Explain what this project does
```

The model replies in the terminal. You can keep sending follow-up messages; Puny remembers the conversation.

```text
Prompt: Now list the source files

🔧 Listing directory "src"

The project has source files under src/, including main.c, utils.h, and a tests/ folder.
```

### One-shot prompt

Run a single prompt and exit. Useful for scripts or quick tasks:

```bash
puny --prompt "List all source files" --oneshot
```

### Connect to a remote LM Studio instance

If LM Studio is running on another machine, point Puny at it:

```bash
puny --url http://192.168.1.42:1234
```

### Authenticate with LM Studio

If LM Studio requires an API token, provide it via CLI, environment variable, config file, or `--reconfigure`:

```bash
# CLI flag (session only)
puny --api-key lmstudio-token-123

# Environment variable (session only)
export PUNY_API_KEY=lmstudio-token-123
puny

# Read from a file (session only)
puny --api-key-file /run/secrets/lmstudio-key

# Save to config interactively
puny --reconfigure
```

Precedence is: `--api-key` > `--api-key-file` > `PUNY_API_KEY` > `config.json`.

## Tool calling

Puny sends a list of available tools to the model on every request. When the model decides to call a tool, Puny executes it automatically and feeds the result back into the conversation.

Tool-call status lines use concise action-oriented summaries instead of raw JSON:

```text
🔧 Reading "src/main.zig"
🔧 Running "zig build test"
🔧 Writing 12 lines (384 bytes) to "README.md"
```

Large payloads, such as file writes, are summarized rather than printed in full.

### ⚠️ Safety warning

Tools execute **automatically without confirmation**. This includes file writes (which overwrite files) and shell commands (which run arbitrary commands). Only run Puny in directories where you are comfortable with the model making changes.

## Reference

### CLI options

| Flag                       | Description                                                |
| -------------------------- | ---------------------------------------------------------- |
| `-u`, `--url <url>`        | LM Studio endpoint URL (default: `http://127.0.0.1:1234`)  |
| `-k`, `--api-key <key>`    | LM Studio API token (session only)                         |
| `--api-key-file <path>`    | Read LM Studio API token from file (session only)          |
| `-m`, `--model <id>`       | Model identifier (skips picker if found in running models) |
| `-p`, `--prompt <text>`    | Pre-fill prompt as first user message                      |
| `-1`, `--oneshot`          | Exit after processing the prompt (requires `--prompt`)     |
| `-M`, `--mock`             | Use mock provider (no LM Studio required)                  |
| `--reconfigure`            | Re-run first-run setup and update config                   |
| `-h`, `--help`             | Show help text                                             |
| `-V`, `--version`          | Print version                                              |

### Interactive commands

While in a chat session:

- `/quit` or `/exit` — exit Puny
- `/reset` — clear the conversation history
- `/config` — reconfigure provider URL and API key

## Build from source

Requires [Zig](https://ziglang.org/) 0.16.0 or later.

```bash
zig build
```

The compiled binary is written to `zig-out/bin/puny`. Copy it to a directory on your PATH to run it from anywhere.

Run the test suite:

```bash
zig build test
```

## Development / testing

### Mock mode (no LM Studio required)

Start without a running AI backend:

```bash
zig build run -- --mock
```

The mock provider returns canned responses and simulates tool calls based on keywords in your prompt:

| Prompt contains            | Mock response                                 |
| -------------------------- | --------------------------------------------- |
| `read`, `file`, `code`     | Calls `read_file` tool                        |
| `search`, `grep`, `find`   | Calls `grep_search` tool                      |
| `shell`, `run`, `execute`  | Calls `execute_shell` tool                    |
| `error`, `timeout`, `fail` | Simulates a network error                     |
| _(after a tool result)_    | Returns a completion acknowledging the result |
| _(anything else)_          | Returns a canned text response                |

Use `--model` to skip the model picker in mock mode:

```bash
zig build run -- --mock --model mock-model --prompt "search for something" --oneshot
```

## License

MIT
