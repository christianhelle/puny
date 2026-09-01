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
PLAN_PROMPT=""
PLAN_FILE=""
EXTRA_ARGS=()

usage() {
  cat <<'EOF'
Usage: orchestrate.sh [options]

Orchestrate an autonomous puny loop: implement → review → fix until merge worthy.

  --prompt <text>       Initial task prompt (mutually exclusive with --prompt-file)
  --prompt-file <path>  Load initial prompt from a file (10 MiB limit, as with puny)
  --plan <text>         Run an interactive planning phase before implement (mutually exclusive with --plan-file)
  --plan-file <path>    Run an interactive planning phase from a file
  --max-iterations <n>  Max review→fix cycles (default: 5)
  --auto-commit         Auto-commit dirty worktree after each implement step (default: on)
  --no-auto-commit      Do not auto-commit; rely on the agent to commit
  --puny-bin <bin>      Puny binary to invoke (default: puny, or $PUNY_BIN)
  -h, --help            Show this help

Examples:
  ./scripts/orchestrate.sh --prompt "Add CSV export to the report command"
  ./scripts/orchestrate.sh --prompt-file spec.md --max-iterations 3
  ./scripts/orchestrate.sh --plan "Add CSV export with PRD" --prompt "Implement the PRD at ./prd.md"
  ./scripts/orchestrate.sh --plan-file spec.md
  PUNY_BIN=./zig-out/bin/puny ./scripts/orchestrate.sh --prompt "Fix typo" --no-auto-commit

Notes:
  - Run from the repository root on a feature branch (not main, not detached HEAD).
  - The script commits dirty changes (excluding review-results.md) so that
    `puny --review` (which reviews merge-base..HEAD) can see them.
  - Review report is written to review-results.md each iteration.
  - Exit code mirrors puny --review: 0=merge worthy, 1=rejected, 2=operational failure.
  - Planning mode is interactive and cannot be used with --prompt "/plan ..." + --oneshot.
    The orchestrate planning phase runs `puny --prompt "/plan ..."` without --oneshot,
    waits until you exit puny (/quit), then copies the generated plan.md from the
    session store to ./prd.md in the repo. The next implement step can then use
    --prompt-file ./prd.md or your original --prompt.
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
    --plan)
      [[ $# -lt 2 ]] && die "--plan requires a value"
      PLAN_PROMPT="$2"
      shift 2
      ;;
    --plan-file)
      [[ $# -lt 2 ]] && die "--plan-file requires a value"
      PLAN_FILE="$2"
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
if [[ -n "$PLAN_PROMPT" && -n "$PLAN_FILE" ]]; then
  die "cannot use both --plan and --plan-file"
fi
if [[ -z "$PROMPT" && -z "$PROMPT_FILE" && -z "$PLAN_PROMPT" && -z "$PLAN_FILE" ]]; then
  die "one of --prompt, --prompt-file, --plan, or --plan-file is required (see --help)"
fi
if ! [[ "$MAX_ITERATIONS" =~ ^[0-9]+$ ]] || [[ "$MAX_ITERATIONS" -lt 1 ]]; then
  die "--max-iterations must be a positive integer"
fi
if ! command -v "$PUNY_BIN" >/dev/null 2>&1 && [[ ! -x "$PUNY_BIN" ]]; then
  die "puny binary not found: $PUNY_BIN (set --puny-bin or \$PUNY_BIN)"
fi

# Planning mode is interactive and cannot be used with --oneshot. Warn if the user
# tries to use --prompt "/plan ..." which would exit after the first question.
if [[ "$PROMPT" == "/plan"* || "$PROMPT" == "/Plan"* || "$PROMPT" == "/PLAN"* ]]; then
  echo "warning: --prompt \"/plan ...\" with --oneshot will exit after the first planning question." >&2
  echo "         Use --plan \"task\" for an interactive planning session that waits for the PRD to be saved." >&2
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
  # and fall back to add-all + reset. Always reset review-results.md to handle
  # the case where it was already staged before this invocation.
  git add -A -- ':!review-results.md' 2>/dev/null || git add -A
  git reset -q HEAD -- review-results.md 2>/dev/null || true
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
  set +e
  "$PUNY_BIN" "${prompt_args[@]}" --oneshot "${EXTRA_ARGS[@]}"
  local ec=$?
  set -e
  if [[ $ec -ne 0 ]]; then
    echo "error: puny implement step failed with exit code $ec" >&2
    exit 2
  fi
}

run_puny_fix() {
  local report="$REPORT_PATH"
  local fix_prompt
  # Keep prompt small by referencing the report file; agent can read it with read_file.
  fix_prompt="Review found issues (see review-results.md). Read $report with read_file and fix every finding, then ensure existing tests still pass. Do not edit review-results.md. Work only on source files."
  echo "[orchestrate] running fix: $PUNY_BIN --prompt <fix> --oneshot"
  set +e
  "$PUNY_BIN" --prompt "$fix_prompt" --oneshot "${EXTRA_ARGS[@]}"
  local ec=$?
  set -e
  if [[ $ec -ne 0 ]]; then
    echo "error: puny fix step failed with exit code $ec" >&2
    exit 2
  fi
}

run_review() {
  echo "[orchestrate] running: $PUNY_BIN --review ${EXTRA_ARGS[*]:-}"
  # shellcheck disable=SC2086
  "$PUNY_BIN" --review "${EXTRA_ARGS[@]}"
}

puny_session_base() {
  if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
    echo "$XDG_CONFIG_HOME/puny/sessions"
  elif [[ -n "${APPDATA:-}" ]]; then
    echo "$APPDATA/puny/sessions"
  else
    echo "$HOME/.config/puny/sessions"
  fi
}

find_latest_plan() {
  local base
  base="$(puny_session_base)"
  # Convert Windows path to Unix if needed (Git Bash / WSL)
  if command -v cygpath >/dev/null 2>&1; then
    base="$(cygpath -u "$base" 2>/dev/null || echo "$base")"
  elif [[ "$base" == *":"* ]]; then
    base="$(echo "$base" | sed -E 's/^([A-Za-z]):/\/mnt\/\L\1/' | tr '\\' '/')"
  fi
  # Fallback to USERPROFILE on Windows if base does not exist
  if [[ ! -d "$base" && -n "${USERPROFILE:-}" ]]; then
    local alt="$USERPROFILE/puny/sessions"
    if command -v cygpath >/dev/null 2>&1; then
      alt="$(cygpath -u "$alt" 2>/dev/null || echo "$alt")"
    elif [[ "$alt" == *":"* ]]; then
      alt="$(echo "$alt" | sed -E 's/^([A-Za-z]):/\/mnt\/\L\1/' | tr '\\' '/')"
    fi
    if [[ -d "$alt" ]]; then
      base="$alt"
    fi
  fi
  # Also try HOME/.config fallback
  if [[ ! -d "$base" ]]; then
    local fallback="$HOME/.config/puny/sessions"
    if [[ -d "$fallback" ]]; then
      base="$fallback"
    fi
  fi
  if [[ -d "$base" ]]; then
    local latest=""
    local latest_time=0
    local start_time="${PLANNING_START_TIME:-0}"
    # Portable null-delimited traversal; compare mtimes with stat (GNU/BSD)
    while IFS= read -r -d '' file; do
      local mtime
      if stat -c "%Y" "$file" >/dev/null 2>&1; then
        mtime=$(stat -c "%Y" "$file")
      else
        mtime=$(stat -f "%m" "$file" 2>/dev/null || echo 0)
      fi
      # Skip stale plans that predate the planning start
      if (( mtime < start_time )); then
        continue
      fi
      if (( mtime > latest_time )); then
        latest_time=$mtime
        latest="$file"
      fi
    done < <(find "$base" -name "plan.md" -type f -print0 2>/dev/null)
    echo "$latest"
  fi
}

run_planning_phase() {
  echo "[orchestrate] Starting interactive planning phase..."
  echo "[orchestrate] Puny will run without --oneshot. Answer the planning questions."
  echo "[orchestrate] When the PRD is saved, exit puny (/quit or Ctrl+C) to continue to implement."
  echo "[orchestrate] The generated PRD will be copied to $REPO_ROOT/prd.md"
  local plan_input=""
  if [[ -n "$PLAN_FILE" ]]; then
    if [[ ! -f "$PLAN_FILE" ]]; then
      die "plan file not found: $PLAN_FILE"
    fi
    plan_input="$(cat "$PLAN_FILE")"
  else
    plan_input="$PLAN_PROMPT"
  fi
  # Record start time to avoid picking up stale plans from previous sessions
  PLANNING_START_TIME=$(date +%s)
  # Run puny in planning mode without --oneshot, wait indefinitely until exit
  # shellcheck disable=SC2086
  set +e
  "$PUNY_BIN" --prompt "/plan $plan_input" "${EXTRA_ARGS[@]}"
  local ec=$?
  set -e
  if [[ $ec -ne 0 ]]; then
    echo "[orchestrate] planning puny exited with code $ec (continuing to look for PRD)" >&2
  fi
  local latest_plan
  latest_plan="$(find_latest_plan)"
  if [[ -z "$latest_plan" || ! -f "$latest_plan" ]]; then
    echo "[orchestrate] warning: no plan.md found in session store after planning." >&2
    echo "[orchestrate] Checked: $(puny_session_base) (and fallbacks)" >&2
    echo "[orchestrate] You can manually copy the PRD to $REPO_ROOT/prd.md and continue." >&2
    return 1
  fi
  echo "[orchestrate] Found plan: $latest_plan"
  cp "$latest_plan" "$REPO_ROOT/prd.md"
  echo "[orchestrate] Copied PRD to $REPO_ROOT/prd.md"
  local latest_html="${latest_plan%.md}.html"
  if [[ -f "$latest_html" ]]; then
    cp "$latest_html" "$REPO_ROOT/prd.html"
    echo "[orchestrate] Copied HTML to $REPO_ROOT/prd.html"
  fi
  if [[ -z "$PROMPT" && -z "$PROMPT_FILE" ]]; then
    PROMPT_FILE="$REPO_ROOT/prd.md"
    echo "[orchestrate] Using generated prd.md for implement phase"
  fi
  return 0
}

echo "[orchestrate] branch: $BRANCH"
echo "[orchestrate] repo:   $REPO_ROOT"
echo "[orchestrate] max iterations: $MAX_ITERATIONS"
echo "[orchestrate] auto-commit:    $([ "$AUTO_COMMIT" -eq 1 ] && echo yes || echo no)"
if [[ -n "$PLAN_PROMPT" || -n "$PLAN_FILE" ]]; then
  echo "[orchestrate] planning requested: $([ -n "$PLAN_FILE" ] && echo "$PLAN_FILE" || echo "$PLAN_PROMPT")"
fi

# Phase 0: interactive planning (optional, runs without --oneshot and waits)
# Planning mode uses an interactive interview and cannot be used with --oneshot.
# This phase runs `puny --prompt "/plan ..."` without --oneshot, waits indefinitely
# until you exit puny, then copies the generated plan.md from the session store
# to $REPO_ROOT/prd.md for the implement step.
if [[ -n "$PLAN_PROMPT" || -n "$PLAN_FILE" ]]; then
  run_planning_phase || echo "[orchestrate] planning phase did not produce a PRD, continuing..." >&2
  if [[ -z "$PROMPT" && -z "$PROMPT_FILE" ]]; then
    if [[ ! -f "$REPO_ROOT/prd.md" ]]; then
      die "no implement prompt available and no prd.md was generated (provide --prompt/--prompt-file or ensure planning saved a PRD)"
    fi
  fi
fi

# Validate we have an implement prompt (either original or generated from planning)
if [[ -z "$PROMPT" && -z "$PROMPT_FILE" ]]; then
  die "no implement prompt available (provide --prompt/--prompt-file or use --plan to generate prd.md)"
fi

# Phase 1: initial implement
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
