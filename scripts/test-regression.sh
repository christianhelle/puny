#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pwsh -NoLogo -File "$DIR/test-regression.ps1" "$@"
