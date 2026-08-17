#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

PROFDATA_FILE="coverage.profdata"
LCOV_FILE="coverage.lcov"

rm -f *.profraw "$PROFDATA_FILE" "$LCOV_FILE"

echo "Running tests with coverage instrumentation..."
LLVM_PROFILE_FILE="coverage-%p-%m.profraw" zig build test-coverage --summary all

echo "Merging profile data..."
llvm-profdata merge -sparse *.profraw -o "$PROFDATA_FILE"

echo "Generating LCOV report..."
llvm-cov export zig-out/bin/puny \
    -instr-profile="$PROFDATA_FILE" \
    --format=lcov \
    --ignore-filename-regex='.*zig-cache.*|.*\.zig-cache.*|.*build\.zig.*' \
    > "$LCOV_FILE"

echo "Coverage report generated: $LCOV_FILE"
