#!/usr/bin/env bash
# codex-run.sh — thin, safe wrapper around the OpenAI Codex CLI for Claude Code's /codex skill.
#
#   codex-run.sh review   [-C DIR] [-m MODEL] [--effort X] [--uncommitted | --base BRANCH | --commit SHA]
#   codex-run.sh ask      [-C DIR] [-m MODEL] [--effort X] [PROMPT | -]
#   codex-run.sh delegate [-C DIR] [-m MODEL] [--effort X] [PROMPT | -]
#   codex-run.sh resume   [-C DIR] [-m MODEL] [--effort X] (--last | SESSION_ID) [--mode read-only|workspace-write] [PROMPT | -]
#   codex-run.sh status   [-C DIR] [--last | SESSION_ID]
#
# Sandbox invariants enforced here, not assumed from Codex defaults (verified against Codex 0.154.0):
#   review/ask            -> -s read-only + approval_policy="never"  (no escalation path out of the sandbox)
#   delegate              -> --approve-for-me  (= sandbox_mode=workspace-write + approval_policy=on-request
#                            + approvals_reviewer=auto_review; mutually exclusive with -s in 0.154.0)
#   resume                -> -c sandbox_mode="<--mode>" with the matching policy above; default read-only
#   Windows (msys/cygwin) -> -c windows.sandbox="unelevated" on every call. Without Codex's Windows sandbox
#                            backend there is NO sandbox on Windows and "read-only" is not enforced at all.
#                            CODEX_RUN_WINDOWS_SANDBOX=elevated selects the stronger backend once set up.
#   web search            -> top-level --search on every exec call. The web_search tool runs on OpenAI's side;
#                            shell commands inside the sandbox still have no network.
# This script never passes any flag that bypasses sandboxing or approvals.

usage() {
  # printf is a bash builtin (unlike cat); --help must work even with no PATH at all.
  printf '%s\n' "Usage:
  codex-run.sh review   [-C DIR] [-m MODEL] [--effort X] [--uncommitted | --base BRANCH | --commit SHA]
  codex-run.sh ask      [-C DIR] [-m MODEL] [--effort X] [PROMPT | -]
  codex-run.sh delegate [-C DIR] [-m MODEL] [--effort X] [PROMPT | -]
  codex-run.sh resume   [-C DIR] [-m MODEL] [--effort X] (--last | SESSION_ID) [--mode read-only|workspace-write] [PROMPT | -]
  codex-run.sh status   [-C DIR] [--last | SESSION_ID]

Modes:
  review    Codex's built-in code review of the repo in DIR (read-only). Default target: --uncommitted.
            Takes no PROMPT; for free-form review instructions use \`ask\`.
  ask       Read-only question about the code in DIR. Codex can read files, not write.
  delegate  Let Codex edit files in DIR (workspace-write; approvals go through Codex automatic review).
  resume    Continue a previous session. Permissions come from --mode (default read-only).
  status    Codex version/login, config.toml model/effort/reviewer, the policy this wrapper applies, and the
            rate-limit usage Codex last recorded. With --last (newest session in DIR) or SESSION_ID also shows
            that session's effective model/sandbox/approval and token totals. Reads \$CODEX_HOME/sessions only;
            no API call.

Web search: on in every mode (codex --search); sandboxed shell commands still have no network.

Prompt: last positional argument, or \`-\` / omitted to read stdin (heredoc-friendly).
Env:    CODEX_RUN_KEEP_LOG=1                keeps the raw JSONL event log even on success.
        CODEX_RUN_WINDOWS_SANDBOX=elevated  (Windows only) use Codex's elevated sandbox backend instead of
                                            the default \"unelevated\" restricted-token one."
}

die() { echo "codex-run: $*" >&2; exit 1; }

stdin_is_tty() { [ -t 0 ]; }

# resolve_prompt PROMPT_ARG -> sets PROMPT (global) or dies.
resolve_prompt() {
  local arg="${1-}"
  if [ -n "$arg" ] && [ "$arg" != "-" ]; then
    PROMPT="$arg"
  elif [ "$arg" = "-" ] || ! stdin_is_tty; then
    PROMPT="$(cat; printf x)"; PROMPT="${PROMPT%x}"   # keep trailing newlines intact
  else
    die "no PROMPT given and stdin is a terminal; pass a prompt argument or pipe one on stdin"
  fi
  case "$PROMPT" in
    *[![:space:]]*) ;;
    *) die "prompt is empty" ;;
  esac
}

# extract_thread_id FILE -> prints the thread_id from the first thread.started event, or nothing.
extract_thread_id() {
  [ -f "${1-}" ] || return 0
  grep '"type":"thread\.started"' "$1" 2>/dev/null | sed -n 's/.*"thread_id":"\([^"]*\)".*/\1/p' | head -n 1 || true
}

looks_like_uuid() {
  [[ "${1-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# parse_args "$@" -> sets MODE DIR MODEL EFFORT REVIEW_TARGET RESUME_LAST SESSION_ID RESUME_MODE PROMPT_ARG
parse_args() {
  MODE="${1-}"
  case "$MODE" in
    -h|--help) usage; exit 0 ;;
    "") usage >&2; exit 1 ;;
    review|ask|delegate|resume|status) shift ;;
    *) die "unknown mode: $MODE (expected review|ask|delegate|resume|status)" ;;
  esac

  DIR="$PWD"; MODEL=""; EFFORT=""
  REVIEW_TARGET=(); local target_count=0
  RESUME_LAST=0; SESSION_ID=""; RESUME_MODE="read-only"
  PROMPT_ARG=""
  local -a pos=()

  while [ $# -gt 0 ]; do
    case "$1" in
      -C)       { [ $# -ge 2 ] && case "$2" in -*) false;; esac; } || die "-C needs a directory"; DIR="$2"; shift 2 ;;
      -m)       [ "$MODE" != status ] || die "-m is not valid for status"
                { [ $# -ge 2 ] && case "$2" in -*) false;; esac; } || die "-m needs a model"; MODEL="$2"; shift 2 ;;
      --effort) [ "$MODE" != status ] || die "--effort is not valid for status"
                { [ $# -ge 2 ] && case "$2" in -*) false;; esac; } || die "--effort needs a value"; EFFORT="$2"; shift 2 ;;
      --uncommitted)
        [ "$MODE" = review ] || die "--uncommitted is only valid for review"
        REVIEW_TARGET=(--uncommitted); target_count=$((target_count+1)); shift ;;
      --base)
        [ "$MODE" = review ] || die "--base is only valid for review"
        { [ $# -ge 2 ] && case "$2" in -*) false;; esac; } || die "--base needs a branch"
        REVIEW_TARGET=(--base "$2"); target_count=$((target_count+1)); shift 2 ;;
      --commit)
        [ "$MODE" = review ] || die "--commit is only valid for review"
        { [ $# -ge 2 ] && case "$2" in -*) false;; esac; } || die "--commit needs a sha"
        REVIEW_TARGET=(--commit "$2"); target_count=$((target_count+1)); shift 2 ;;
      --last)
        case "$MODE" in resume|status) ;; *) die "--last is only valid for resume or status" ;; esac
        RESUME_LAST=1; shift ;;
      --mode)
        [ "$MODE" = resume ] || die "--mode is only valid for resume"
        { [ $# -ge 2 ] && case "$2" in -*) false;; esac; } || die "--mode needs a value"
        RESUME_MODE="$2"; shift 2 ;;
      -)  pos+=("$1"); shift ;;
      -*) die "unknown option: $1" ;;
      *)  pos+=("$1"); shift ;;
    esac
  done

  case "$MODE" in
    review)
      [ "$target_count" -le 1 ] || die "review accepts only one of --uncommitted | --base | --commit"
      [ "${#pos[@]}" -eq 0 ] || die "review takes no PROMPT; use 'ask' for free-form review instructions"
      [ "$target_count" -eq 1 ] || REVIEW_TARGET=(--uncommitted)
      ;;
    ask|delegate)
      [ "${#pos[@]}" -le 1 ] || die "unexpected extra argument: ${pos[1]}"
      PROMPT_ARG="${pos[0]-}"
      ;;
    resume)
      case "$RESUME_MODE" in read-only|workspace-write) ;; *) die "--mode must be read-only or workspace-write" ;; esac
      if [ "$RESUME_LAST" -eq 1 ]; then
        [ "${#pos[@]}" -le 1 ] || die "unexpected extra argument: ${pos[1]}"
        looks_like_uuid "${pos[0]-}" && die "pass either --last or SESSION_ID, not both"
        PROMPT_ARG="${pos[0]-}"
      else
        [ "${#pos[@]}" -ge 1 ] || die "resume needs --last or SESSION_ID"
        [ "${#pos[@]}" -le 2 ] || die "unexpected extra argument: ${pos[2]}"
        SESSION_ID="${pos[0]}"
        looks_like_uuid "$SESSION_ID" || die "SESSION_ID must be the UUID printed on the session: line (got: '$SESSION_ID')"
        PROMPT_ARG="${pos[1]-}"
      fi
      ;;
    status)
      [ "${#pos[@]}" -le 1 ] || die "unexpected extra argument: ${pos[1]}"
      if [ "$RESUME_LAST" -eq 1 ]; then
        [ "${#pos[@]}" -eq 0 ] || die "pass either --last or SESSION_ID, not both"
      elif [ "${#pos[@]}" -eq 1 ]; then
        SESSION_ID="${pos[0]}"
        looks_like_uuid "$SESSION_ID" || die "SESSION_ID must be the UUID printed on the session: line (got: '$SESSION_ID')"
      fi
      ;;
  esac
}

# set_platform_args -> sets PLATFORM_ARGS (array). On Windows (Git Bash reports msys or cygwin) Codex has
# no OS sandbox unless its Windows sandbox backend is enabled, so `-s read-only` would not be enforced.
# Enable it per invocation instead of relying on the user's config.toml.
set_platform_args() {
  PLATFORM_ARGS=()
  case "${OSTYPE:-}" in
    msys*|cygwin*)
      local level="${CODEX_RUN_WINDOWS_SANDBOX:-unelevated}"
      case "$level" in
        unelevated|elevated) ;;
        *) die "CODEX_RUN_WINDOWS_SANDBOX must be unelevated or elevated (got: $level)" ;;
      esac
      PLATFORM_ARGS=(-c "windows.sandbox=\"$level\"") ;;
  esac
}

# build_cmd -> sets CMD (array). Uses MODE MODEL EFFORT REVIEW_TARGET RESUME_LAST SESSION_ID RESUME_MODE OUT_FILE.
build_cmd() {
  CFG_ARGS=(); MODEL_ARGS=()
  [ -z "$EFFORT" ] || CFG_ARGS+=(-c "model_reasoning_effort=\"$EFFORT\"")
  [ -z "$MODEL" ]  || MODEL_ARGS+=(-m "$MODEL")
  set_platform_args

  # Read-only: approval_policy=never removes the only path out of the sandbox (an approved escalation).
  # Write: exactly what `--approve-for-me` expands to in 0.154.0, spelled out for `resume`, which has no such flag.
  local -a ro_policy=(-c 'approval_policy="never"')
  local -a ww_policy=(-c 'sandbox_mode="workspace-write"' -c 'approval_policy="on-request"' -c 'approvals_reviewer="auto_review"')

  case "$MODE" in
    review)
      # -s goes on `exec` (review has no -s); -c sandbox_mode is added on `review` too so the
      # read-only guarantee does not depend on how the parent flag propagates.
      CMD=(codex --search exec -s read-only --color never review "${REVIEW_TARGET[@]}" -c 'sandbox_mode="read-only"' "${ro_policy[@]}" "${PLATFORM_ARGS[@]}" "${CFG_ARGS[@]}" "${MODEL_ARGS[@]}") ;;
    ask)
      CMD=(codex --search exec -s read-only "${ro_policy[@]}" "${PLATFORM_ARGS[@]}" --color never --skip-git-repo-check --json -o "$OUT_FILE" "${CFG_ARGS[@]}" "${MODEL_ARGS[@]}" -) ;;
    delegate)
      # --approve-for-me already selects the workspace-write sandbox; 0.154.0 rejects it combined with -s.
      CMD=(codex --search exec --approve-for-me "${PLATFORM_ARGS[@]}" --color never --skip-git-repo-check --json -o "$OUT_FILE" "${CFG_ARGS[@]}" "${MODEL_ARGS[@]}" -) ;;
    resume)
      local -a target policy
      if [ "$RESUME_LAST" -eq 1 ]; then target=(--last); else target=("$SESSION_ID"); fi
      if [ "$RESUME_MODE" = workspace-write ]; then
        policy=("${ww_policy[@]}")
      else
        policy=(-c 'sandbox_mode="read-only"' "${ro_policy[@]}")
      fi
      CMD=(codex --search exec resume "${target[@]}" --skip-git-repo-check --json -o "$OUT_FILE" "${policy[@]}" "${PLATFORM_ARGS[@]}" "${CFG_ARGS[@]}" "${MODEL_ARGS[@]}" -) ;;
  esac
}

print_header() {
  local cwd; cwd="$(pwd -W 2>/dev/null || pwd)"
  echo "[codex $MODE] cwd=$cwd model=${MODEL:-default}"
}

# Prints the last 20 lines of codex's stderr plus any error events from the JSONL.
report_failure() {
  local rc="$1"
  KEEP_LOG=1
  echo "codex-run: codex exited with status $rc" >&2
  [ -s "$ERR_FILE" ] && tail -n 20 "$ERR_FILE" >&2
  grep -E '"type":"(error|turn\.failed)"' "$LOG" 2>/dev/null | tail -n 5 >&2 || true
  if [ -s "$OUT_FILE" ]; then
    echo; echo "--- partial output ---"; cat "$OUT_FILE"; echo
  fi
}

# Executes CMD for ask/delegate/resume. Prompt from $PROMPT on stdin. Returns codex's exit code.
run_json_mode() {
  local rc=0
  printf '%s' "$PROMPT" | "${CMD[@]}" >"$LOG" 2>"$ERR_FILE" || rc=$?
  if [ "$rc" -ne 0 ]; then report_failure "$rc"; return "$rc"; fi

  local tid; tid="$(extract_thread_id "$LOG")"
  if [ "$MODE" = resume ] && [ -n "$SESSION_ID" ]; then
    if [ -z "$tid" ]; then
      echo "codex-run: warning: no thread.started event; could not verify that session $SESSION_ID was resumed" >&2
    elif [ "${tid,,}" != "${SESSION_ID,,}" ]; then
      KEEP_LOG=1
      echo "codex-run: requested session $SESSION_ID but codex started thread $tid; session was NOT resumed" >&2
      return 1
    fi
  fi
  [ -z "$tid" ] || echo "session: $tid"
  echo
  if [ -s "$OUT_FILE" ]; then cat "$OUT_FILE"; echo; fi

  if { [ "$MODE" = delegate ] || { [ "$MODE" = resume ] && [ "$RESUME_MODE" = workspace-write ]; }; } \
     && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo; echo "--- git status after Codex ---"; git status --short
  fi
  return 0
}

# Executes CMD for review. Codex's stdout is passed through unchanged after the header.
run_review() {
  local rc=0
  "${CMD[@]}" </dev/null 2>"$ERR_FILE" || rc=$?
  if [ "$rc" -ne 0 ]; then report_failure "$rc"; return "$rc"; fi
  return 0
}

# ---------------------------------------------------------------- status (offline; reads $CODEX_HOME)
# Codex 0.154.0 writes one rollout file per session under $CODEX_HOME/sessions/YYYY/MM/DD/
# rollout-<timestamp>-<session-id>.jsonl. Line 1 is session_meta (cwd); turn_context lines carry the
# effective model/effort/sandbox/approval; token_count events carry cumulative usage and rate limits.
# Parsed with grep/sed only (no jq), like extract_thread_id.

# jget JSON KEY -> first value of "KEY": either a string or a bare number/word. Empty if absent.
jget() {
  printf '%s' "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p; t; s/.*\"$2\":\([^,}]*\).*/\1/p" | head -n 1
}

# fmt_time SPEC -> local time for an ISO-8601 string or @EPOCH; falls back to the raw value.
fmt_time() { date -d "$1" '+%Y-%m-%d %H:%M %z' 2>/dev/null || printf '%s' "$1"; }

# fmt_window MINUTES -> "weekly", "5h window", "3d window", "30m window".
fmt_window() {
  case "$1" in
    10080) echo weekly ;;
    *) if   [ "$1" -ge 1440 ] && [ $(( $1 % 1440 )) -eq 0 ]; then echo "$(( $1 / 1440 ))d window"
       elif [ "$1" -ge 60 ]   && [ $(( $1 % 60 )) -eq 0 ];   then echo "$(( $1 / 60 ))h window"
       else echo "${1}m window"; fi ;;
  esac
}

# fmt_pct 19.0 -> 19 ; 77.5 -> 77.5
fmt_pct() { printf '%s' "$1" | sed 's/\.0$//'; }

# norm_path PATH -> lowercase, forward slashes, no trailing slash (Codex records cwd as C:\\Users\\... on Windows).
norm_path() {
  local p="$1"
  p="${p//\\\\/\\}"; p="${p//\\//}"; p="${p%/}"
  printf '%s' "${p,,}"
}

# all_rollouts -> rollout files, newest first (date directories + timestamped names sort naturally).
all_rollouts() {
  [ -d "$CODEX_HOME/sessions" ] || return 0
  find "$CODEX_HOME/sessions" -type f -name 'rollout-*.jsonl' 2>/dev/null | sort -r
}

# rollout_for_id UUID -> path of that session's rollout, or nothing.
rollout_for_id() {
  all_rollouts | grep -i -- "-${1}\.jsonl\$" | head -n 1 || true
}

# rollout_for_dir DIR -> newest user-started rollout whose session_meta cwd is DIR, or nothing.
# Codex's automatic reviewer runs as its own thread (thread_source "guardian_review") in the same cwd;
# those are skipped so --last means the same session `resume --last` would pick.
rollout_for_dir() {
  local want f meta src
  want="$(norm_path "$1")"
  while IFS= read -r f; do
    meta="$(head -n 1 "$f")"
    src="$(jget "$meta" thread_source)"
    [ -z "$src" ] || [ "$src" = user ] || continue
    [ "$(norm_path "$(jget "$meta" cwd)")" = "$want" ] && { printf '%s' "$f"; return 0; }
  done < <(all_rollouts)
  return 0
}

# last_token_count FILE -> the last token_count event line in FILE, or nothing.
last_token_count() {
  [ -f "${1-}" ] || return 0
  grep '"type":"token_count"' "$1" 2>/dev/null | tail -n 1 || true
}

# newest_usage -> "FILE" of the newest rollout that has a token_count event, or nothing.
newest_usage() {
  local f
  while IFS= read -r f; do
    grep -q '"type":"token_count"' "$f" 2>/dev/null && { printf '%s' "$f"; return 0; }
  done < <(all_rollouts)
  return 0
}

# session_id_of FILE -> the UUID in the rollout's file name.
session_id_of() { printf '%s' "$1" | sed -n 's/.*-\([0-9a-fA-F-]\{36\}\)\.jsonl$/\1/p'; }

# config_value KEY -> top-level KEY from $CODEX_HOME/config.toml (stops at the first [section]); "(default)" if unset.
config_value() {
  local v=""
  if [ -f "$CODEX_HOME/config.toml" ]; then
    v="$(awk -v k="$1" '
      /^[[:space:]]*\[/ { exit }
      $1 == k && $2 == "=" { sub(/^[^=]*=[[:space:]]*/, ""); gsub(/^"|"[[:space:]]*(#.*)?$/, ""); print; exit }
    ' "$CODEX_HOME/config.toml")"
  fi
  printf '%s' "${v:-(default)}"
}

print_limits() {   # print_limits TOKEN_COUNT_LINE SESSION_ID
  local line="$1" sid="$2" rl p sec plan
  rl="$(printf '%s' "$line" | sed -n 's/.*"rate_limits":{\(.*\)}}$/\1/p')"
  p="$(printf '%s' "$rl" | sed -n 's/.*"primary":{\([^}]*\)}.*/\1/p')"
  sec="$(printf '%s' "$rl" | sed -n 's/.*"secondary":{\([^}]*\)}.*/\1/p')"
  plan="$(jget "$rl" plan_type)"
  printf 'limits:  plan=%s' "${plan:-unknown}"
  local part
  for part in "$p" "$sec"; do
    [ -n "$part" ] || continue
    printf '  %s %s%% used (resets %s)' \
      "$(fmt_window "$(jget "$part" window_minutes)")" "$(fmt_pct "$(jget "$part" used_percent)")" \
      "$(fmt_time "@$(jget "$part" resets_at)")"
  done
  printf '\n         as of %s, session %s\n' "$(fmt_time "$(jget "$line" timestamp)")" "$sid"
}

print_session() {   # print_session ROLLOUT_FILE
  local f="$1" meta ctx usage tu
  meta="$(head -n 1 "$f")"
  ctx="$(grep '"type":"turn_context"' "$f" 2>/dev/null | tail -n 1 || true)"
  echo
  echo "session $(session_id_of "$f")   $(fmt_time "$(jget "$meta" timestamp)")   cwd=$(jget "$meta" cwd | sed 's/\\\\/\\/g')"
  if [ -n "$ctx" ]; then
    echo "  model=$(jget "$ctx" model)  effort=$(jget "$ctx" effort)  sandbox=$(jget "$(printf '%s' "$ctx" | sed -n 's/.*"sandbox_policy":{\([^}]*\)}.*/\1/p')" type)  approval=$(jget "$ctx" approval_policy)"
  fi
  usage="$(last_token_count "$f")"
  if [ -n "$usage" ]; then
    tu="$(printf '%s' "$usage" | sed -n 's/.*"total_token_usage":{\([^}]*\)}.*/\1/p')"
    echo "  tokens: total $(jget "$tu" total_tokens) = input $(jget "$tu" input_tokens) (cached $(jget "$tu" cached_input_tokens)) + output $(jget "$tu" output_tokens)   context window $(jget "$usage" model_context_window)"
  else
    echo "  tokens: (no usage recorded)"
  fi
}

run_status() {
  CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
  local ver login
  ver="$(codex --version </dev/null 2>/dev/null || echo unknown)"
  login="$(codex login status </dev/null 2>&1 | head -n 1 || true)"
  echo "[codex status]"
  echo "codex:   $ver  ($(command -v codex))   login: ${login:-unknown}"
  echo "config:  model=$(config_value model)  effort=$(config_value model_reasoning_effort)  approvals_reviewer=$(config_value approvals_reviewer)   ($CODEX_HOME/config.toml)"
  set_platform_args
  local plat="none"
  [ "${#PLATFORM_ARGS[@]}" -eq 0 ] || plat="${PLATFORM_ARGS[1]}"
  echo "wrapper: $plat | read-only modes: approval_policy=never | delegate: --approve-for-me | web search: on"

  local target="" usage_file="" usage_line=""
  if [ -n "$SESSION_ID" ]; then
    target="$(rollout_for_id "$SESSION_ID")"
    [ -n "$target" ] || die "session not found: $SESSION_ID (looked under $CODEX_HOME/sessions)"
  elif [ "$RESUME_LAST" -eq 1 ]; then
    target="$(rollout_for_dir "$(pwd -W 2>/dev/null || pwd)")"
    [ -n "$target" ] || die "no session found for $DIR (looked under $CODEX_HOME/sessions)"
  fi

  if [ -n "$target" ]; then usage_line="$(last_token_count "$target")"; usage_file="$target"; fi
  if [ -z "$usage_line" ]; then
    usage_file="$(newest_usage)"
    [ -z "$usage_file" ] || usage_line="$(last_token_count "$usage_file")"
  fi
  if [ -n "$usage_line" ]; then
    print_limits "$usage_line" "$(session_id_of "$usage_file")"
  else
    echo "limits:  (no usage recorded yet)"
  fi

  [ -z "$target" ] || print_session "$target"
}

cleanup() {
  if { [ "${KEEP_LOG:-0}" = 1 ] || [ "${CODEX_RUN_KEEP_LOG:-0}" = 1 ]; } && [ -s "$LOG" ]; then
    echo "codex-run: events log kept at $LOG" >&2
  else
    rm -f "$LOG"
  fi
  rm -f "$OUT_FILE" "$ERR_FILE"
}

main() {
  set -euo pipefail
  umask 077

  parse_args "$@"

  command -v codex >/dev/null 2>&1 || { echo "codex-run: 'codex' not found on PATH (npm i -g @openai/codex)" >&2; exit 2; }

  [ -d "$DIR" ] || die "directory not found: $DIR"
  case "$MODE" in review|status) ;; *) resolve_prompt "$PROMPT_ARG" ;; esac
  unset CDPATH
  cd -- "$DIR"
  if [ "$MODE" = status ]; then run_status; return; fi

  local tmproot="${TMPDIR:-/tmp}/codex-run"
  mkdir -p "$tmproot"
  LOG="$(mktemp "$tmproot/events.XXXXXX")"
  OUT_FILE="$(mktemp "$tmproot/last.XXXXXX")"
  ERR_FILE="$(mktemp "$tmproot/stderr.XXXXXX")"
  KEEP_LOG=0
  trap cleanup EXIT

  build_cmd
  print_header
  if [ "$MODE" = review ]; then
    run_review
  else
    run_json_mode
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
