#!/bin/bash

# Runs a council of AI reviewers over a plan, a diff, or free text.
#
# Each member critiques the subject independently, then critiques the other
# members' critiques, then a chair synthesises a single ranked verdict. Members
# differ by model (round-robin) and by role brief, and are seated in adversarial
# pairs so that disagreement is engineered rather than hoped for.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSET_DIR="$SCRIPT_DIR/council"
KNOWN_PROVIDERS="lmstudio opencode_zen opencode opencode_go copilot"

MEMBER_COUNT="${COUNCIL_MEMBERS:-6}"
MODEL_SPECS="${COUNCIL_MODELS:-}"
CHAIR_SPEC="${COUNCIL_CHAIR:-}"
SUBJECT_FILE=""
SUBJECT_DIFF=""
SUBJECT_TEXT=""
SUBJECT_KIND=""
OUT_DIR="${COUNCIL_OUT:-}"
ROLE_FILTER=""
SKIP_CROSS=0
SKIP_CHAIR=0
JOBS="${COUNCIL_JOBS:-3}"
TIMEOUT_SECS="${COUNCIL_TIMEOUT:-900}"
MIN_MEMBERS=""
MIN_ANSWER_CHARS=200
MAX_PEER_CHARS=20000
DRY_RUN=0
SMOKE=0
PUNY_BIN_PATH="${PUNY_BIN:-}"
USE_CHAT_LOG=1
ISOLATE_HOME=1
KEEP_TEMP=0

COLOR_GREEN=""
COLOR_RED=""
COLOR_YELLOW=""
COLOR_RESET=""

log_info() {
  echo "[INFO] $1" >&2
}

log_success() {
  echo "${COLOR_GREEN}[OK]${COLOR_RESET} $1" >&2
}

log_warning() {
  echo "${COLOR_YELLOW}[WARN]${COLOR_RESET} $1" >&2
}

log_error() {
  echo "${COLOR_RED}[ERROR]${COLOR_RESET} $1" >&2
}

# Colors stay empty unless stderr is a terminal and NO_COLOR is unset, so every
# call site can interpolate them unconditionally.
init_colors() {
  if [[ -t 2 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    COLOR_GREEN=$'\033[32m'
    COLOR_RED=$'\033[31m'
    COLOR_YELLOW=$'\033[33m'
    COLOR_RESET=$'\033[0m'
  fi
}

show_usage() {
  cat <<'USAGE'
Usage: council.sh [options]

Runs a council of AI reviewers over a subject and writes a synthesised verdict.

Subject (exactly one is required):
  -f, --subject-file PATH   Critique the contents of a file
  -d, --diff BASE           Critique "git diff BASE...HEAD"
  -t, --subject TEXT        Critique the given text
      --kind KIND           plan | diff | text (default: inferred)

Council:
  -n, --members N           Number of council members (default: 6, maximum: 8)
  -m, --models LIST         Comma-separated models, each [provider:]model
  -c, --chair SPEC          Model that writes the final verdict (default: first)
      --roles LIST          Comma-separated role ids instead of the first N seats
      --no-cross            Skip round two (the cross-critique)
      --no-chair            Skip round three (the synthesis)

Execution:
  -j, --jobs N              Maximum members running at once (default: 3)
      --timeout SECONDS     Per-member time limit (default: 900)
      --min-members N       Abort after round one below this many (default: half)
      --min-answer-chars N  Shorter answers count as a failure (default: 200)
      --max-peer-chars N    Truncate each peer critique in round two (default: 20000)
      --bin PATH            Path to the puny binary
      --no-chat-log         Extract answers from stdout instead of puny_chat.log
      --no-isolate-home     Share the real puny config directory between members
      --keep-temp           Do not delete the per-member working directories

Output:
  -o, --out DIR             Output directory (default: .council/<timestamp>-<slug>)
      --dry-run             Compose every prompt but call no models
      --smoke               Self-test against the mock provider
  -h, --help                Show this help text

Environment: PUNY_BIN, COUNCIL_MEMBERS, COUNCIL_MODELS, COUNCIL_CHAIR,
COUNCIL_OUT, COUNCIL_JOBS, COUNCIL_TIMEOUT, NO_COLOR

Exit codes: 0 ok, 1 usage or preflight, 2 quorum not met, 3 chair failed
USAGE
}

die() {
  log_error "$1"
  exit "${2:-1}"
}

require_value() {
  # Guards against a flag silently swallowing the next flag as its value.
  if [[ -z "$2" ]] || [[ "$2" == -* ]]; then
    die "Option $1 requires a value"
  fi
}

require_positive_int() {
  if ! [[ "$2" =~ ^[0-9]+$ ]] || [[ "$2" -lt 1 ]]; then
    die "Option $1 requires a positive whole number, got '$2'"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -f | --subject-file)
      require_value "$1" "${2:-}"
      SUBJECT_FILE="$2"
      shift 2
      ;;
    -d | --diff)
      require_value "$1" "${2:-}"
      SUBJECT_DIFF="$2"
      shift 2
      ;;
    -t | --subject)
      require_value "$1" "${2:-}"
      SUBJECT_TEXT="$2"
      shift 2
      ;;
    --kind)
      require_value "$1" "${2:-}"
      SUBJECT_KIND="$2"
      shift 2
      ;;
    -n | --members)
      require_positive_int "$1" "${2:-}"
      MEMBER_COUNT="$2"
      shift 2
      ;;
    -m | --models)
      require_value "$1" "${2:-}"
      MODEL_SPECS="$2"
      shift 2
      ;;
    -c | --chair)
      require_value "$1" "${2:-}"
      CHAIR_SPEC="$2"
      shift 2
      ;;
    --roles)
      require_value "$1" "${2:-}"
      ROLE_FILTER="$2"
      shift 2
      ;;
    --no-cross)
      SKIP_CROSS=1
      shift
      ;;
    --no-chair)
      SKIP_CHAIR=1
      shift
      ;;
    -j | --jobs)
      require_positive_int "$1" "${2:-}"
      JOBS="$2"
      shift 2
      ;;
    --timeout)
      require_positive_int "$1" "${2:-}"
      TIMEOUT_SECS="$2"
      shift 2
      ;;
    --min-members)
      require_positive_int "$1" "${2:-}"
      MIN_MEMBERS="$2"
      shift 2
      ;;
    --min-answer-chars)
      require_positive_int "$1" "${2:-}"
      MIN_ANSWER_CHARS="$2"
      shift 2
      ;;
    --max-peer-chars)
      require_positive_int "$1" "${2:-}"
      MAX_PEER_CHARS="$2"
      shift 2
      ;;
    -o | --out)
      require_value "$1" "${2:-}"
      OUT_DIR="$2"
      shift 2
      ;;
    --bin)
      require_value "$1" "${2:-}"
      PUNY_BIN_PATH="$2"
      shift 2
      ;;
    --no-chat-log)
      USE_CHAT_LOG=0
      shift
      ;;
    --no-isolate-home)
      ISOLATE_HOME=0
      shift
      ;;
    --keep-temp)
      KEEP_TEMP=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --smoke)
      SMOKE=1
      shift
      ;;
    -h | --help)
      show_usage
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      show_usage >&2
      exit 1
      ;;
    esac
  done
}

check_dependencies() {
  local deps=("awk" "sed" "grep" "git")
  local dep

  for dep in "${deps[@]}"; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      die "Required dependency '$dep' not found. Please install it first."
    fi
  done

  # A missing 'timeout' is survivable; a hung member is not worth aborting over.
  if ! command -v timeout >/dev/null 2>&1; then
    log_warning "'timeout' not found; members will run without a time limit"
    TIMEOUT_SECS=0
  fi
}

# Splits "[provider:]model" into SPEC_PROVIDER and SPEC_MODEL. A leading token is
# treated as a provider only when it names one. A bare "foo:bar" is rejected so a
# typo cannot silently become a model id, while ids that legitimately contain a
# colon (qwen/qwen3-coder:free) pass through untouched.
SPEC_PROVIDER=""
SPEC_MODEL=""
split_spec() {
  local spec="$1"
  local head

  SPEC_PROVIDER=""
  SPEC_MODEL="$spec"

  if [[ "$spec" != *:* ]]; then
    return
  fi

  head="${spec%%:*}"
  case " $KNOWN_PROVIDERS " in
  *" $head "*)
    SPEC_PROVIDER="$head"
    SPEC_MODEL="${spec#*:}"
    return
    ;;
  esac

  if [[ "$head" != */* ]]; then
    die "Unknown provider '$head' in model spec '$spec' (known: $KNOWN_PROVIDERS)"
  fi
}

resolve_binary() {
  local candidate

  if [[ -n "$PUNY_BIN_PATH" ]]; then
    [[ -x "$PUNY_BIN_PATH" ]] || die "puny binary not executable: $PUNY_BIN_PATH"
    return
  fi

  for candidate in \
    "$SCRIPT_DIR/../zig-out/bin/puny" \
    "$SCRIPT_DIR/../zig-out/bin/puny.exe"; do
    if [[ -x "$candidate" ]]; then
      PUNY_BIN_PATH="$candidate"
      return
    fi
  done

  if command -v puny >/dev/null 2>&1; then
    PUNY_BIN_PATH="$(command -v puny)"
    return
  fi

  die "Could not find the puny binary. Build it with 'zig build' or pass --bin PATH."
}

validate_args() {
  local chosen=0

  [[ -n "$SUBJECT_FILE" ]] && chosen=$((chosen + 1))
  [[ -n "$SUBJECT_DIFF" ]] && chosen=$((chosen + 1))
  [[ -n "$SUBJECT_TEXT" ]] && chosen=$((chosen + 1))

  if [[ "$chosen" -eq 0 ]]; then
    log_error "No subject given. Pass one of --subject-file, --diff, or --subject."
    show_usage >&2
    exit 1
  fi

  if [[ "$chosen" -gt 1 ]]; then
    die "--subject-file, --diff, and --subject are mutually exclusive"
  fi

  if [[ -n "$SUBJECT_FILE" ]] && [[ ! -f "$SUBJECT_FILE" ]]; then
    die "Subject file not found: $SUBJECT_FILE"
  fi

  if [[ -n "$SUBJECT_KIND" ]]; then
    case "$SUBJECT_KIND" in
    plan | diff | text) ;;
    *) die "--kind must be plan, diff, or text (got '$SUBJECT_KIND')" ;;
    esac
  fi

  if [[ "$JOBS" -gt "$MEMBER_COUNT" ]]; then
    JOBS="$MEMBER_COUNT"
  fi

  if [[ -z "$MIN_MEMBERS" ]]; then
    MIN_MEMBERS=$(((MEMBER_COUNT + 1) / 2))
    [[ "$MIN_MEMBERS" -lt 2 ]] && MIN_MEMBERS=2
  fi

  if [[ "$MIN_MEMBERS" -gt "$MEMBER_COUNT" ]]; then
    die "--min-members ($MIN_MEMBERS) exceeds the member count ($MEMBER_COUNT)"
  fi
}

main() {
  init_colors
  parse_args "$@"
  check_dependencies
  validate_args
  resolve_binary
}

main "$@"
