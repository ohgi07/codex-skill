#!/usr/bin/env bash
# codex-run.sh — thin, safe wrapper around the OpenAI Codex CLI for Claude Code's /codex skill.
#
#   codex-run.sh review   [-C DIR] [-m MODEL] [--effort X] [--uncommitted | --base BRANCH | --commit SHA]
#   codex-run.sh ask      [-C DIR] [-m MODEL] [--effort X] [PROMPT | -]
#   codex-run.sh delegate [-C DIR] [-m MODEL] [--effort X] [PROMPT | -]
#   codex-run.sh resume   [-C DIR] (--last | SESSION_ID) [--mode read-only|workspace-write] [PROMPT | -]
#
# Sandbox invariants enforced here, not assumed from Codex defaults:
#   review/ask  -> -s read-only
#   delegate    -> -s workspace-write --approve-for-me
#   resume      -> -c sandbox_mode="<--mode>", default read-only
# This script never passes any flag that bypasses sandboxing or approvals.

usage() {
  cat <<'USAGE'
Usage:
  codex-run.sh review   [-C DIR] [-m MODEL] [--effort X] [--uncommitted | --base BRANCH | --commit SHA]
  codex-run.sh ask      [-C DIR] [-m MODEL] [--effort X] [PROMPT | -]
  codex-run.sh delegate [-C DIR] [-m MODEL] [--effort X] [PROMPT | -]
  codex-run.sh resume   [-C DIR] (--last | SESSION_ID) [--mode read-only|workspace-write] [PROMPT | -]

Modes:
  review    Codex's built-in code review of the repo in DIR (read-only). Default target: --uncommitted.
            Takes no PROMPT; for free-form review instructions use `ask`.
  ask       Read-only question about the code in DIR. Codex can read files, not write.
  delegate  Let Codex edit files in DIR (workspace-write; approvals go through Codex automatic review).
  resume    Continue a previous session. Permissions come from --mode (default read-only).

Prompt: last positional argument, or `-` / omitted to read stdin (heredoc-friendly).
Env:    CODEX_RUN_KEEP_LOG=1 keeps the raw JSONL event log even on success.
USAGE
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
      -C)       [ $# -ge 2 ] || die "-C needs a directory"; DIR="$2"; shift 2 ;;
      -m)       [ $# -ge 2 ] || die "-m needs a model"; MODEL="$2"; shift 2 ;;
      --effort) [ $# -ge 2 ] || die "--effort needs a value"; EFFORT="$2"; shift 2 ;;
      --uncommitted)
        [ "$MODE" = review ] || die "--uncommitted is only valid for review"
        REVIEW_TARGET=(--uncommitted); target_count=$((target_count+1)); shift ;;
      --base)
        [ "$MODE" = review ] || die "--base is only valid for review"
        [ $# -ge 2 ] || die "--base needs a branch"
        REVIEW_TARGET=(--base "$2"); target_count=$((target_count+1)); shift 2 ;;
      --commit)
        [ "$MODE" = review ] || die "--commit is only valid for review"
        [ $# -ge 2 ] || die "--commit needs a sha"
        REVIEW_TARGET=(--commit "$2"); target_count=$((target_count+1)); shift 2 ;;
      --last)
        [ "$MODE" = resume ] || die "--last is only valid for resume"
        RESUME_LAST=1; shift ;;
      --mode)
        [ "$MODE" = resume ] || die "--mode is only valid for resume"
        [ $# -ge 2 ] || die "--mode needs a value"
        RESUME_MODE="$2"; shift 2 ;;
      --) shift; while [ $# -gt 0 ]; do pos+=("$1"); shift; done ;;
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
        PROMPT_ARG="${pos[0]-}"
      else
        [ "${#pos[@]}" -ge 1 ] || die "resume needs --last or SESSION_ID"
        [ "${#pos[@]}" -le 2 ] || die "unexpected extra argument: ${pos[2]}"
        SESSION_ID="${pos[0]}"
        PROMPT_ARG="${pos[1]-}"
      fi
      ;;
  esac
}

# build_cmd -> sets CMD (array). Uses MODE MODEL EFFORT REVIEW_TARGET RESUME_LAST SESSION_ID RESUME_MODE OUT_FILE.
build_cmd() {
  CFG_ARGS=(); MODEL_ARGS=()
  [ -z "$EFFORT" ] || CFG_ARGS+=(-c "model_reasoning_effort=\"$EFFORT\"")
  [ -z "$MODEL" ]  || MODEL_ARGS+=(-m "$MODEL")

  case "$MODE" in
    review)
      # -s goes on `exec` (review has no -s); -c sandbox_mode is added on `review` too so the
      # read-only guarantee does not depend on how the parent flag propagates.
      CMD=(codex exec -s read-only --color never review "${REVIEW_TARGET[@]}" -c 'sandbox_mode="read-only"' "${CFG_ARGS[@]}" "${MODEL_ARGS[@]}") ;;
    ask)
      CMD=(codex exec -s read-only --color never --skip-git-repo-check --json -o "$OUT_FILE" "${CFG_ARGS[@]}" "${MODEL_ARGS[@]}" -) ;;
    delegate)
      CMD=(codex exec -s workspace-write --approve-for-me --color never --skip-git-repo-check --json -o "$OUT_FILE" "${CFG_ARGS[@]}" "${MODEL_ARGS[@]}" -) ;;
    resume)
      local -a target
      if [ "$RESUME_LAST" -eq 1 ]; then target=(--last); else target=("$SESSION_ID"); fi
      CMD=(codex exec resume "${target[@]}" --skip-git-repo-check --json -o "$OUT_FILE" -c "sandbox_mode=\"$RESUME_MODE\"" "${CFG_ARGS[@]}" "${MODEL_ARGS[@]}" -) ;;
  esac
}

looks_like_uuid() {
  [[ "${1-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
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
  if [ "$MODE" = resume ] && [ -n "$SESSION_ID" ] && looks_like_uuid "$SESSION_ID" && [ -n "$tid" ] \
     && [ "${tid,,}" != "${SESSION_ID,,}" ]; then
    KEEP_LOG=1
    echo "codex-run: requested session $SESSION_ID but codex started thread $tid; session was NOT resumed" >&2
    return 1
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

cleanup() {
  if [ "${KEEP_LOG:-0}" = 1 ] || [ "${CODEX_RUN_KEEP_LOG:-0}" = 1 ]; then
    echo "codex-run: events log kept at $LOG" >&2
  else
    rm -f "$LOG"
  fi
  rm -f "$OUT_FILE" "$ERR_FILE"
}

main() {
  set -euo pipefail
  umask 077

  command -v codex >/dev/null 2>&1 || { echo "codex-run: 'codex' not found on PATH (npm i -g @openai/codex)" >&2; exit 2; }

  parse_args "$@"
  [ -d "$DIR" ] || die "directory not found: $DIR"
  if [ "$MODE" != review ]; then
    resolve_prompt "$PROMPT_ARG"
  fi
  cd "$DIR"

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
    echo "codex-run: review not implemented yet" >&2; exit 1
  else
    run_json_mode
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
