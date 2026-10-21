#!/usr/bin/env bash
# codex-run.sh — thin, safe wrapper around the OpenAI Codex CLI for Claude Code's /codex skill.
#
#   codex-run.sh review   [-C DIR] [-m MODEL] [--effort X] [--uncommitted | --base BRANCH | --commit SHA]
#   codex-run.sh ask      [-C DIR] [-m MODEL] [--effort X] [PROMPT | -]
#   codex-run.sh delegate [-C DIR] [-m MODEL] [--effort X] [PROMPT | -]
#   codex-run.sh resume   [-C DIR] [-m MODEL] [--effort X] (--last | SESSION_ID) [--mode read-only|workspace-write] [PROMPT | -]
#   codex-run.sh status   [-C DIR] [--last | SESSION_ID] [--resets | --use-reset]
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
  codex-run.sh status   [-C DIR] [--last | SESSION_ID] [--resets | --use-reset]

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
            --resets     asks the account (codex app-server) for live usage and the rate-limit reset
                         credits available, instead of the last recorded reading. Read-only.
            --use-reset  as --resets, then SPENDS one reset credit (the soonest to expire) to reset the
                         current usage windows, and reads usage again. Irreversible.

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
#                      LIVE USE_RESET
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
  LIVE=0; USE_RESET=0
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
      --resets)
        [ "$MODE" = status ] || die "--resets is only valid for status"
        LIVE=1; shift ;;
      --use-reset)
        [ "$MODE" = status ] || die "--use-reset is only valid for status"
        LIVE=1; USE_RESET=1; shift ;;
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
# Parsed with bash regexes (no jq). Status output builds dozens of fields, and on Windows every $(...) forks
# (~30ms) and every external command spawns (~50ms), so these helpers set a variable or print directly.

# jv JSON KEY -> JV = value of "KEY": a string (\" unescaped, other escapes kept) or a bare number/word;
# empty if absent. When KEY occurs more than once the last one wins.
jv() {
  local s="\"$2\":\"(([^\"\\\\]|\\\\.)*)\"" b="\"$2\":([^,}]*)"
  JV=""
  if [[ $1 =~ .*$s ]]; then JV="${BASH_REMATCH[1]}"; JV="${JV//\\\"/\"}"
  elif [[ $1 =~ .*$b ]]; then JV="${BASH_REMATCH[1]}"
  fi
}

# fmt_time SPEC -> prints the local time for @EPOCH or an ISO-8601 string; falls back to the raw value.
fmt_time() {
  case "$1" in
    @[0-9]*) printf '%(%Y-%m-%d %H:%M %z)T' "${1#@}" ;;
    *) local t; t="$(date -d "$1" '+%Y-%m-%d %H:%M %z' 2>/dev/null)" && printf '%s' "$t" || printf '%s' "$1" ;;
  esac
}

# fmt_window MINUTES -> prints "weekly", "5h window", "3d window", "30m window".
fmt_window() {
  case "$1" in
    10080) printf weekly ;;
    *) if   [ "$1" -ge 1440 ] && [ $(( $1 % 1440 )) -eq 0 ]; then printf '%sd window' "$(( $1 / 1440 ))"
       elif [ "$1" -ge 60 ]   && [ $(( $1 % 60 )) -eq 0 ];   then printf '%sh window' "$(( $1 / 60 ))"
       else printf '%sm window' "$1"; fi ;;
  esac
}

# print_window WINDOW_JSON WINDOW_KEY PERCENT_KEY RESETS_KEY -> "  5h window 19% used (resets <time>)".
# The keys differ between rollout files (snake_case) and app-server replies (camelCase).
print_window() {
  local w p
  jv "$1" "$2"; w="$JV"; jv "$1" "$3"; p="${JV%.0}"; jv "$1" "$4"
  printf '  '; fmt_window "$w"; printf ' %s%% used (resets ' "$p"; fmt_time "@$JV"; printf ')'
}

# first_object JSON KEY -> OBJ = the first brace-free {...} value of "KEY", or empty.
first_object() {
  local re="\"$2\":[{][^}]*[}]"
  OBJ=""; [[ $1 =~ $re ]] && OBJ="${BASH_REMATCH[0]}"
}

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
  local want f meta
  want="$(norm_path "$1")"
  while IFS= read -r f; do
    IFS= read -r meta < "$f" || true
    jv "$meta" thread_source
    [ -z "$JV" ] || [ "$JV" = user ] || continue
    jv "$meta" cwd
    [ "$(norm_path "$JV")" = "$want" ] && { printf '%s' "$f"; return 0; }
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
  local line="$1" sid="$2" rl key
  rl="${line#*\"rate_limits\":}"
  jv "$rl" plan_type
  printf 'limits:  plan=%s' "${JV:-unknown}"
  for key in primary secondary; do
    first_object "$rl" "$key"
    [ -z "$OBJ" ] || print_window "$OBJ" window_minutes used_percent resets_at
  done
  jv "$line" timestamp
  printf '\n         as of '; fmt_time "$JV"; printf ', session %s\n' "$sid"
}

print_session() {   # print_session ROLLOUT_FILE
  local f="$1" meta ctx usage model effort approval k
  local -A tu=()
  IFS= read -r meta < "$f" || true
  ctx="$(grep '"type":"turn_context"' "$f" 2>/dev/null | tail -n 1 || true)"
  echo
  jv "$meta" timestamp
  printf 'session %s   ' "$(session_id_of "$f")"; fmt_time "$JV"
  jv "$meta" cwd; printf '   cwd=%s\n' "${JV//\\\\/\\}"
  if [ -n "$ctx" ]; then
    jv "$ctx" model; model="$JV"; jv "$ctx" effort; effort="$JV"; jv "$ctx" approval_policy; approval="$JV"
    first_object "$ctx" sandbox_policy; jv "$OBJ" type
    echo "  model=$model  effort=$effort  sandbox=$JV  approval=$approval"
  fi
  usage="$(last_token_count "$f")"
  if [ -n "$usage" ]; then
    first_object "$usage" total_token_usage
    for k in total_tokens input_tokens cached_input_tokens output_tokens; do jv "$OBJ" "$k"; tu[$k]="$JV"; done
    jv "$usage" model_context_window
    echo "  tokens: total ${tu[total_tokens]} = input ${tu[input_tokens]} (cached ${tu[cached_input_tokens]}) + output ${tu[output_tokens]}   context window $JV"
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

  local target=""
  if [ -n "$SESSION_ID" ]; then
    target="$(rollout_for_id "$SESSION_ID")"
    [ -n "$target" ] || die "session not found: $SESSION_ID (looked under $CODEX_HOME/sessions)"
  elif [ "$RESUME_LAST" -eq 1 ]; then
    target="$(rollout_for_dir "$(pwd -W 2>/dev/null || pwd)")"
    [ -n "$target" ] || die "no session found for $DIR (looked under $CODEX_HOME/sessions)"
  fi

  local live_rc=0
  if [ "$LIVE" -eq 1 ]; then
    run_live "$target" || live_rc=$?
  else
    print_recorded_limits "$target"
  fi

  [ -z "$target" ] || print_session "$target"
  return "$live_rc"
}

print_recorded_limits() {   # print_recorded_limits [ROLLOUT_FILE]
  local usage_file="" usage_line=""
  if [ -n "${1-}" ]; then usage_line="$(last_token_count "$1")"; usage_file="$1"; fi
  if [ -z "$usage_line" ]; then
    usage_file="$(newest_usage)"
    [ -z "$usage_file" ] || usage_line="$(last_token_count "$usage_file")"
  fi
  if [ -n "$usage_line" ]; then
    print_limits "$usage_line" "$(session_id_of "$usage_file")"
  else
    echo "limits:  (no usage recorded yet)"
  fi
}

# ---------------------------------------------------------------- status --resets / --use-reset (live)
# `codex app-server` speaks JSON-RPC over stdio, one object per line (verified against Codex 0.163.0):
#   initialize                            -> handshake, then the "initialized" notification
#   account/rateLimits/read               -> live rateLimits (camelCase) + rateLimitResetCredits
#                                            {availableCount, credits: [{id, status, expiresAt, title, …}] | null}
#   account/rateLimitResetCredit/consume  -> params {creditId?, idempotencyKey}
#                                            -> {outcome: reset | nothingToReset | noCredit | alreadyRedeemed}
# Responses start with {"id":N, and are matched on that; notifications in between are skipped.
# The server exits on stdin EOF (dropping unanswered requests), so it is closed only after the last reply.

# new_uuid -> random UUIDv4 (idempotency key for one reset attempt).
new_uuid() {
  local h v
  h="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  v="$(printf '%x' $(( (16#${h:16:1} & 3) | 8 )))"
  printf '%s-%s-4%s-%s%s-%s' "${h:0:8}" "${h:8:4}" "${h:13:3}" "$v" "${h:17:3}" "${h:20:12}"
}

app_open() {
  APP_ERR="$(mktemp "${TMPDIR:-/tmp}/codex-run-app.XXXXXX")"
  trap app_close EXIT
  coproc APP { exec codex app-server 2>"$APP_ERR"; }
  APP_IN="${APP[1]}"; APP_OUT="${APP[0]}"; APP_WAIT_PID="$APP_PID"; APP_SEQ=0
  trap '' PIPE   # a dead server must fail the write, not kill the wrapper (set after the spawn: not inherited)
  app_call initialize '{"clientInfo":{"name":"codex-run","version":"1"}}' || return 1
  printf '%s\n' '{"jsonrpc":"2.0","method":"initialized"}' >&"$APP_IN" 2>/dev/null || true
}

# app_exited SECONDS -> polls until the server process is gone (0) or SECONDS have passed (1).
app_exited() {
  local deadline=$((SECONDS + $1))
  while kill -0 "$APP_WAIT_PID" 2>/dev/null; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}

# app_close -> EOF on stdin, then CODEX_RUN_APP_GRACE seconds (default 5) to exit, then SIGTERM and the same
# again, then SIGKILL, so the final wait cannot block. Its stdout is closed first so a server still writing
# cannot block on a full pipe. On Windows the PID is the npm shim's node, which forwards SIGTERM to the
# native binary; SIGKILL ends node only, and the binary already has EOF on both pipes.
app_close() {
  local grace="${CODEX_RUN_APP_GRACE:-5}"
  if [ -n "${APP_IN-}" ]; then
    exec {APP_IN}>&- 2>/dev/null || true
    exec {APP_OUT}<&- 2>/dev/null || true
    app_exited "$grace" || { kill "$APP_WAIT_PID" 2>/dev/null; app_exited "$grace"; } \
      || kill -KILL "$APP_WAIT_PID" 2>/dev/null || true
    wait "$APP_WAIT_PID" 2>/dev/null || true
    APP_IN=""
  fi
  [ -z "${APP_ERR-}" ] || rm -f "$APP_ERR"
}

# app_call METHOD PARAMS_JSON -> RPC_LINE (the response line) or RPC_ERROR, non-zero on failure.
app_call() {
  local id line rc deadline left
  APP_SEQ=$((APP_SEQ + 1)); id=$APP_SEQ; RPC_LINE=""; RPC_ERROR=""
  if printf '{"jsonrpc":"2.0","id":%s,"method":"%s","params":%s}\n' "$id" "$1" "$2" >&"$APP_IN" 2>/dev/null; then
    deadline=$((SECONDS + ${CODEX_RUN_RPC_TIMEOUT:-60}))
    while :; do
      # The deadline is absolute: notifications arriving in between do not extend it.
      left=$((deadline - SECONDS)); rc=142
      [ "$left" -le 0 ] || { rc=0; IFS= read -r -t "$left" line <&"$APP_OUT" 2>/dev/null || rc=$?; }
      if [ "$rc" -gt 128 ]; then RPC_ERROR="no reply to $1 within ${CODEX_RUN_RPC_TIMEOUT:-60}s"; return 1; fi
      [ "$rc" -eq 0 ] || break
      case "$line" in
        "{\"id\":$id,\"result\":"*) RPC_LINE="$line"; return 0 ;;
        "{\"id\":$id,"*) jv "$line" message; RPC_ERROR="${JV:-$line}"; return 1 ;;
      esac
    done
  fi
  RPC_ERROR="codex app-server exited before answering $1"
  [ ! -s "$APP_ERR" ] || RPC_ERROR="$RPC_ERROR: $(tail -n 1 "$APP_ERR")"
  return 1
}

# print_live_limits RESULT_LINE [LABEL] -> "limits:" line from the result's top-level rateLimits snapshot.
print_live_limits() {
  local rl key
  rl="${1#*\"rateLimits\":}"; rl="${rl%%\"rateLimitsByLimitId\"*}"; rl="${rl%%\"rateLimitResetCredits\"*}"
  jv "$rl" planType
  printf 'limits:  plan=%s' "$JV"
  for key in primary secondary; do
    first_object "$rl" "$key"
    [ -z "$OBJ" ] || print_window "$OBJ" windowDurationMins usedPercent resetsAt
  done
  printf '\n         %slive (account/rateLimits/read)\n' "${2:+$2 }"
}

# print_resets RESULT_LINE -> "resets:" block, soonest-expiring first; sets RESET_COUNT and RESET_NEXT_ID
# (the soonest-expiring available credit). Rows are the brace-free {...} objects naming a resetType, so a
# "{" or "}" inside a string either hides a row or cuts it short, and the backend may cap the list; any of
# these could hide a sooner expiry. RESET_NEXT_ID therefore stays empty, and the server picks, unless every
# row was matched, every row has id/status/expiresAt, and the available rows add up to availableCount.
print_resets() {
  local rc rest row rows=() sorted=() n=0 avail=0 complete=1 key id st exp title types
  local sep=$'\x1f' rt='"resetType"'
  RESET_COUNT=0; RESET_NEXT_ID=""
  rc="${1#*\"rateLimitResetCredits\":}"
  if [ "$rc" = "$1" ] || [ "${rc:0:4}" = null ]; then echo "resets:  (not reported for this account)"; return 0; fi
  jv "$rc" availableCount; RESET_COUNT="${JV:-0}"
  case "${rc%%\}*}" in   # the summary up to its first "}": {"availableCount":N,"credits":null} has no rows
    *'"credits":null'*) rest="" ;;
    *) rest="$rc" ;;
  esac
  while [[ $rest =~ [{][^{}]*\"resetType\"[^{}]*[}] ]]; do
    row="${BASH_REMATCH[0]}"; rest="${rest#*"$row"}"
    jv "$row" id; id="$JV"; jv "$row" status; st="$JV"; jv "$row" expiresAt; exp="$JV"; jv "$row" title; title="$JV"
    [ -n "$id" ] && [ -n "$st" ] && [ -n "$exp" ] || complete=0
    case "$exp" in ''|null) key=99999999999 ;; *) key="$exp" ;; esac
    rows+=("$key$sep$id$sep$st$sep$exp$sep$title")
  done
  if [ "${#rows[@]}" -eq 0 ]; then
    if [ "$RESET_COUNT" -gt 0 ]; then echo "resets:  $RESET_COUNT available (no details returned)"
    else echo "resets:  0 available"; fi
    return 0
  fi

  echo "resets:  $RESET_COUNT available"
  mapfile -t sorted < <(printf '%s\n' "${rows[@]}" | sort -n)
  for row in "${sorted[@]}"; do
    IFS="$sep" read -r key id st exp title <<< "$row"
    n=$((n + 1))
    if [ "$st" = available ]; then avail=$((avail + 1)); [ -n "$RESET_NEXT_ID" ] || RESET_NEXT_ID="$id"; fi
    printf '         %s. %s  ' "$n" "$title"
    case "$exp" in ''|null) printf 'no expiry' ;; *) printf 'expires '; fmt_time "@$exp" ;; esac
    printf '  id=%s' "$id"; [ "$st" = available ] || printf '  (%s)' "$st"; printf '\n'
  done

  types="${rc//"$rt"/}"; types=$(( (${#rc} - ${#types}) / ${#rt} ))   # occurrences of "resetType"
  if [ "$complete" -eq 0 ] || [ "$n" -ne "$types" ] || [ "$avail" -ne "$RESET_COUNT" ]; then
    RESET_NEXT_ID=""
    echo "         ($avail of $RESET_COUNT listed or parsed; the server picks which credit to use)"
  fi
}

# use_reset -> spends RESET_NEXT_ID (or lets the backend pick) and prints the "reset:" line.
use_reset() {
  local params outcome
  if [ "$RESET_COUNT" -le 0 ]; then echo "reset:   not used, no reset credits available"; return 1; fi
  params="\"idempotencyKey\":\"$(new_uuid)\""
  [ -z "$RESET_NEXT_ID" ] || params="\"creditId\":\"$RESET_NEXT_ID\",$params"
  if ! app_call account/rateLimitResetCredit/consume "{$params}"; then
    echo "reset:   failed: $RPC_ERROR"; return 1
  fi
  jv "$RPC_LINE" outcome; outcome="$JV"
  case "$outcome" in
    reset)           echo "reset:   done, used ${RESET_NEXT_ID:-the next available credit}" ;;
    alreadyRedeemed) echo "reset:   done (this attempt was already redeemed)" ;;
    nothingToReset)  echo "reset:   not used, no current rate-limit window is eligible for a reset"; return 1 ;;
    noCredit)        echo "reset:   not used, the account has no reset credits"; return 1 ;;
    *)               echo "reset:   unexpected outcome: ${outcome:-none} ($RPC_LINE)"; return 1 ;;
  esac
}

run_live() {   # run_live [ROLLOUT_FILE]
  if ! app_open || ! app_call account/rateLimits/read null; then
    print_recorded_limits "${1-}"
    echo "resets:  unavailable: $RPC_ERROR"
    app_close; return 1
  fi
  print_live_limits "$RPC_LINE"
  print_resets "$RPC_LINE"
  [ "$USE_RESET" -eq 1 ] || { app_close; return 0; }

  local rc=0
  use_reset || rc=$?
  if app_call account/rateLimits/read null; then
    print_live_limits "$RPC_LINE" "after reset,"
    print_resets "$RPC_LINE"
  else
    echo "limits:  re-read failed: $RPC_ERROR"
  fi
  app_close; return "$rc"
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
