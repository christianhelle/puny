#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

rm -rf output/

echo "Setting up Docker Buildx for kcov..."
docker buildx create --name insecure-builder --buildkitd-flags "--allow-insecure-entitlement security.insecure" 2>/dev/null || true
docker buildx use insecure-builder

echo "Building and running coverage via Docker..."
docker buildx build --progress plain --builder insecure-builder --allow security.insecure --file Dockerfile.coverage --output type=local,dest=. .

if [ -f output/cobertura.xml ]; then
    echo "Coverage report generated: output/cobertura.xml"
else
    echo "Warning: coverage report was not generated"
fi
