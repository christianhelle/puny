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

TEMP_ROOT=""
SEED_CONFIG=""

cleanup() {
  if [[ -n "$TEMP_ROOT" ]] && [[ -d "$TEMP_ROOT" ]] && [[ "$KEEP_TEMP" -eq 0 ]]; then
    rm -rf "$TEMP_ROOT"
  fi
}

# puny is a native binary, so paths handed to it as arguments or environment
# values must be in the host's own form, not the shell's.
to_native() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    echo "$1"
  fi
}

# Finds the real config.json so each member's isolated config directory can be
# seeded with it. Without a seed, puny treats a missing config as a first run and
# starts an interactive setup that would hang with no terminal attached.
find_seed_config() {
  local candidate

  for candidate in \
    "${XDG_CONFIG_HOME:-}/puny/config.json" \
    "${APPDATA:-}/puny/config.json" \
    "$HOME/.config/puny/config.json"; do
    case "$candidate" in
    /puny/config.json) continue ;;
    esac
    if [[ -f "$candidate" ]]; then
      SEED_CONFIG="$candidate"
      return
    fi
  done

  if [[ "$ISOLATE_HOME" -eq 1 ]]; then
    log_warning "No puny config.json found; sharing the real config directory instead of isolating"
    log_warning "Members may race on the session index, and your session history will grow"
    ISOLATE_HOME=0
  fi
}

now_ms() {
  local raw
  raw="$(date -u +%s%3N 2>/dev/null || true)"
  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    echo "$raw"
  else
    echo "$(($(date -u +%s) * 1000))"
  fi
}

strip_ansi() {
  # puny emits only SGR and simple cursor sequences, all CSI with an alphabetic
  # final byte, so a narrow pattern is safer here than a maximal one.
  sed -e $'s/\033\\[[0-9;?]*[a-zA-Z]//g' -e 's/\r//g' "$1"
}

# The chat log holds the model's raw markdown. Stdout does not: puny renders
# markdown to the terminal before printing it, so bold, headings and tables are
# destroyed and every line is hard-wrapped at 80 columns when piped.
extract_from_chat_log() {
  local log="$1"

  [[ -s "$log" ]] || return 1

  awk '
    /^\[(USER|ASSISTANT|REASONING|TOOL_CALL|TOOL_RESULT)\]$/ {
      if ($0 == "[ASSISTANT]") { buf = ""; capture = 1 } else { capture = 0 }
      next
    }
    capture { buf = buf $0 "\n" }
    END { printf "%s", buf }
  ' "$log"
}

# Degraded fallback. Slices between the last thinking indicator and whichever
# trailer appears first; the token footer is absent when a turn fails, so several
# end anchors are needed.
extract_from_stdout() {
  local raw="$1"

  strip_ansi "$raw" | awk '
    /^Thinking\.\.\.$/           { buf = ""; capture = 1; next }
    /^Thought for /              { capture = 0; next }
    /^⏱ tokens: /                { capture = 0; next }
    /^─── Session: /             { capture = 0 }
    /^Goodbye\.$/                { capture = 0 }
    capture && /^🔧 /            { next }
    capture && /^Skill: /        { next }
    capture                      { buf = buf $0 "\n" }
    END { printf "%s", buf }
  '
}

trim_blank_edges() {
  awk 'BEGIN { started = 0 }
    { lines[NR] = $0; if ($0 ~ /[^[:space:]]/) { if (!started) { first = NR; started = 1 } last = NR } }
    END { if (started) for (i = first; i <= last; i++) print lines[i] }' "$1"
}

# Runs one member and writes <dest>/<slug>.md plus its raw logs and a status
# line. Never exits the script: a member that fails is recorded and skipped.
run_one() {
  local slug="$1" provider="$2" model="$3" prompt="$4" dest="$5"
  local work home status="ok" code=0 started ended answer_bytes
  local -a cmd=()

  work="$TEMP_ROOT/$slug"
  mkdir -p "$work"

  started="$(now_ms)"

  if [[ "$TIMEOUT_SECS" -gt 0 ]]; then
    cmd+=(timeout -s TERM -k 10 "$TIMEOUT_SECS")
  fi
  cmd+=(env)
  if [[ "$ISOLATE_HOME" -eq 1 ]]; then
    home="$work/home"
    mkdir -p "$home/puny"
    cp "$SEED_CONFIG" "$home/puny/config.json"
    cmd+=("XDG_CONFIG_HOME=$(to_native "$home")" "APPDATA=$(to_native "$home")")
  fi
  cmd+=("$PUNY_BIN_PATH" --oneshot --no-skills --prompt-file "$(to_native "$prompt")")
  [[ "$USE_CHAT_LOG" -eq 1 ]] && cmd+=(--chat-log)
  [[ "$SMOKE" -eq 1 ]] && cmd+=(--mock)
  [[ -n "$provider" ]] && cmd+=(--provider "$provider")
  [[ -n "$model" ]] && cmd+=(-m "$model")

  set +e
  (cd "$work" && "${cmd[@]}") >"$dest/$slug.stdout.log" 2>"$dest/$slug.stderr.log"
  code=$?
  set -e

  ended="$(now_ms)"

  if [[ "$code" -eq 124 ]] || [[ "$code" -eq 137 ]]; then
    status="timeout"
  elif [[ "$code" -ne 0 ]]; then
    status="exit:$code"
  fi

  if [[ -f "$work/puny_chat.log" ]]; then
    cp "$work/puny_chat.log" "$dest/$slug.chat.log"
  fi

  # An exit code of 0 does not mean the turn produced anything: a plain one-shot
  # run always exits 0, even when the provider fails outright. The size of what
  # we could extract is the only honest success signal.
  : >"$dest/$slug.md"
  if [[ "$USE_CHAT_LOG" -eq 1 ]] && [[ -s "$dest/$slug.chat.log" ]]; then
    extract_from_chat_log "$dest/$slug.chat.log" >"$dest/$slug.md.raw" || true
  else
    extract_from_stdout "$dest/$slug.stdout.log" >"$dest/$slug.md.raw" || true
  fi
  trim_blank_edges "$dest/$slug.md.raw" >"$dest/$slug.md"
  rm -f "$dest/$slug.md.raw"

  answer_bytes="$(wc -c <"$dest/$slug.md" | tr -d '[:space:]')"
  if [[ "$answer_bytes" -lt "$MIN_ANSWER_CHARS" ]] && [[ "$status" == "ok" ]]; then
    status="extract-empty"
  fi

  printf '%s\t%s\t%s\t%s\n' "$status" "$code" "$((ended - started))" "$answer_bytes" \
    >"$dest/$slug.status"
}

wait_for_slot() {
  while [[ "$(jobs -rp | wc -l)" -ge "$JOBS" ]]; do
    sleep 0.2
  done
}

read_status_field() {
  local file="$1" field="$2"
  [[ -f "$file" ]] || {
    echo ""
    return
  }
  cut -f"$field" <"$file"
}

# Fans members out, capped at --jobs, then reports each seat's outcome.
run_round() {
  local round="$1"
  shift
  local -a indices=("$@")
  local dest="$OUT_DIR/$round"
  local i slug status ok=0 bad=0

  log_info "Round $round: ${#indices[@]} member(s), up to $JOBS at once"

  for i in "${indices[@]}"; do
    wait_for_slot
    run_one "${MEMBER_SLUG[$i]}" "${MEMBER_PROVIDER[$i]}" "${MEMBER_MODEL[$i]}" \
      "$dest/${MEMBER_SLUG[$i]}.prompt.md" "$dest" &
  done
  wait

  for i in "${indices[@]}"; do
    slug="${MEMBER_SLUG[$i]}"
    status="$(read_status_field "$dest/$slug.status" 1)"
    if [[ "$status" == "ok" ]]; then
      log_success "$round $slug ($(model_label "$i"))"
      ok=$((ok + 1))
    else
      log_error "$round $slug ($(model_label "$i")): $status"
      bad=$((bad + 1))
    fi
  done

  log_info "$round: $ok passed, $bad failed (of ${#indices[@]})"
}

model_label() {
  local i="$1"
  if [[ "$SMOKE" -eq 1 ]]; then
    echo "mock"
  elif [[ -n "${MEMBER_PROVIDER[$i]}" ]]; then
    echo "${MEMBER_PROVIDER[$i]}:${MEMBER_MODEL[$i]}"
  elif [[ -n "${MEMBER_MODEL[$i]}" ]]; then
    echo "${MEMBER_MODEL[$i]}"
  else
    echo "config default"
  fi
}

member_ok() {
  [[ "$(read_status_field "$OUT_DIR/$1/${MEMBER_SLUG[$2]}.status" 1)" == "ok" ]]
}

# Concatenates every other surviving member's round-one critique, in seat order
# so that the ordering never hints at which model is which, and truncated so one
# verbose member cannot crowd out the rest of the council.
build_peer_file() {
  local self="$1" out="$2"
  shift 2
  local -a survivors=("$@")
  local peer src bytes

  : >"$out"
  for peer in "${survivors[@]}"; do
    [[ "$peer" -ne "$self" ]] || continue
    src="$OUT_DIR/round1/${MEMBER_SLUG[$peer]}.md"
    [[ -s "$src" ]] || continue

    printf -- '--- Member %02d (%s) [%s] ---\n\n' \
      "$peer" "${ROLE_NAME[$peer]}" "$(model_label "$peer")" >>"$out"

    bytes="$(wc -c <"$src" | tr -d '[:space:]')"
    if [[ "$bytes" -gt "$MAX_PEER_CHARS" ]]; then
      head -c "$MAX_PEER_CHARS" "$src" >>"$out"
      printf '\n[TRUNCATED: %d chars omitted]\n' "$((bytes - MAX_PEER_CHARS))" >>"$out"
    else
      cat "$src" >>"$out"
    fi
    printf '\n\n' >>"$out"
  done

  [[ -s "$out" ]] || printf '(no other member reported)\n' >"$out"
}

compose_round2_prompt() {
  local index="$1" out="$2"
  shift 2
  local -a survivors=("$@")
  local template scratch peers pair pair_name="none" pair_alive=0 p

  pair="${MEMBER_PAIR[$index]}"
  if [[ "$pair" -ge 0 ]]; then
    for p in "${survivors[@]}"; do
      [[ "$p" -eq "$pair" ]] && pair_alive=1 && break
    done
  fi

  if [[ "$pair_alive" -eq 1 ]]; then
    template="$PROMPT_DIR/round2.md"
    pair_name="${ROLE_NAME[$pair]}"
  else
    template="$PROMPT_DIR/round2-nopair.md"
    [[ "$pair" -ge 0 ]] && log_info "Seat $(printf '%02d' "$index") lost its opposite; it will attack the strongest claims instead"
  fi
  [[ -f "$template" ]] || die "Round-two template not found: $template"

  peers="$TEMP_ROOT/peers-$(printf '%02d' "$index").md"
  build_peer_file "$index" "$peers" "${survivors[@]}"

  scratch="${out}.scalars"
  render_scalars "$template" "$scratch" \
    "$(printf '%02d' "$index")" "${ROLE_NAME[$index]}" "$pair_name" "$MEMBER_COUNT"
  splice_all "$scratch" "$out" \
    "{{ROLE_BRIEF}}" "${ROLE_FILE[$index]}" \
    "{{SUBJECT}}" "$SUBJECT_PATH" \
    "{{OWN_ROUND1}}" "$OUT_DIR/round1/${MEMBER_SLUG[$index]}.md" \
    "{{PEER_CRITIQUES}}" "$peers"
  rm -f "$scratch"

  [[ "$SMOKE" -eq 1 ]] && guard_mock_keywords "$out"
  return 0
}

warn_if_prompt_large() {
  local file="$1" bytes
  bytes="$(wc -c <"$file" | tr -d '[:space:]')"
  if [[ "$bytes" -gt 204800 ]]; then
    log_warning "$(basename "$file") is ${bytes} bytes and may exceed the model's context window"
  fi
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
  find_seed_config

  TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/council.XXXXXX")"
  trap cleanup EXIT

  local i
  local -a all_seats=()
  for ((i = 0; i < MEMBER_COUNT; i++)); do
    compose_round1_prompt "$i" "$OUT_DIR/round1/${MEMBER_SLUG[$i]}.prompt.md"
    all_seats+=("$i")
  done
  log_success "Composed $MEMBER_COUNT round-one prompts in $OUT_DIR/round1"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "Dry run: prompts written, no models called"
    return 0
  fi

  if [[ "$USE_CHAT_LOG" -eq 1 ]] && [[ "$SMOKE" -eq 0 ]]; then
    log_warning "--chat-log forces high reasoning effort in puny, which costs more per call"
  fi

  run_round round1 "${all_seats[@]}"

  local survivors=()
  for ((i = 0; i < MEMBER_COUNT; i++)); do
    member_ok round1 "$i" && survivors+=("$i")
  done

  if [[ "${#survivors[@]}" -lt "$MIN_MEMBERS" ]]; then
    log_error "Only ${#survivors[@]} member(s) reported, below the --min-members floor of $MIN_MEMBERS"
    exit 2
  fi

  local -a round2_seats=()
  if [[ "$SKIP_CROSS" -eq 1 ]]; then
    log_info "Skipping round two"
  else
    for i in "${survivors[@]}"; do
      compose_round2_prompt "$i" "$OUT_DIR/round2/${MEMBER_SLUG[$i]}.prompt.md" "${survivors[@]}"
      warn_if_prompt_large "$OUT_DIR/round2/${MEMBER_SLUG[$i]}.prompt.md"
      round2_seats+=("$i")
    done
    run_round round2 "${round2_seats[@]}"
  fi
}

main "$@"
