# Puny

A minimal AI coding agent for the terminal that currently supports the following model providers, with OpenAI, Anthropic, and Google (Gemini) API compatible models:

- [LM Studio](https://lmstudio.ai/) 
- [OpenCode Zen](https://opencode.ai/zen)
- [OpenCode Go](https://opencode.ai/go)
- [GitHub Copilot](https://github.com/features/copilot)

Puny lets you chat with an LLM and gives it a curated set of coding tools so it can read, edit, search, and inspect your codebase.

## Features

- **Multiple providers**: local-first LM Studio, or hosted models via OpenCode Zen, OpenCode Go, or your GitHub Copilot subscription.
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

Puny connects to `https://opencode.ai/zen` and shows the model picker. 
Models served over OpenCode Zen's OpenAI-compatible `/v1/chat/completions` 
transport are listed (DeepSeek, GPT, GLM, Kimi, MiniMax, Grok, Big Pickle, and the free models), 
plus Qwen and Claude models served over Anthropic's `/v1/messages` transport, 
and Gemini models served over Google's `/v1/models/<model>:streamGenerateContent` transport.

### OpenCode Go

Sign in to [OpenCode Zen](https://opencode.ai/zen), subscribe to Go, copy your API key (same key for Zen and Go), then:

```bash
puny --provider opencode-go --api-key YOUR_API_KEY
```

Puny connects to `https://opencode.ai/zen/go` and shows the model picker. 
Go models are served over OpenAI-compatible `/v1/chat/completions` (DeepSeek, Grok, GLM, Kimi, MiMo)
and Anthropic `/v1/messages` (MiniMax, Qwen) transports.

### GitHub Copilot

Use Puny with your existing [GitHub Copilot](https://github.com/features/copilot) subscription:

```bash
puny --provider copilot
```

Puny resolves a GitHub OAuth token in this order:

1. A token you supply manually via `--api-key`, `--api-key-file`, `PUNY_API_KEY`,
   `config.json`, or the `GITHUB_COPILOT_OAUTH_TOKEN` environment variable.
2. Auto-discovery of an existing token from the GitHub Copilot editor plugin
   (`apps.json`/`hosts.json`) or from OpenCode's `auth.json`.
3. An interactive device-flow login: Puny prints a code and a URL to open in your
   browser, then persists the acquired token to `config.json` for future runs.

It then exchanges that OAuth token for a short-lived Copilot token and shows the model
picker. The picker lists the same curated models the GitHub Copilot CLI offers — the
models your subscription marks as picker-enabled that are served over the OpenAI-compatible
`/chat/completions` endpoint. Legacy models (e.g. GPT-3.5, GPT-4o), internal agent models,
and `/responses`-only models (e.g. GPT-5.5, GPT-5 Codex) are filtered out because Puny
can't drive them. The general-purpose `GH_TOKEN`/`GITHUB_TOKEN` environment variables are
intentionally **not** used, so an unrelated GitHub token can't break the exchange.

Support for GitHub Copilot is experimental, but both chat and tool calling work across the
listed models (Claude, GPT-5 mini, Gemini, Kimi, and more).

## Docker

Puny is published as a container image to both Docker Hub and GitHub Container Registry.

### Pull the image

From Docker Hub:

```bash
docker pull christianhelle/puny:latest
```

From GitHub Container Registry:

```bash
docker pull ghcr.io/christianhelle/puny:latest
```

### Run interactively

Mount your project directory into `/app` and allocate a TTY so Puny can read and edit files:

```bash
docker run -it --mount "type=bind,source=${PWD},target=/app" christianhelle/puny
```

Puny starts in the current directory and shows the model picker.

### One-shot prompt

Run a single prompt and exit:

```bash
docker run --mount "type=bind,source=${PWD},target=/app" christianhelle/puny --prompt "List all source files" --oneshot
```

### LM Studio

LM Studio must be reachable from inside the container. If it is running on the Docker host, use the host's address or `host.docker.internal` on Docker Desktop:

```bash
docker run -it --mount "type=bind,source=${PWD},target=/app" christianhelle/puny --url http://host.docker.internal:1234
```

### OpenCode Zen

```bash
docker run -it --mount "type=bind,source=${PWD},target=/app" christianhelle/puny --provider opencode --api-key YOUR_API_KEY
```

### OpenCode Go

```bash
docker run -it --mount "type=bind,source=${PWD},target=/app" christianhelle/puny --provider opencode-go --api-key YOUR_API_KEY
```

### GitHub Copilot

Pass a discovered or manually issued GitHub OAuth token via `PUNY_API_KEY` (device-flow
login needs an interactive terminal). Replace `gho_...` below with your actual token:

```bash
# Replace gho_... with your GitHub OAuth token
docker run -it --mount "type=bind,source=${PWD},target=/app" -e PUNY_API_KEY=gho_... christianhelle/puny --provider copilot
```

### Available tags

- `latest`
- Semantic versions: `v1.2.3`, `1.2`, `1`
- Branch refs

### Build the image locally

The Dockerfile expects a Linux binary at `artifacts/puny`. Build it with the Docker step:

```bash
zig build docker
mkdir -p artifacts
cp zig-out/bin/puny artifacts/puny
docker build -t puny:local .
```

`zig build docker` is equivalent to `zig build -Doptimize=ReleaseSmall -Dtarget=x86_64-linux -Ddocker` and sets the default LM Studio URL to `http://host.docker.internal:1234`.

Run the locally built image the same way as the published one:

```bash
docker run -it --mount "type=bind,source=${PWD},target=/app" puny:local
```

### API key security

The examples above pass `--api-key` inline for simplicity. For shared or production environments, prefer mounting a key file with `--api-key-file` or a `config.json` instead.

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

Use `--provider` to switch between LM Studio (`lmstudio`, the default), OpenCode Zen (`opencode`), OpenCode Go (`opencode-go`), and GitHub Copilot (`copilot`). You can also set `PUNY_PROVIDER` or the `provider` field in `config.json`.

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

GitHub Copilot does not need an API key up front — Puny discovers an existing GitHub
OAuth token or runs a device-flow login on first use, then persists it. You can still
supply a token manually (via `--api-key`, `PUNY_API_KEY`, or `GITHUB_COPILOT_OAUTH_TOKEN`)
to skip discovery and login.

### Save provider and API key to config

Run `--reconfigure` to choose a provider and save its URL and API key to `config.json`:

```bash
puny --reconfigure
```

You will be prompted for:

1. **Provider** — `lmstudio`, `opencode`, `opencode-go`, or `copilot`.
2. **Provider URL** — press Enter to use the provider's default. (OpenCode Zen's URL is fixed at `https://opencode.ai/zen`; GitHub Copilot's is fixed at `https://api.githubcopilot.com`.)
3. **API key** — press Enter to keep the existing key, or `-` to clear it.

Once saved, Puny uses the stored provider and key on subsequent runs, so you only need to pass `--provider` or `--api-key` again if you want to override them for a single session. If an OpenCode Zen request fails with an authentication error, Puny prints an auth hint; use `--reconfigure` to update the key.

`--url` and `PUNY_PROVIDER_URL` only affect LM Studio; OpenCode Zen always uses `https://opencode.ai/zen` and GitHub Copilot always uses `https://api.githubcopilot.com`.

## Tool calling

Puny sends a list of available tools to the model on every request. When the model decides to call a tool, Puny executes it automatically and feeds the result back into the conversation.

Tool-call status lines use concise action-oriented summaries instead of raw JSON:

```text
🔧 Reading "src/main.zig"
🔧 Running "zig build test"
🔧 Writing 12 lines (384 bytes) to "README.md"
```

Large payloads, such as file writes, are summarized rather than printed in full.

### ⚠️ Safety warning - YOLO mode by default

Tools execute **automatically without confirmation**. This includes file writes (which overwrite files) and shell commands (which run arbitrary commands). Only run Puny in directories where you are comfortable with the model making changes.

## Reference

### CLI options

| Flag                       | Description                                                |
| -------------------------- | ---------------------------------------------------------- |
| `--provider <name>`        | Provider: `lmstudio`, `opencode`, `opencode-go`, or `copilot` (env/config/CLI precedence) |
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
- `/stats` — show session statistics
- `/config` — reconfigure provider, URL, and API key mid-session; changing the provider rebuilds the connection and re-opens the model picker
- `/plan [task]` — enter planning mode (optionally with a task description)
- `/build [task]` — switch to build mode (optionally with a task description)
- `/model [id]` — switch to another model; shows the model picker if no ID is given
- `/provider [name]` — switch to another provider without reconfiguring everything; shows the provider picker if no name is given, then opens the model picker for the new provider

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

### Mock mode (no LM Studio, OpenCode Zen, or Github Copilot required)

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
