# Puny

A minimal AI coding agent for the terminal. 

Currently supports the following model providers, limited OpenAI and Anthropic API compatible models (no Gemini support):
- [LM Studio](https://lmstudio.ai/) 
- [OpenCode Zen](https://opencode.ai/zen)

Puny lets you chat with an LLM and gives it a curated set of coding tools so it can read, edit, search, and inspect your codebase.

## Features

- **Multiple providers**: local-first LM Studio, or hosted models via OpenCode Zen.
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

### LM Studio

Start LM Studio and load a model with tool-calling support, then:

```bash
puny
```

Or, if you are running from the source tree:

```bash
zig build run
```

### OpenCode Zen

Sign in to [OpenCode Zen](https://opencode.ai/zen), copy your API key, then:

```bash
puny --provider opencode --api-key YOUR_API_KEY
```

Puny connects to `https://opencode.ai/zen` and shows the model picker. Models served over OpenCode Zen's OpenAI-compatible `/v1/chat/completions` transport are listed (DeepSeek, GPT, GLM, Kimi, MiniMax, Grok, Big Pickle, and the free models), plus Claude models served over Anthropic's `/v1/messages` transport. Gemini and Qwen models still use unsupported transports.

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

### Select a provider

Use `--provider` to switch between LM Studio (`lmstudio`, the default) and OpenCode Zen (`opencode`). You can also set `PUNY_PROVIDER` or the `provider` field in `config.json`.

```bash
puny --provider opencode --api-key YOUR_API_KEY
```

Precedence is: `--provider` > `PUNY_PROVIDER` > `config.json` > `lmstudio`.

### Connect to a remote LM Studio instance

If LM Studio is running on another machine, point Puny at it:

```bash
puny --url http://192.168.1.42:1234
```

### Authenticate

If your provider requires an API token, provide it via CLI, environment variable, config file, or `--reconfigure`:

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

OpenCode Zen requires an API key. Puny exits early with a hint if the key is missing.

### Save provider and API key to config

Run `--reconfigure` to choose a provider and save its URL and API key to `config.json`:

```bash
puny --reconfigure
```

You will be prompted for:

1. **Provider** — `lmstudio` or `opencode`.
2. **Provider URL** — press Enter to use the provider's default. (OpenCode Zen's URL is fixed at `https://opencode.ai/zen`.)
3. **API key** — press Enter to keep the existing key, or `-` to clear it.

Once saved, Puny uses the stored provider and key on subsequent runs, so you only need to pass `--provider` or `--api-key` again if you want to override them for a single session. If an OpenCode Zen request fails with an authentication error, Puny prints an auth hint; use `--reconfigure` to update the key.

`--url` and `PUNY_PROVIDER_URL` only affect LM Studio; OpenCode Zen always uses `https://opencode.ai/zen`.

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
| `--provider <name>`        | Provider: `lmstudio` or `opencode` (env/config/CLI precedence) |
| `-u`, `--url <url>`        | LM Studio endpoint URL (default: `http://127.0.0.1:1234`)  |
| `-k`, `--api-key <key>`    | Provider API token (session only)                          |
| `--api-key-file <path>`    | Read provider API token from file (session only)           |
| `-m`, `--model <id>`       | Model identifier (skips picker if found in running models) |
| `-p`, `--prompt <text>`    | Pre-fill prompt as first user message                      |
| `-1`, `--oneshot`          | Exit after processing the prompt (requires `--prompt`)     |
| `-M`, `--mock`             | Use mock provider (no backend required)                    |
| `--reconfigure`            | Re-run first-run setup and update config                   |
| `-h`, `--help`             | Show help text                                             |
| `-V`, `--version`          | Print version                                              |

### Interactive commands

While in a chat session:

- `/quit` or `/exit` — exit Puny
- `/reset` — clear the conversation history
- `/config` — reconfigure provider, URL, and API key mid-session; changing the provider rebuilds the connection and re-opens the model picker

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
