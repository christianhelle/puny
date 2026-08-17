#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

rm -rf coverage/

echo "Running tests with coverage instrumentation..."
zig build test-coverage --summary all

echo "Coverage report generated in coverage/ directory"
