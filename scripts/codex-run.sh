#!/usr/bin/env bash
# codex-run.sh — thin, safe wrapper around the OpenAI Codex CLI for Claude Code's /codex skill.
#
#   codex-run.sh review   [-C DIR] [-m MODEL] [--effort X] [--uncommitted | --base BRANCH | --commit SHA]
#   codex-run.sh ask      [-C DIR] [-m MODEL] [--effort X] [PROMPT | -]
#   codex-run.sh delegate [-C DIR] [-m MODEL] [--effort X] [PROMPT | -]
#   codex-run.sh resume   [-C DIR] [-m MODEL] [--effort X] (--last | SESSION_ID) [--mode read-only|workspace-write] [PROMPT | -]
#
# Sandbox invariants enforced here, not assumed from Codex defaults (verified against Codex 0.154.0):
#   review/ask            -> -s read-only + approval_policy="never"  (no escalation path out of the sandbox)
#   delegate              -> --approve-for-me  (= sandbox_mode=workspace-write + approval_policy=on-request
#                            + approvals_reviewer=auto_review; mutually exclusive with -s in 0.154.0)
#   resume                -> -c sandbox_mode="<--mode>" with the matching policy above; default read-only
#   Windows (msys/cygwin) -> -c windows.sandbox="unelevated" on every call. Without Codex's Windows sandbox
#                            backend there is NO sandbox on Windows and "read-only" is not enforced at all.
#                            CODEX_RUN_WINDOWS_SANDBOX=elevated selects the stronger backend once set up.
# This script never passes any flag that bypasses sandboxing or approvals.

usage() {
  # printf is a bash builtin (unlike cat); --help must work even with no PATH at all.
  printf '%s\n' "Usage:
  codex-run.sh review   [-C DIR] [-m MODEL] [--effort X] [--uncommitted | --base BRANCH | --commit SHA]
  codex-run.sh ask      [-C DIR] [-m MODEL] [--effort X] [PROMPT | -]
  codex-run.sh delegate [-C DIR] [-m MODEL] [--effort X] [PROMPT | -]
  codex-run.sh resume   [-C DIR] [-m MODEL] [--effort X] (--last | SESSION_ID) [--mode read-only|workspace-write] [PROMPT | -]

Modes:
  review    Codex's built-in code review of the repo in DIR (read-only). Default target: --uncommitted.
            Takes no PROMPT; for free-form review instructions use \`ask\`.
  ask       Read-only question about the code in DIR. Codex can read files, not write.
  delegate  Let Codex edit files in DIR (workspace-write; approvals go through Codex automatic review).
  resume    Continue a previous session. Permissions come from --mode (default read-only).

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
    review|ask|delegate|resume) shift ;;
    *) die "unknown mode: $MODE (expected review|ask|delegate|resume)" ;;
  esac

  DIR="$PWD"; MODEL=""; EFFORT=""
  REVIEW_TARGET=(); local target_count=0
  RESUME_LAST=0; SESSION_ID=""; RESUME_MODE="read-only"
  PROMPT_ARG=""
  local -a pos=()

  while [ $# -gt 0 ]; do
    case "$1" in
      -C)       { [ $# -ge 2 ] && case "$2" in -*) false;; esac; } || die "-C needs a directory"; DIR="$2"; shift 2 ;;
      -m)       { [ $# -ge 2 ] && case "$2" in -*) false;; esac; } || die "-m needs a model"; MODEL="$2"; shift 2 ;;
      --effort) { [ $# -ge 2 ] && case "$2" in -*) false;; esac; } || die "--effort needs a value"; EFFORT="$2"; shift 2 ;;
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
        [ "$MODE" = resume ] || die "--last is only valid for resume"
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
      CMD=(codex exec -s read-only --color never review "${REVIEW_TARGET[@]}" -c 'sandbox_mode="read-only"' "${ro_policy[@]}" "${PLATFORM_ARGS[@]}" "${CFG_ARGS[@]}" "${MODEL_ARGS[@]}") ;;
    ask)
      CMD=(codex exec -s read-only "${ro_policy[@]}" "${PLATFORM_ARGS[@]}" --color never --skip-git-repo-check --json -o "$OUT_FILE" "${CFG_ARGS[@]}" "${MODEL_ARGS[@]}" -) ;;
    delegate)
      # --approve-for-me already selects the workspace-write sandbox; 0.154.0 rejects it combined with -s.
      CMD=(codex exec --approve-for-me "${PLATFORM_ARGS[@]}" --color never --skip-git-repo-check --json -o "$OUT_FILE" "${CFG_ARGS[@]}" "${MODEL_ARGS[@]}" -) ;;
    resume)
      local -a target policy
      if [ "$RESUME_LAST" -eq 1 ]; then target=(--last); else target=("$SESSION_ID"); fi
      if [ "$RESUME_MODE" = workspace-write ]; then
        policy=("${ww_policy[@]}")
      else
        policy=(-c 'sandbox_mode="read-only"' "${ro_policy[@]}")
      fi
      CMD=(codex exec resume "${target[@]}" --skip-git-repo-check --json -o "$OUT_FILE" "${policy[@]}" "${PLATFORM_ARGS[@]}" "${CFG_ARGS[@]}" "${MODEL_ARGS[@]}" -) ;;
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
  if [ "$MODE" != review ]; then
    resolve_prompt "$PROMPT_ARG"
  fi
  unset CDPATH
  cd -- "$DIR"

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
