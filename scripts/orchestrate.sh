#!/usr/bin/env bash
# orchestrate.sh — plan → implement → review loop for puny
# Usage: ./scripts/orchestrate.sh --prompt "Add feature" [--max-iterations 5] [--no-auto-commit]
#        ./scripts/orchestrate.sh --prompt-file spec.md
#
# Exit codes: 0 merge worthy, 1 not merge worthy after max iterations, 2 operational failure
set -euo pipefail

PUNY_BIN="${PUNY_BIN:-puny}"
MAX_ITERATIONS=5
AUTO_COMMIT=1
PROMPT=""
PROMPT_FILE=""
EXTRA_ARGS=()

usage() {
  cat <<'EOF'
Usage: orchestrate.sh [options]

Orchestrate an autonomous puny loop: implement → review → fix until merge worthy.

  --prompt <text>       Initial task prompt (mutually exclusive with --prompt-file)
  --prompt-file <path>  Load initial prompt from a file (10 MiB limit, as with puny)
  --max-iterations <n>  Max review→fix cycles (default: 5)
  --auto-commit         Auto-commit dirty worktree after each implement step (default: on)
  --no-auto-commit      Do not auto-commit; rely on the agent to commit
  --puny-bin <bin>      Puny binary to invoke (default: puny, or $PUNY_BIN)
  -h, --help            Show this help

Examples:
  ./scripts/orchestrate.sh --prompt "Add CSV export to the report command"
  ./scripts/orchestrate.sh --prompt-file spec.md --max-iterations 3
  ./scripts/orchestrate.sh --prompt "/plan Add CSV export"   # start with planning mode
  PUNY_BIN=./zig-out/bin/puny ./scripts/orchestrate.sh --prompt "Fix typo"

Notes:
  - Run from the repository root on a feature branch (not main, not detached HEAD).
  - The script commits dirty changes (excluding review-results.md) so that
    `puny --review` (which reviews merge-base..HEAD) can see them.
  - Review report is written to review-results.md each iteration.
  - Exit code mirrors puny --review: 0=merge worthy, 1=rejected, 2=operational failure.
EOF
}

die() {
  echo "error: $*" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt)
      [[ $# -lt 2 ]] && die "--prompt requires a value"
      PROMPT="$2"
      shift 2
      ;;
    --prompt-file)
      [[ $# -lt 2 ]] && die "--prompt-file requires a value"
      PROMPT_FILE="$2"
      shift 2
      ;;
    --max-iterations)
      [[ $# -lt 2 ]] && die "--max-iterations requires a value"
      MAX_ITERATIONS="$2"
      shift 2
      ;;
    --auto-commit)
      AUTO_COMMIT=1
      shift
      ;;
    --no-auto-commit)
      AUTO_COMMIT=0
      shift
      ;;
    --puny-bin)
      [[ $# -lt 2 ]] && die "--puny-bin requires a value"
      PUNY_BIN="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do EXTRA_ARGS+=("$1"); shift; done
      break
      ;;
    *)
      die "unknown argument: $1 (see --help)"
      ;;
  esac
done

if [[ -n "$PROMPT" && -n "$PROMPT_FILE" ]]; then
  die "cannot use both --prompt and --prompt-file"
fi
if [[ -z "$PROMPT" && -z "$PROMPT_FILE" ]]; then
  die "one of --prompt or --prompt-file is required (see --help)"
fi
if ! [[ "$MAX_ITERATIONS" =~ ^[0-9]+$ ]] || [[ "$MAX_ITERATIONS" -lt 1 ]]; then
  die "--max-iterations must be a positive integer"
fi
if ! command -v "$PUNY_BIN" >/dev/null 2>&1 && [[ ! -x "$PUNY_BIN" ]]; then
  die "puny binary not found: $PUNY_BIN (set --puny-bin or \$PUNY_BIN)"
fi

# Verify git repository and branch preconditions (mirrors puny --review checks).
if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  die "not a git repository"
fi
BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
if [[ -z "$BRANCH" ]]; then
  die "detached HEAD is not supported — checkout a feature branch"
fi
if [[ "$BRANCH" == "main" ]]; then
  die "orchestration cannot run on main — checkout a feature branch"
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
REPORT_PATH="$REPO_ROOT/review-results.md"

commit_if_dirty() {
  local msg="$1"
  # Exclude review-results.md from dirty check, matching puny's filter.
  local status
  status="$(git status --porcelain=v1 --untracked-files=all | grep -v " review-results.md" | grep -v "?? review-results.md" || true)"
  # Fallback: also filter exact path match generically.
  if [[ -n "$status" ]]; then
    # Re-filter more precisely: drop any line whose path is review-results.md
    status="$(echo "$status" | awk 'substr($0,4) != "review-results.md"' || true)"
  fi
  if [[ -z "${status//[[:space:]]/}" ]]; then
    echo "[orchestrate] worktree clean — nothing to commit"
    return 0
  fi
  echo "[orchestrate] committing dirty worktree..."
  echo "$status" | sed 's/^/  /'
  # Stage everything except review-results.md (which puny treats as generated
  # and is gitignored in the main repo). Use pathspec exclusion when supported
  # and fall back to add-all + reset.
  if git add -A -- ':!review-results.md' 2>/dev/null; then
    :
  else
    git add -A
    git reset -q HEAD -- review-results.md 2>/dev/null || true
  fi
  # Allow empty commit message failure to surface.
  git commit -m "$msg" || die "git commit failed"
}

run_puny_implement() {
  local prompt_args=()
  if [[ -n "$PROMPT_FILE" ]]; then
    prompt_args=(--prompt-file "$PROMPT_FILE")
  else
    prompt_args=(--prompt "$PROMPT")
  fi
  echo "[orchestrate] running: $PUNY_BIN ${prompt_args[*]} --oneshot ${EXTRA_ARGS[*]:-}"
  # shellcheck disable=SC2086
  "$PUNY_BIN" "${prompt_args[@]}" --oneshot "${EXTRA_ARGS[@]}"
}

run_puny_fix() {
  local report="$REPORT_PATH"
  local fix_prompt
  # Keep prompt small by referencing the report file; agent can read it with read_file.
  fix_prompt="Review found issues (see review-results.md). Read $report with read_file and fix every finding, then ensure existing tests still pass. Do not edit review-results.md. Work only on source files."
  echo "[orchestrate] running fix: $PUNY_BIN --prompt <fix> --oneshot"
  "$PUNY_BIN" --prompt "$fix_prompt" --oneshot "${EXTRA_ARGS[@]}"
}

run_review() {
  echo "[orchestrate] running: $PUNY_BIN --review ${EXTRA_ARGS[*]:-}"
  # shellcheck disable=SC2086
  "$PUNY_BIN" --review "${EXTRA_ARGS[@]}"
}

echo "[orchestrate] branch: $BRANCH"
echo "[orchestrate] repo:   $REPO_ROOT"
echo "[orchestrate] max iterations: $MAX_ITERATIONS"
echo "[orchestrate] auto-commit:    $([ "$AUTO_COMMIT" -eq 1 ] && echo yes || echo no)"

# Phase 1: initial implement (plan → implement). If the prompt starts with /plan,
# puny will enter planning mode and attempt to save plan.md in one turn.
run_puny_implement
commit_status=0
if [[ "$AUTO_COMMIT" -eq 1 ]]; then
  commit_if_dirty "puny orchestrate: implement initial prompt" || commit_status=$?
  if [[ $commit_status -ne 0 ]]; then
    exit 2
  fi
fi

# Phase 2: review → fix loop
iteration=1
while [[ $iteration -le $MAX_ITERATIONS ]]; do
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "[orchestrate] review iteration $iteration/$MAX_ITERATIONS"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  set +e
  run_review
  ec=$?
  set -e

  if [[ $ec -eq 0 ]]; then
    echo ""
    echo "[orchestrate] ✓ MERGE WORTHY — report: $REPORT_PATH"
    cat "$REPORT_PATH" 2>/dev/null | tail -n 20 || true
    exit 0
  elif [[ $ec -eq 1 ]]; then
    echo "[orchestrate] ✗ not merge worthy (exit 1) — report: $REPORT_PATH"
    if [[ ! -f "$REPORT_PATH" ]]; then
      echo "[orchestrate] missing report; treating as operational failure" >&2
      exit 2
    fi
    echo "---- review findings (tail) ----"
    tail -n 60 "$REPORT_PATH" || true
    echo "--------------------------------"
    if [[ $iteration -eq $MAX_ITERATIONS ]]; then
      echo "[orchestrate] max iterations ($MAX_ITERATIONS) reached — branch still not merge worthy" >&2
      exit 1
    fi
    echo "[orchestrate] applying fixes for iteration $iteration..."
    run_puny_fix
    if [[ "$AUTO_COMMIT" -eq 1 ]]; then
      commit_if_dirty "puny orchestrate: fix review findings (iteration $iteration)" || exit 2
    fi
  elif [[ $ec -eq 2 ]]; then
    echo "[orchestrate] ! operational failure (exit 2) — report: $REPORT_PATH" >&2
    if [[ -f "$REPORT_PATH" ]]; then
      echo "---- fallback report ----"
      cat "$REPORT_PATH" || true
      echo "-------------------------"
    fi
    exit 2
  else
    echo "[orchestrate] ! unexpected exit code $ec from puny --review" >&2
    exit 2
  fi

  iteration=$((iteration + 1))
done

echo "[orchestrate] loop exhausted — not merge worthy after $MAX_ITERATIONS iterations" >&2
exit 1
