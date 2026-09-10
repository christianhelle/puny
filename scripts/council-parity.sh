#!/bin/bash

# Checks that council.sh and council.ps1 still compose identical prompts.
#
# The two runners are hand-mirrored, and the thing that must not drift is what
# reaches the model. Both are run against the mock provider and every composed
# prompt is compared byte for byte. A full run is used rather than --dry-run so
# that rounds two, three and four are covered, which means answer extraction is
# compared too: a round-two prompt embeds round-one output, so it can only match
# if both runners extracted the same text.
#
# Run this after touching either script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MEMBERS="${PARITY_MEMBERS:-4}"
WORK_DIR=""

ANSI_GREEN=""
ANSI_RED=""
ANSI_RESET=""

log_info() {
  echo "[INFO] $1" >&2
}

log_error() {
  echo "[ERROR] $1" >&2
}

# Colors stay empty unless stderr is a terminal and NO_COLOR is unset, so every
# call site can interpolate them unconditionally.
init_colors() {
  if [[ -t 2 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    ANSI_GREEN=$'\033[32m'
    ANSI_RED=$'\033[31m'
    ANSI_RESET=$'\033[0m'
  fi
}

cleanup() {
  [[ -n "$WORK_DIR" ]] && [[ -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
}

check_dependencies() {
  local dep
  for dep in pwsh diff; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      log_error "Required dependency '$dep' not found."
      log_error "Both runners must be executable to compare them."
      exit 1
    fi
  done
}

# The mock provider is deterministic, so identical prompts must produce identical
# answers, and any difference is a real drift rather than model variation.
run_both() {
  local subject="$SCRIPT_DIR/council/smoke/subject.md"

  log_info "Running council.sh with $MEMBERS members against the mock provider"
  bash "$SCRIPT_DIR/council.sh" --smoke --members "$MEMBERS" --jobs 2 \
    --min-answer-chars 20 --subject-file "$subject" --out "$WORK_DIR/bash" \
    >"$WORK_DIR/bash.log" 2>&1 || {
    log_error "council.sh failed; see $WORK_DIR/bash.log"
    cat "$WORK_DIR/bash.log" >&2
    exit 1
  }

  log_info "Running council.ps1 with $MEMBERS members against the mock provider"
  pwsh -NoProfile -File "$SCRIPT_DIR/council.ps1" -Smoke -Members "$MEMBERS" -Jobs 2 \
    -MinAnswerChars 20 -SubjectFile "$subject" -Out "$WORK_DIR/pwsh" \
    >"$WORK_DIR/pwsh.log" 2>&1 || {
    log_error "council.ps1 failed; see $WORK_DIR/pwsh.log"
    cat "$WORK_DIR/pwsh.log" >&2
    exit 1
  }
}

compare_prompts() {
  local round prompt name passed=0 failed=0 seen=" "

  for round in round1 round2 round3 round4; do
    # Compare the union of both runners' prompts: a prompt composed by only one
    # side is drift even when every shared prompt matches.
    for prompt in "$WORK_DIR/bash/$round"/*.prompt.md "$WORK_DIR/pwsh/$round"/*.prompt.md; do
      [[ -e "$prompt" ]] || continue
      name="$round/$(basename "$prompt")"
      case " $seen " in *" $name "*) continue ;; esac
      seen="$seen$name "

      if [[ ! -f "$WORK_DIR/bash/$name" ]]; then
        echo "  $name... ${ANSI_RED}FAILED${ANSI_RESET} (council.sh produced no such prompt)"
        failed=$((failed + 1))
        continue
      fi
      if [[ ! -f "$WORK_DIR/pwsh/$name" ]]; then
        echo "  $name... ${ANSI_RED}FAILED${ANSI_RESET} (council.ps1 produced no such prompt)"
        failed=$((failed + 1))
        continue
      fi

      if diff -q "$WORK_DIR/bash/$name" "$WORK_DIR/pwsh/$name" >/dev/null 2>&1; then
        echo "  $name... ${ANSI_GREEN}PASSED${ANSI_RESET}"
        passed=$((passed + 1))
      else
        echo "  $name... ${ANSI_RED}FAILED${ANSI_RESET}"
        diff -u "$WORK_DIR/bash/$name" "$WORK_DIR/pwsh/$name" | head -20 | sed 's/^/    /' || true
        failed=$((failed + 1))
      fi
    done
  done

  # A runner that composed nothing would otherwise pass by having no prompts to
  # disagree about.
  if [[ "$passed" -eq 0 ]] && [[ "$failed" -eq 0 ]]; then
    log_error "No prompts were composed by either runner."
    exit 1
  fi

  echo
  echo "$passed passed, $failed failed (of $((passed + failed)))"
  [[ "$failed" -eq 0 ]]
}

main() {
  init_colors
  check_dependencies

  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/council-parity.XXXXXX")"
  trap cleanup EXIT

  run_both
  compare_prompts
}

main "$@"
