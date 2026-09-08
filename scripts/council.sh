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

ROLE_DIR=""
PROMPT_DIR=""
declare -a ROLE_ID=()
declare -a ROLE_NAME=()
declare -a ROLE_FILE=()

# Loads the role briefs into parallel arrays, in seat order. Smoke runs use a
# separate, keyword-safe set because the real briefs contain words the mock
# provider treats as tool-call triggers.
load_roles() {
  local file base id name
  local -a wanted=()
  local want found i

  ROLE_DIR="$ASSET_DIR/roles"
  PROMPT_DIR="$ASSET_DIR/prompts"
  if [[ "$SMOKE" -eq 1 ]]; then
    ROLE_DIR="$ASSET_DIR/smoke/roles"
    PROMPT_DIR="$ASSET_DIR/smoke/prompts"
  fi

  [[ -d "$ROLE_DIR" ]] || die "Role directory not found: $ROLE_DIR"
  [[ -d "$PROMPT_DIR" ]] || die "Prompt directory not found: $PROMPT_DIR"

  local -a all_id=() all_name=() all_file=()
  for file in "$ROLE_DIR"/[0-9][0-9]-*.md; do
    [[ -f "$file" ]] || continue
    base="$(basename "$file" .md)"
    id="${base#[0-9][0-9]-}"
    name="$(head -1 "$file" | sed -e 's/^#[[:space:]]*//')"
    [[ -n "$name" ]] || name="$id"
    all_id+=("$id")
    all_name+=("$name")
    all_file+=("$file")
  done

  [[ "${#all_id[@]}" -gt 0 ]] || die "No role briefs found in $ROLE_DIR"

  if [[ -n "$ROLE_FILTER" ]]; then
    IFS=',' read -r -a wanted <<<"$ROLE_FILTER"
    for want in "${wanted[@]}"; do
      want="$(echo "$want" | tr -d '[:space:]')"
      [[ -n "$want" ]] || continue
      found=0
      for i in "${!all_id[@]}"; do
        if [[ "${all_id[$i]}" == "$want" ]]; then
          ROLE_ID+=("${all_id[$i]}")
          ROLE_NAME+=("${all_name[$i]}")
          ROLE_FILE+=("${all_file[$i]}")
          found=1
          break
        fi
      done
      [[ "$found" -eq 1 ]] || die "Unknown role '$want'. Available: ${all_id[*]}"
    done
    MEMBER_COUNT="${#ROLE_ID[@]}"
    [[ "$MEMBER_COUNT" -gt 0 ]] || die "--roles selected no roles"
  else
    if [[ "$MEMBER_COUNT" -gt "${#all_id[@]}" ]]; then
      die "Only ${#all_id[@]} role briefs exist in $ROLE_DIR, cannot seat $MEMBER_COUNT members"
    fi
    for ((i = 0; i < MEMBER_COUNT; i++)); do
      ROLE_ID+=("${all_id[$i]}")
      ROLE_NAME+=("${all_name[$i]}")
      ROLE_FILE+=("${all_file[$i]}")
    done
  fi

  if [[ $((MEMBER_COUNT % 2)) -ne 0 ]]; then
    log_warning "Member count $MEMBER_COUNT is odd, so one seat has no adversarial opposite"
  fi
}

declare -a MEMBER_PROVIDER=()
declare -a MEMBER_MODEL=()
declare -a MEMBER_PAIR=()
declare -a MEMBER_SLUG=()
CHAIR_PROVIDER=""
CHAIR_MODEL=""

# Assigns models round-robin across seats and pairs seat i with seat i XOR 1.
seat_members() {
  local -a specs=()
  local i pair spec

  if [[ "$SMOKE" -eq 1 ]]; then
    specs=("mock")
  elif [[ -n "$MODEL_SPECS" ]]; then
    IFS=',' read -r -a specs <<<"$MODEL_SPECS"
  else
    specs=("")
    log_info "No --models given; every member uses the model from your puny config"
  fi

  for i in "${!specs[@]}"; do
    specs[$i]="$(echo "${specs[$i]}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  done

  if [[ "$SMOKE" -eq 0 ]]; then
    if [[ "${#specs[@]}" -eq 1 ]] && [[ -n "${specs[0]}" ]]; then
      log_warning "Only one model given; members will differ by role brief alone"
    elif [[ $((${#specs[@]} % 2)) -ne 0 ]] && [[ "${#specs[@]}" -gt 1 ]]; then
      log_warning "An odd number of models means some adversarial pairs share a model"
    fi
  fi

  for ((i = 0; i < MEMBER_COUNT; i++)); do
    spec="${specs[$((i % ${#specs[@]}))]}"
    if [[ "$SMOKE" -eq 1 ]]; then
      SPEC_PROVIDER=""
      SPEC_MODEL=""
    else
      split_spec "$spec"
    fi
    MEMBER_PROVIDER+=("$SPEC_PROVIDER")
    MEMBER_MODEL+=("$SPEC_MODEL")
    MEMBER_SLUG+=("$(printf '%02d-%s' "$i" "${ROLE_ID[$i]}")")

    pair=$((i ^ 1))
    if [[ "$pair" -lt "$MEMBER_COUNT" ]]; then
      MEMBER_PAIR+=("$pair")
    else
      MEMBER_PAIR+=("-1")
    fi
  done

  if [[ "$SMOKE" -eq 1 ]]; then
    CHAIR_PROVIDER=""
    CHAIR_MODEL=""
  elif [[ -n "$CHAIR_SPEC" ]]; then
    split_spec "$CHAIR_SPEC"
    CHAIR_PROVIDER="$SPEC_PROVIDER"
    CHAIR_MODEL="$SPEC_MODEL"
  else
    CHAIR_PROVIDER="${MEMBER_PROVIDER[0]}"
    CHAIR_MODEL="${MEMBER_MODEL[0]}"
  fi
}

SUBJECT_PATH=""
SUBJECT_LABEL=""

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]\+/-/g' -e 's/^-//' -e 's/-$//' | cut -c1-40
}

init_out_dir() {
  local stamp slug
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"

  if [[ -z "$OUT_DIR" ]]; then
    if [[ -n "$SUBJECT_FILE" ]]; then
      slug="$(slugify "$(basename "$SUBJECT_FILE" .md)")"
    elif [[ -n "$SUBJECT_DIFF" ]]; then
      slug="$(slugify "diff-$SUBJECT_DIFF")"
    else
      slug="text"
    fi
    [[ -n "$slug" ]] || slug="subject"
    OUT_DIR=".council/${stamp}-${slug}"
  fi

  mkdir -p "$OUT_DIR/round1" "$OUT_DIR/round2" "$OUT_DIR/round3"
}

# Writes the exact bytes every member will see into <out>/subject.md.
resolve_subject() {
  local bytes

  SUBJECT_PATH="$OUT_DIR/subject.md"

  if [[ -n "$SUBJECT_FILE" ]]; then
    cat "$SUBJECT_FILE" >"$SUBJECT_PATH"
    SUBJECT_LABEL="file $SUBJECT_FILE"
    [[ -n "$SUBJECT_KIND" ]] || {
      case "$SUBJECT_FILE" in
      *.md | *.markdown) SUBJECT_KIND="plan" ;;
      *.diff | *.patch) SUBJECT_KIND="diff" ;;
      *) SUBJECT_KIND="text" ;;
      esac
    }
  elif [[ -n "$SUBJECT_DIFF" ]]; then
    git rev-parse --git-dir >/dev/null 2>&1 || die "--diff needs to run inside a git repository"
    git rev-parse --verify "$SUBJECT_DIFF" >/dev/null 2>&1 ||
      die "--diff base '$SUBJECT_DIFF' is not a valid revision"
    {
      echo "Summary of the change:"
      echo
      git diff --stat "$SUBJECT_DIFF...HEAD"
      echo
      echo "Full diff:"
      echo
      git diff "$SUBJECT_DIFF...HEAD"
    } >"$SUBJECT_PATH"
    SUBJECT_LABEL="git diff $SUBJECT_DIFF...HEAD"
    SUBJECT_KIND="diff"
  else
    printf '%s\n' "$SUBJECT_TEXT" >"$SUBJECT_PATH"
    SUBJECT_LABEL="inline text"
    [[ -n "$SUBJECT_KIND" ]] || SUBJECT_KIND="text"
  fi

  bytes="$(wc -c <"$SUBJECT_PATH" | tr -d '[:space:]')"
  [[ "$bytes" -gt 0 ]] || die "The subject is empty"
  if [[ "$bytes" -gt 204800 ]]; then
    log_warning "Subject is ${bytes} bytes; large subjects can exceed a model's context window"
  fi
  log_info "Subject: $SUBJECT_LABEL (${bytes} bytes, kind: $SUBJECT_KIND)"
}

# Replaces whole-line block markers in a single pass, so that text pulled in by
# one marker is never rescanned for another. Inserted content is untrusted model
# output, and a second pass over it would let it expand markers of its own.
splice_all() {
  local template="$1" out="$2"
  local m1="${3:-}" f1="${4:-}" m2="${5:-}" f2="${6:-}"
  local m3="${7:-}" f3="${8:-}" m4="${9:-}" f4="${10:-}"

  awk -v m1="$m1" -v f1="$f1" -v m2="$m2" -v f2="$f2" \
    -v m3="$m3" -v f3="$f3" -v m4="$m4" -v f4="$f4" '
    function emit(f,   line) { while ((getline line < f) > 0) print line; close(f) }
    {
      if (m1 != "" && $0 == m1) { emit(f1); next }
      if (m2 != "" && $0 == m2) { emit(f2); next }
      if (m3 != "" && $0 == m3) { emit(f3); next }
      if (m4 != "" && $0 == m4) { emit(f4); next }
      print
    }
  ' "$template" >"$out"
}

# Substitutes the short scalar markers, then checks that nothing but the known
# block markers is left. This runs on the template only, before any subject or
# peer text is spliced in, so a subject that happens to contain "{{SUBJECT}}"
# cannot trip the check.
render_scalars() {
  local template="$1" out="$2" member_n="$3" role_name="$4" pair_name="$5" n_members="$6"
  local leftover

  sed \
    -e "s|{{MEMBER_N}}|${member_n}|g" \
    -e "s|{{ROLE_NAME}}|${role_name}|g" \
    -e "s|{{PAIR_NAME}}|${pair_name}|g" \
    -e "s|{{N_MEMBERS}}|${n_members}|g" \
    "$template" >"$out"

  leftover="$(grep -o '{{[A-Z_0-9]*}}' "$out" | sort -u |
    grep -vxE '\{\{(ROLE_BRIEF|SUBJECT|OWN_ROUND1|PEER_CRITIQUES|ALL_ROUND1|ALL_ROUND2)\}\}' || true)"

  if [[ -n "$leftover" ]]; then
    die "Unsubstituted marker(s) in $(basename "$template"): $(echo "$leftover" | tr '\n' ' ')"
  fi
}

# The mock provider dispatches tool calls and faults on whole-word matches in the
# last user message, so a mock run whose prompt contains one of these silently
# returns something other than a critique. Refuse rather than debug it later.
MOCK_TRIGGER_WORDS="long fast slow echo empty partial usage error timeout fail read search shell review table markdown reasoning"
guard_mock_keywords() {
  local file="$1" word hits=""

  for word in $MOCK_TRIGGER_WORDS; do
    if grep -qiwE "$word" "$file"; then
      hits="$hits $word"
    fi
  done

  if [[ -n "$hits" ]]; then
    die "Mock trigger word(s) in $(basename "$file"):$hits -- fix the smoke fixtures"
  fi
}

compose_round1_prompt() {
  local index="$1" out="$2"
  local template scratch pair_name

  template="$PROMPT_DIR/round1-${SUBJECT_KIND}.md"
  [[ -f "$template" ]] || template="$PROMPT_DIR/round1.md"
  [[ -f "$template" ]] || die "No round-one template for kind '$SUBJECT_KIND' in $PROMPT_DIR"

  pair_name="none"
  if [[ "${MEMBER_PAIR[$index]}" -ge 0 ]]; then
    pair_name="${ROLE_NAME[${MEMBER_PAIR[$index]}]}"
  fi

  scratch="${out}.scalars"
  render_scalars "$template" "$scratch" \
    "$(printf '%02d' "$index")" "${ROLE_NAME[$index]}" "$pair_name" "$MEMBER_COUNT"
  splice_all "$scratch" "$out" \
    "{{ROLE_BRIEF}}" "${ROLE_FILE[$index]}" \
    "{{SUBJECT}}" "$SUBJECT_PATH"
  rm -f "$scratch"

  [[ "$SMOKE" -eq 1 ]] && guard_mock_keywords "$out"
  return 0
}

main() {
  init_colors
  parse_args "$@"
  check_dependencies
  validate_args
  resolve_binary
  load_roles
  seat_members
  init_out_dir
  resolve_subject

  local i
  for ((i = 0; i < MEMBER_COUNT; i++)); do
    compose_round1_prompt "$i" "$OUT_DIR/round1/${MEMBER_SLUG[$i]}.prompt.md"
  done
  log_success "Composed $MEMBER_COUNT round-one prompts in $OUT_DIR/round1"
}

main "$@"
