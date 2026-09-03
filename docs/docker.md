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

Keep the project and Puny's state on separate mounts. The project is available
at `/workspace`; the `puny-home` volume persists configuration, sessions, and
the encryption key under `/app`:

```bash
docker volume create puny-home

docker run --rm -it \
  --mount "type=bind,source=${PWD},target=/workspace" \
  --mount "type=volume,source=puny-home,target=/app" \
  --workdir /workspace \
  christianhelle/puny:latest
```

On the first run, Puny opens the setup wizard. Later containers reuse the
provider, model, credentials, and sessions stored in `puny-home`. The image runs
as the non-root user `puny` (UID/GID 1001), so that user must have write
permission to files Puny should edit on Linux hosts.

## One-shot prompt

After completing setup in an interactive container, pass a model ID so the run
does not open the model picker:

```bash
docker run --rm \
  --mount "type=bind,source=${PWD},target=/workspace" \
  --mount "type=volume,source=puny-home,target=/app" \
  --workdir /workspace \
  christianhelle/puny:latest --model model-id --prompt "List all source files" --oneshot
```

## LM Studio

LM Studio must be reachable from inside the container. If it is running on the Docker host, use the host's address or `host.docker.internal` on Docker Desktop:

```bash
docker run --rm -it \
  --mount "type=bind,source=${PWD},target=/workspace" \
  --mount "type=volume,source=puny-home,target=/app" \
  --workdir /workspace \
  christianhelle/puny:latest --url http://host.docker.internal:1234
```

## OpenCode Zen

Set `PUNY_API_KEY` in the host shell, then pass it through without placing the
token value in the Docker command:

```bash
docker run --rm -it \
  --mount "type=bind,source=${PWD},target=/workspace" \
  --mount "type=volume,source=puny-home,target=/app" \
  --workdir /workspace \
  --env PUNY_API_KEY \
  christianhelle/puny:latest --provider opencode_zen
```

## OpenCode Go

OpenCode Go uses the same API key:

```bash
docker run --rm -it \
  --mount "type=bind,source=${PWD},target=/workspace" \
  --mount "type=volume,source=puny-home,target=/app" \
  --workdir /workspace \
  --env PUNY_API_KEY \
  christianhelle/puny:latest --provider opencode_go
```

## GitHub Copilot

Set `PUNY_API_KEY` in the host shell to a discovered or manually issued GitHub
OAuth token, then pass it through. Device-flow login needs an interactive
terminal.

```bash
docker run --rm -it \
  --mount "type=bind,source=${PWD},target=/workspace" \
  --mount "type=volume,source=puny-home,target=/app" \
  --workdir /workspace \
  --env PUNY_API_KEY \
  christianhelle/puny:latest --provider copilot
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
docker run --rm -it \
  --mount "type=bind,source=${PWD},target=/workspace" \
  --mount "type=volume,source=puny-home,target=/app" \
  --workdir /workspace \
  puny:local
```

## API key security

The provider examples pass an existing host environment variable without
putting its value in shell history. Container environment variables remain
visible through Docker inspection. For shared or production environments,
mount a secrets directory read-only and use `--api-key-file`:

```bash
docker run --rm -it \
  --mount "type=bind,source=${PWD},target=/workspace" \
  --mount "type=volume,source=puny-home,target=/app" \
  --mount "type=bind,source=${HOME}/.config/puny-secrets,target=/run/secrets,readonly" \
  --workdir /workspace \
  christianhelle/puny:latest \
  --provider opencode_zen \
  --api-key-file /run/secrets/api-key
```

Create `${HOME}/.config/puny-secrets/api-key` before running the command. On
Linux, keep yourself as the owner while granting the container's numeric group
read access:

```bash
sudo chgrp 1001 "${HOME}/.config/puny-secrets" \
  "${HOME}/.config/puny-secrets/api-key"
chmod 750 "${HOME}/.config/puny-secrets"
chmod 640 "${HOME}/.config/puny-secrets/api-key"
```

Mode `0640` limits the key to its owner and the container's GID 1001, while
mode `0750` lets that group traverse the secrets directory. Alternatively, save
the key during setup; Puny encrypts it in the `puny-home` volume.
