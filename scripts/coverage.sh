#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

rm -rf coverage/

echo "Building test binary for coverage..."
zig build test-coverage --summary all

echo "Running kcov..."
kcov --clean --cobertura-only --include-pattern=src/ coverage zig-out/bin/test || true

if [ -f coverage/cobertura.xml ]; then
    echo "Coverage report generated: coverage/cobertura.xml"
else
    echo "Warning: coverage report was not generated (kcov may have crashed)"
fi
