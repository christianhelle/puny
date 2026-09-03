# Docker

Puny is published as a container image to both Docker Hub and GitHub Container Registry.

## Pull the image

From Docker Hub:

```bash
docker pull christianhelle/puny:latest
```

From GitHub Container Registry:

```bash
docker pull ghcr.io/christianhelle/puny:latest
```

## Run interactively

Mount your project directory into `/app` and allocate a TTY so Puny can read and edit files:

```bash
docker run -it --mount "type=bind,source=${PWD},target=/app" christianhelle/puny
```

Puny starts in the current directory and shows the model picker.

## One-shot prompt

Run a single prompt and exit:

```bash
docker run --mount "type=bind,source=${PWD},target=/app" christianhelle/puny --prompt "List all source files" --oneshot
```

## LM Studio

LM Studio must be reachable from inside the container. If it is running on the Docker host, use the host's address or `host.docker.internal` on Docker Desktop:

```bash
docker run -it --mount "type=bind,source=${PWD},target=/app" christianhelle/puny --url http://host.docker.internal:1234
```

## OpenCode Zen

```bash
docker run -it --mount "type=bind,source=${PWD},target=/app" christianhelle/puny --provider opencode_zen --api-key YOUR_API_KEY
```

## OpenCode Go

```bash
docker run -it --mount "type=bind,source=${PWD},target=/app" christianhelle/puny --provider opencode_go --api-key YOUR_API_KEY
```

## GitHub Copilot

Pass a discovered or manually issued GitHub OAuth token via `PUNY_API_KEY` (device-flow
login needs an interactive terminal). Replace `gho_...` below with your actual token:

```bash
# Replace gho_... with your GitHub OAuth token
docker run -it --mount "type=bind,source=${PWD},target=/app" -e PUNY_API_KEY=gho_... christianhelle/puny --provider copilot
```

## Available tags

- `latest`
- Semantic versions: `1.2.3`, `1.2`, `1`
- Branch refs

## Build the image locally

The Dockerfile is generated on demand and not checked into the repo. Use `zig build docker` to build the Docker-optimized release binary and the docker image:

```bash
zig build docker
```

This is equivalent to `zig build -Doptimize=ReleaseSmall -Dtarget=x86_64-linux -Ddocker` and sets the default LM Studio URL to `http://host.docker.internal:1234`.

Run the locally built image the same way as the published one:

```bash
docker run -it --mount "type=bind,source=${PWD},target=/app" puny:local
```

## API key security

The examples above pass `--api-key` inline for simplicity. For shared or production environments, prefer mounting a key file with `--api-key-file` or a `config.json` instead.
