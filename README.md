[![CI](https://github.com/christianhelle/puny/actions/workflows/ci.yml/badge.svg)](https://github.com/christianhelle/puny/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/christianhelle/puny/graph/badge.svg?token=ZnheGzJyII)](https://codecov.io/gh/christianhelle/puny)

# Puny

Puny is a minimal natively compiled single-binary coding agent with a ~1 MB footprint.

It's designed for people who want a fast, lightweight coding agent that runs smoothly 
on limited hardware or remote machines. This is a coding agent that starts in under 1
millisecond, uses around 1 MB of disk space, uses minimal memory, uses <1% CPU,
and stays out of your way.

## Features

- **Multiple providers**: local-first LM Studio, or hosted models via OpenCode Zen, OpenCode Go, or your GitHub Copilot subscription.
- **Interactive model picker**: choose the model to load when Puny starts.
- **Multi-turn chat**: keeps the conversation history across messages.
- **Session management**: each run, `/new`, or `/reset` creates a new UUID-identified session, with the conversation automatically saved after every turn and PRDs saved to the session folder. Sessions can be resumed with `/resume` or `--session`.
- **Branch review mode**: review committed branch changes against the latest `origin/main` and produce an automation-ready merge-worthiness report.
- **Orchestrate loop**: `/orchestrate` and `--orchestrate` run implement → review → fix until the branch is merge worthy, each phase from a fresh context.
- **Tool calling**: the LLM can use built-in tools to work with your project.
- **Skills system**: extend Puny with reusable prompt-engineering skills stored in markdown files.
- **Built-in tools**:
  - Read, write, and list files in your project
  - Run shell commands
  - Search your codebase
  - Load skills
  - Fetch web pages

## Why fast and small matters

Startup time ~1ms means Puny is always ready when you are — no spinner, no animations, no
waiting. The ~1 MB binary and minimal memory footprint mean it runs comfortably on
a Raspberry Pi, a slow remote server over SSH, or a cheap decade-old laptop. 
Every millisecond and megabyte is deliberate: there is no hidden runtime, no garbage collector, 
no Node.js dependencies, no JavaScript.

## Why the feature set is intentionally limited

Puny is designed around the way I work. It is highly opinionated. That means it will
never try to be everything to everyone. It's a tool and will never take credit itself for your work
by adding itself as a co-author to your commits. It will never try to be a platform, a framework, 
or a plugin ecosystem. 

Other coding agents include MCP, subagents, plugins, extensions, animations, and dozens
of other features I never asked for. Puny does not. The feature set is limited to what
I need to get results: read files, write files, run commands, search code, load skills,
fetch web pages. If you want parallel work, run another instance.

Each feature earns its place. Nothing ships because it looks good on a comparison table.
This is not a platform — it is a tool.

Puny does not show the model's reasoning or thinking output by default. I do not care
about the model's internal monologue. I see it as a wall of text, a huge TL;DR you have
to scroll past to get to the actual answer. If you want it, pass `--show-thinking`.
If you think you want it later, pass `--chat-log` which saves the entire conversation,
noise included, to puny_chat.log

The four supported providers are the ones I use personally:

- [LM Studio](https://lmstudio.ai/) — local inference on my own hardware
- [OpenCode Zen](https://opencode.ai/zen) — wide selection of reliable optimized models
- [OpenCode Go](https://opencode.ai/go) — cheaper hosted models when I need them
- [GitHub Copilot](https://github.com/features/copilot) — comes with my sponsored GitHub subscription

Puny lets you chat with an LLM and gives it a curated set of coding tools so it can
read, edit, search, and inspect your codebase.

## Installation

### Quick Install (Recommended)

**Linux/macOS:**

```bash
curl -fsSL https://christianhelle.com/puny/install | bash
```

**Windows (PowerShell):**

```powershell
irm https://christianhelle.com/puny/install.ps1 | iex
```

The install scripts download the latest release from GitHub and install the binary (Linux/macOS detects x86_64 and aarch64; Windows currently installs the x86_64 build).

**Custom installation directory:**

```bash
# Linux/macOS
curl -fsSL https://christianhelle.com/puny/install | bash -s -- --dir "$HOME/.local/bin"
# Windows
$install = irm https://christianhelle.com/puny/install.ps1
& ([scriptblock]::Create($install)) -InstallDir "C:\Tools"
```

**Pin a specific version:**

```bash
# Linux/macOS
VERSION=v0.1.0 curl -fsSL https://christianhelle.com/puny/install | bash

# Windows
$install = irm https://christianhelle.com/puny/install.ps1
& ([scriptblock]::Create($install)) -Version "v0.1.0"
```

### Upgrade

If Puny is already installed, upgrade to the latest version:

```bash
puny --upgrade
```

This re-runs the install script for your platform.

### Build from source

Requires [Zig](https://ziglang.org/) 0.16.0 or later.

```bash
git clone https://github.com/christianhelle/puny.git
cd puny
zig build
```

The compiled binary is written to `zig-out/bin/puny`. Copy it to a directory on your PATH to run it from anywhere.

To build a release binary and install it to `$HOME/.local/bin` (the same directory used by the install scripts), run:

```bash
zig build install-release
```

Other optimization modes are available:

```bash
zig build install-release-safe   # safe release build (runtime safety checks enabled)
zig build install-release-fast   # fast release build (maximizes runtime performance)
zig build install-debug          # debug build
```

The install directory can be overridden with the `INSTALL_DIR` environment variable or the `--prefix` flag:

```bash
INSTALL_DIR=/custom/path zig build install-release
zig build install-release --prefix /custom/path
```

Run the test suite:

```bash
zig build test
```

Run the regression test suite:

```bash
zig build test-regression
```

## Quick start

On first run, Puny launches a one-time setup wizard that asks you to pick a
provider and API key (and a URL only for LM Studio; OpenCode Zen, OpenCode Go,
and GitHub Copilot use fixed URLs). Your choices are saved to `config.json` and
the wizard is skipped on later runs.

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
puny --provider opencode_zen --api-key YOUR_API_KEY
```

Puny connects to `https://opencode.ai/zen` and shows the model picker.
Puny chooses the streaming transport from the model ID:

- `muse-spark-*`, `grok-*`, and `gpt-*` use `/v1/responses`.
- `claude-*` uses Anthropic's `/v1/messages`.
- `gemini-*` uses Google's `/v1/models/<model>:streamGenerateContent`.
- All other model IDs use the OpenAI-compatible `/v1/chat/completions` endpoint.

### OpenCode Go

Sign in to [OpenCode Zen](https://opencode.ai/zen), subscribe to Go, copy your API key (same key for Zen and Go), then:

```bash
puny --provider opencode_go --api-key YOUR_API_KEY
```

Puny connects to `https://opencode.ai/zen/go` and shows the model picker.
Models beginning with `muse-spark-`, `grok-`, or `gpt-` use
`/v1/responses`; `minimax-*` and `qwen*` use Anthropic's `/v1/messages`;
all other model IDs use `/v1/chat/completions`.

Requests to OpenCode Zen and OpenCode Go carry an `x-opencode-session` header
holding the first 8 characters of the current session id — the same prefix
`--session` matches on, and short enough to read whole in OpenCode's usage
metrics — so OpenCode can group the requests belonging to one conversation.
Starting a new session with `/new` or `/reset` sends a new id; resuming a
session with `/resume` or `--session` keeps the original one. Puny also
identifies itself as `puny/<version>` in the `User-Agent` of every request.

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

## Usage

Run Puny from the project directory you want the agent to work in:

```bash
puny
```

Puny uses the provider saved during setup, shows its model picker, and opens a
chat prompt. When using LM Studio, start it and load a tool-capable model first.

### Interactive chat

Type your request and press Enter:

```text
> Explain what this project does
```

The model replies in the terminal. You can keep sending follow-up messages; Puny remembers the conversation.

```text
> Now list the source files

🔧 Listing directory "src"

The project has source files under src/, including main.c, utils.h, and a tests/ folder.
```

### Attach files to a prompt

Type `@` at the start of a prompt or after whitespace to open a searchable file
picker rooted at the current directory. Selecting a file inserts an `@path`
mention:

```text
> Explain @src/main.zig and compare it with @src/config/config.zig
```

You can also type `@path` mentions directly. Before sending the prompt, Puny
appends the contents of each readable file. Each attachment is limited to
64 KiB; unreadable files, larger files, and paths containing whitespace are not
attached.

### Repository instructions

When Puny starts inside a Git repository, it loads the first instruction file
found at the repository root in this order:

1. `AGENTS.md`
2. `.github/copilot-instructions.md`
3. `CLAUDE.md`

Only one file is loaded. Use it for project-specific build commands,
conventions, and constraints that should apply to every request. Puny restores
these instructions after `/new`, `/reset`, and between orchestrate phases.

### One-shot prompt

Run one prompt and exit:

```bash
puny --prompt "List all source files" --oneshot
```

`--oneshot` requires either `--prompt` or `--prompt-file`. It reuses the model
saved during setup; pass `--model` (or set `PUNY_MODEL`) to make an unattended
run independent of that saved selection:

```bash
puny --model model-id --prompt "List all source files" --oneshot
```

On a fresh installation, run `puny` once to complete the setup wizard before
using one-shot mode in a non-interactive job.

### Review a branch

Run one autonomous review of the current branch and exit:

```bash
puny --review
```

Puny fetches `origin/main`, fixes the review scope to
`merge-base(origin/main, HEAD)..HEAD`, reviews committed changes, and writes
`review-results.md` in the repository root. Staged, modified, and untracked
work is reported separately and does not affect the branch verdict. Existing
build, test, and lint checks run in the current worktree, so their generated
artifacts are allowed, but review mode does not expose generic file writing.

The report always includes review scope, change summary, quality and regression
assessment, validation performed, findings, and a binary conclusion:
`MERGE WORTHY: YES` or `MERGE WORTHY: NO`. Incomplete evidence forces `NO`.
A branch with no committed changes also receives `NO`.

| Exit code | Meaning |
| --------- | ------- |
| `0` | Review completed and the branch is merge worthy |
| `1` | Review completed and the branch is not merge worthy |
| `2` | Retryable operational failure; a `NO` fallback report is written when possible |

Review mode rejects `main`, detached HEAD, and directories outside a Git
repository. Invoking it on `main` exits with code `2` without writing a report.
For a single autonomous review pass use `puny --review` directly. To loop
`implement → review → fix` until merge worthy, use `/orchestrate` or
`--orchestrate` (see below).

### Orchestrate an implement → review → fix loop

`/orchestrate` and `--orchestrate` run the autonomous flow
`[plan] → implement → (while review != merge worthy) → fix findings` in a single
process, and exit with the same code `puny --review` would.

```text
[plan (interactive, /orchestrate --plan only)]
  → implement (build mode, the model commits as it works)
    → commit anything left in the worktree (excluding generated files)
    → review (0 = merge worthy, 1 = rejected, 2 = operational failure)
    → on 0: done; on 1: feed review-results.md back for fixes and loop
```

Every phase starts from a **fresh conversation** and hands off through
artifacts — the saved PRD into implement, commits into review, and
`review-results.md` back into fix. Nothing accumulates across phases, so the
loop stays inside the context window of a small local model.

```bash
# Implement, then loop until merge worthy (default 5 iterations)
puny --orchestrate --prompt "Add CSV export to the report command"

# From a spec file, capped at 3 iterations
puny --orchestrate --prompt-file spec.md --max-iterations 3
```

Inside a chat session:

```text
/orchestrate Add CSV export to the report command
/orchestrate --iterations 3 Add CSV export
/orchestrate --plan Add CSV export     # plan interactively first, then run
/orchestrate                           # implement the PRD this session saved
```

`/orchestrate --plan` runs the normal interactive planning interview. The loop
starts by itself the moment the model calls `save_prd`, reading the PRD straight
from the session folder — nothing is copied into your repository. Bare
`/orchestrate` does the same for a plan the session already has.

The headless `--orchestrate` flag never plans: it needs `--prompt` or
`--prompt-file` and goes straight to implementing.

**Commits.** The review only sees committed changes, so the model is told to
commit as it works: one logical change per commit, one-line plain-English
imperative messages, no Conventional Commits prefixes, no trailers, no
co-author, never pushing or amending. Anything it leaves behind is swept into a
single backstop commit before the review runs, so a review never passes
judgement on a partial diff. `review-results.md`, `puny_http.log`, and
`puny_chat.log` are never committed. Override the instructions with the
`prompts.orchestrate` entry in `config.json`.

Preconditions: run from a repository on a feature branch (not `main`, not
detached HEAD). The branch needs `origin/main` available so the review can
compute `merge-base(origin/main, HEAD)..HEAD`.

| Flag | Meaning |
| ---- | ------- |
| `--orchestrate` | Run the loop headlessly and exit with the review's code (requires `--prompt` or `--prompt-file`) |
| `--max-iterations <n>` | Maximum review iterations; a fix runs between reviews, not after the last one (default `5`) |
| `/orchestrate [task]` | Run the loop in a chat session; with no task, implement the session's `plan.md` |
| `/orchestrate --plan <task>` | Plan interactively first, then start the loop when the PRD is saved |
| `/orchestrate --iterations <n>` | Per-run iteration cap (alias `--max-iterations`) |

Exit codes mirror `puny --review`: `0` merge worthy, `1` still not merge worthy
after the iteration budget, `2` operational failure (missing repo, detached
HEAD, on `main`, fetch failure, a failed commit, or an interrupted run).

Press `Ctrl+C` to stop a run. Work already committed stays committed; anything
still in the worktree is left for you. Interrupts are noticed between phases —
use double-`Esc` to cancel a turn already in flight.


### Prompt from a file or URL

Load the first prompt from a local file or an `http://`/`https://` URL, either
at startup via the CLI or interactively with `/file`:

```bash
# CLI: local file or remote URL, optionally one-shot
puny --model model-id --prompt-file spec.md --oneshot
puny --prompt-file https://example.com/spec.md

# Interactive
/file spec.md
/file https://example.com/spec.md
```

At startup, `--prompt-file` loads the content and sends it as the first user
message, exactly like `--prompt`. `--oneshot` accepts `--prompt-file` in place
of `--prompt`, and using both `--prompt` and `--prompt-file` is an error.

In the interactive loop, `/file` loads the content and sends it as the next
user message instead.

Both flows load from local files or remote URLs; local files and remote
responses are limited to 10 MiB, and remote fetches time out after 30 seconds.

### Select a provider

Use `--provider` to switch between LM Studio (`lmstudio`, the default),
OpenCode Zen (`opencode_zen`), OpenCode Go (`opencode_go`), and GitHub Copilot
(`copilot`). The same identifiers apply to `PUNY_PROVIDER` and the `provider`
field in `config.json`.

```bash
puny --provider opencode_zen --api-key YOUR_API_KEY
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

OpenCode Zen and OpenCode Go require an API key. Puny exits early with a hint if the key is missing.

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

1. **Provider** — LM Studio (`lmstudio`), OpenCode Zen (`opencode_zen`), OpenCode Go (`opencode_go`), or GitHub Copilot (`copilot`).
2. **Provider URL** — only for LM Studio; press Enter to use the default. OpenCode Zen, OpenCode Go, and GitHub Copilot use fixed URLs (`https://opencode.ai/zen`, `https://opencode.ai/zen/go`, and `https://api.githubcopilot.com` respectively).
3. **API key** — press Enter to keep the existing key, or `-` to clear it.

Once saved, Puny uses the stored provider and key on subsequent runs, so you only need to pass `--provider` or `--api-key` again if you want to override them for a single session. If an OpenCode Zen or OpenCode Go request fails with an authentication error, Puny prints an auth hint; use `--reconfigure` to update the key.

`--url` and `PUNY_PROVIDER_URL` only affect LM Studio; OpenCode Zen always uses `https://opencode.ai/zen`, OpenCode Go always uses `https://opencode.ai/zen/go`, and GitHub Copilot always uses `https://api.githubcopilot.com`.

The config file stores per-provider settings (URL, API key, and last-selected model) so you can switch between providers without re-entering credentials.

### API key protection

Puny does not write API keys to `config.json` as clear text. When Puny saves a
configuration containing keys, each key is encrypted at rest with
XChaCha20-Poly1305 and written as an `enc:v1:` blob. The encryption key is a
random 32-byte file that never leaves your machine:

| OS      | Key file location                                                        |
| ------- | ----------------------------------------------------------------------- |
| Linux   | `$XDG_DATA_HOME/puny/encryption.key` → `~/.local/share/puny/encryption.key` |
| macOS   | `$XDG_DATA_HOME/puny/encryption.key` → `~/.local/share/puny/encryption.key` |
| Windows | `%LOCALAPPDATA%\puny\encryption.key` → `%USERPROFILE%\puny\encryption.key`  |

The key file is created automatically (permissions `0600` on POSIX) the first
time a configuration containing an API key is saved, and `config.json` itself
is written with `0600` permissions on POSIX.

- **Existing plaintext keys** are migrated to encrypted blobs on the next
  configuration save (`--reconfigure`, `/config`, `/provider`, or the Copilot
  device-flow login). Re-entering the API key during `--reconfigure` migrates
  immediately; pressing Enter on every prompt does not save and does not
  migrate.
- **Backups**: back up `config.json` **together with** the key file. A config
  without its key file degrades gracefully — Puny warns and treats the stored
  keys as unset until you re-enter them with `--reconfigure`.
- **Docker**: the key file lives in the container's writable layer
  (`/app/.local/share/puny/encryption.key`). Recreating the container loses it,
  so mount a volume for `/app/.local/share/puny` (or `/app`) to keep stored
  keys across container recreation.
- **No keys at rest**: if you prefer not to persist credentials at all, pass
  `--api-key`, `--api-key-file`, `PUNY_API_KEY`, or
  `GITHUB_COPILOT_OAUTH_TOKEN` per session — these are never written to disk.

This protects against accidental exposure — a leaked, synced, or committed
`config.json` contains no usable credentials. It does not defend against an
attacker who already has full access to your user account (they can read the
key file and process memory like any other tool).

## Skills

Puny can load reusable prompt-engineering skills from markdown files. Skills are
instructions that get injected into the system prompt so the model knows how to
behave for a specific task. They can be loaded by slash command, by mentioning
a trigger phrase in your message, or by the model itself via tool call.

To disable skills entirely, pass `--no-skills` (or set `PUNY_NO_SKILLS=1`). No
skill directories are scanned, `/skills` reports that skills are disabled, and
skill commands are treated as ordinary prompts.

### Skill locations

Puny scans two directories for skills:

- **Global**: `~/.agents/skills/` — skills available across all repositories
- **Repository**: `<repo-root>/.agents/skills/` — project-specific skills (auto-detected via `git rev-parse --show-toplevel`)

Each subdirectory inside these paths is treated as a skill. The skill's name is the
directory name.

### Skill structure

A skill directory must contain a `SKILL.md` file. The file starts with YAML frontmatter
that can include the following fields:

```markdown
---
name: my-skill
description: >
  Expert knowledge of MyTool for integration testing.
  Covers setup, configuration, and common patterns.
triggers: mytool, integration test, configure
disable-model-invocation: false
---

# MyTool Instructions

When asked about MyTool, follow these guidelines...
```

| Field                      | Required | Description                                                                                |
| -------------------------- | -------- | ------------------------------------------------------------------------------------------ |
| `name`                     | Yes      | Canonical identifier (must match the directory name)                                       |
| `description`              | Yes      | Short summary shown in `/skills` output and the `<available_skills>` block                 |
| `triggers`                 | No       | Comma-separated phrases that auto-load the skill when mentioned in a user message          |
| `disable-model-invocation` | No       | Set to `true` to prevent the model from loading this skill via tool call (default `false`) |

The body after the frontmatter is the skill content that gets injected into the
conversation when the skill is loaded.

### Loading a skill

Skills can be loaded in three ways:

1. **Slash command** — type `/<skill-name>` in the prompt:

   ```text
   > /nano-commits
   ```

2. **Keyword trigger** — mention a trigger phrase from the skill's `triggers` field in your
   message. For example, a `caveman` skill with `triggers: talk like caveman, be brief`
   loads automatically when you say:

   ```text
   > talk like caveman from now on
   ```

   Skills are also triggered by their directory name as a whole word — saying
   `grill me on this design` loads the `grill-me` skill.

3. **Model invocation** — the model can load a skill it considers relevant by calling the
   `load_skill` tool. This happens automatically when the model sees a matching skill in
   the `<available_skills>` block. Skills with `disable-model-invocation: true` won't
   appear for model invocation and must be loaded by slash command only.

### Listing available skills

Use `/skills` to list all discovered skills from both global and repository locations:

```text
> /skills

Available skills:

  nano-commits
  grill-me
```

Skills with a `description` field in their frontmatter show a description next to
their name.

### How skills work

When Puny starts, it scans both skill directories and builds a registry. Available
skills and their descriptions (if scanned) are injected into the system prompt as an
`<available_skills>` block:

```xml
<available_skills>
  <skill>
    <name>nano-commits</name>
    <description>Commit often. One logical change per commit.</description>
  </skill>
</available_skills>
```

When a skill is loaded (via slash command, keyword trigger, or model invocation),
Puny reads the `SKILL.md` body, strips the frontmatter, and adds the content as a
system message. The model can then follow the skill's instructions for the remainder
of the conversation.

Skills stay loaded for the session. To clear all loaded skills, use `/reset`.

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

| Flag                    | Description                                                                               |
| ----------------------- | ----------------------------------------------------------------------------------------- |
| `--provider <name>`     | Provider: `lmstudio`, `opencode_zen`, `opencode_go`, or `copilot` (CLI/env/config precedence) |
| `-u`, `--url <url>`     | LM Studio endpoint URL (default: `http://127.0.0.1:1234`)                                 |
| `-k`, `--api-key <key>` | Provider API token (session only)                                                         |
| `--api-key-file <path>` | Read provider API token from file (session only)                                          |
| `--chat-log`            | Save full conversation (including reasoning) to `puny_chat.log`                           |
| `--no-skills`           | Disable skill loading entirely (slash commands, triggers, and model invocation)          |
| `-m`, `--model <id>`    | Model identifier (skips picker if found in running models)                                |
| `-p`, `--prompt <text>` | Pre-fill prompt as first user message                                                     |
| `--prompt-file <file-or-url>` | Read first prompt from a file or URL (10 MiB limit) |
| `-1`, `--oneshot`, `--one-shot` | Exit after processing the prompt (requires `--prompt` or `--prompt-file`)                              |
| `--review`               | Review the current branch against the latest `origin/main`, write `review-results.md`, and exit       |
| `--orchestrate`          | Implement, review, and fix the current branch until merge worthy, then exit (requires `--prompt` or `--prompt-file`) |
| `--max-iterations <n>`   | Maximum review iterations for `--orchestrate`; a fix runs between reviews, not after the last one (default `5`) |
| `-M`, `--mock`          | Use mock provider (no backend required)                                                   |
| `--reconfigure`         | Re-run first-run setup and update config                                                  |
| `--show-thinking`       | Show reasoning/thinking output from the model                                             |
| `--session <id>`        | Resume a previous session by UUID or unique prefix                                        |
| `--resume`              | Resume the most recent session with a saved conversation                                  |
| `--prune`               | Delete old sessions (use with `--session` to keep one)                                    |
| `--debug`               | Log HTTP requests and responses to `puny_http.log`                                       |
| `-U`, `--upgrade`       | Upgrade to the latest release via install script                                          |
| `--force`               | Force upgrade even if already on the latest version (use with `--upgrade`)                |
| `-h`, `--help`          | Show help text                                                                            |
| `-V`, `--version`       | Print version                                                                             |

### Environment variables

| Variable                     | Description                                         |
| ---------------------------- | --------------------------------------------------- |
| `PUNY_CHAT_LOG`              | Set to `1` or `true` to save full conversation to `puny_chat.log` |
| `PUNY_PROVIDER`              | Default provider name (overrides config)            |
| `PUNY_PROVIDER_URL`          | LM Studio endpoint URL (overrides config, unless `--url` is set) |
| `PUNY_API_KEY`               | Provider API token (overrides config, session only) |
| `PUNY_MODEL`                 | Default model identifier (overrides config)         |
| `PUNY_MOCK`                  | Set to `1` or `true` to enable mock provider        |
| `PUNY_NO_SKILLS`             | Set to `1` or `true` to disable skill loading       |
| `PUNY_SHOW_THINKING`         | Set to `1` or `true` to show reasoning output       |
| `GITHUB_COPILOT_OAUTH_TOKEN` | GitHub OAuth token for Copilot provider             |

### Interactive commands

While in a chat session:

- `/quit` or `/exit` — exit Puny
- `/new` or `/reset` — clear the conversation, start a new session, and unload all skills
- `/stats` — show session statistics and memory usage
- `/config` — reconfigure provider, URL, and API key mid-session; changing the provider rebuilds the connection and re-opens the model picker
- `/plan [task]` — enter planning mode (optionally with a task description); the resulting PRD is saved to the session folder as `plan.md`
- `/build [task]` — switch to build mode (optionally with a task description)
- `/review` — review committed changes against the latest `origin/main`; remain in read-only review mode afterward
- `/orchestrate [task]` — run the implement to review to fix loop until the branch is merge worthy; `--plan <task>` plans interactively first, `--iterations <n>` caps the rounds, and a bare `/orchestrate` implements the PRD this session saved
- `/model [id]` — switch to another model; shows the model picker if no ID is given
- `/provider` — open the provider picker, then choose a model for the new provider
- `/thinking [level]` — change the reasoning effort of the current model; shows the effort picker if no level is given (valid levels: `default`, `none`, `minimal`, `low`, `medium`, `high`, `xhigh`)
- `/sessions` — list all saved sessions, showing their UUID, whether they have a `plan.md` or saved conversation, and a preview of the first user message
- `/resume [id]` — list saved sessions and pick one to restore, or restore a specific session by UUID prefix
- `/prune` — delete all session directories except the current one
- `/skills` — list all available global and repository skills (prints "Skills are disabled." with `--no-skills`)
- `/file <path|url>` — load a prompt from a local file or URL and send it as the next message

Any unrecognized slash command (e.g. `/nano-commits`, `/grill-me`) is treated as a
skill name and loads the matching skill if found. With `--no-skills` these commands
are treated as ordinary prompts instead.

Skills also load automatically when your message contains the skill's directory name
or a trigger phrase listed in its frontmatter `triggers` field. The model can also
load skills on its own via the `load_skill` tool.

### Sessions

Each Puny session is identified by a UUID. A new session is created every time you
start Puny or run `/new` (or `/reset`). The session ID is shown in the welcome screen and in
the `/stats` header.

#### Storage

Sessions are stored at `~/.config/puny/sessions/<uuid>/` (Linux/macOS) or
`%APPDATA%\puny\sessions\<uuid>\` (Windows). The base directory is configurable:
use `$XDG_CONFIG_HOME/puny` when set on Linux/macOS, and on Windows fall back to
`%USERPROFILE%\puny` when `%APPDATA%` is unavailable. Each session folder can contain:

| File            | Description                                                     |
| --------------- | --------------------------------------------------------------- |
| `plan.md`       | PRD markdown produced by the model during `/plan` mode          |
| `plan.html`     | HTML version of the PRD                                         |
| `messages.json` | Full conversation history, saved automatically after every turn |
| `session.json`  | Session metadata (agent mode, first user prompt)                 |

#### Conversation persistence

The entire conversation is saved to `messages.json` in the session folder after
every completed chat turn. It is also saved automatically when you exit the
session (`/quit`, `Ctrl+C`) or run `/reset`. Tool call results are included in
the save so the restored session has the full context.

Sessions that end with no real content — no user message, no assistant reply,
and no `plan.md`/`plan.html` — are removed automatically on exit so empty
session folders don't accumulate.

#### Restoring a session

You can resume a previous session in several ways:

- **CLI flag**: `puny --session <uuid-or-prefix>` loads a specific session by
  UUID or unique prefix. Use `--session` with a partial UUID for prefix matching
  (e.g. `puny --session abc-12` matches `abc-1234-...`).
- **CLI flag**: `puny --resume` resumes the most recent session with a saved
  conversation. If multiple sessions have saved conversations, a hint is printed.
- **CLI flag**: `puny --prune` deletes all session directories. Use
  `puny --prune --session <uuid>` to delete all sessions except the one to keep.
- **Interactive**: `/resume` inside a chat session lists all saved sessions
  that have conversations and lets you pick one to restore. You can also pass
  a prefix: `/resume abc-12`.
- **In-session restore**: Calling `/resume` replaces the current conversation
  with the saved one, keeping the same provider and model configuration.

When a session is restored, the system prompt, skills blocks, and agent mode
are restored exactly as they were saved — the conversation picks up where it
left off.

#### Planning mode

In planning mode the model can only read files, list directories, search code,
check git status/diff, and fetch web pages — plus use the `save_prd` tool to
write the final PRD. When the user confirms readiness, the model calls
`save_prd` with markdown and HTML content, which writes both `plan.md` and
`plan.html` to the session folder. Planning mode state is persisted in
`session.json` and restored when the session is resumed.

#### Review mode

Run `/review` inside a chat to perform the same branch review as `--review`
without exiting Puny. After the report is written, the session remains in
read-only review mode for follow-up questions. Use `/build` to allow source
changes again or `/plan` to enter planning mode.

## Development / testing

### Mock mode (no LM Studio, OpenCode Zen, or GitHub Copilot required)

Start without a running AI backend:

```bash
zig build run -- --mock
```

You can also set the `PUNY_MOCK` environment variable:

```bash
export PUNY_MOCK=1
zig build run
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

### Show thinking/reasoning output

To see the model's internal reasoning (thinking) output, use `--show-thinking`:

```bash
puny --show-thinking
```

Or set the `PUNY_SHOW_THINKING` environment variable:

```bash
export PUNY_SHOW_THINKING=true
puny
```

To verify this works without a real backend, use the mock provider's `reasoning`
keyword, which streams a large amount of dimmed reasoning output before the
final answer:

```bash
zig build run -- --mock --model mock-model --prompt "respond with reasoning" --show-thinking --oneshot
```

### HTTP debug logging

To log all HTTP requests and responses to `puny_http.log`, use `--debug`:

```bash
puny --debug
```

The debug log captures request payloads, response headers, and SSE chunks for troubleshooting. JSON bodies are pretty-printed for readability.

## License

MIT
