#!/usr/bin/env bash
# Unit tests for skills/codex/scripts/codex-run.sh. No network: a fake `codex` is put on PATH.
# Run: bash tests/test-unit.sh   (CODEX_TEST_SERIAL=1 runs the lanes one after another, for debugging)
#
# The tests are split into lanes (lane_* functions below) that run in parallel, each in its own subshell
# with its own WORK and TMPDIR. On Windows every process launch costs ~0.1s, so the run is bound by how
# many processes start, not by CPU; the helpers avoid launching external commands where a builtin will do.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="$HERE/../skills/codex/scripts/codex-run.sh"
WORK_ROOT="$HERE/.work"
rm -rf "$WORK_ROOT"; mkdir -p "$WORK_ROOT/bin"
cp "$HERE/fake-codex" "$WORK_ROOT/bin/codex"; chmod +x "$WORK_ROOT/bin/codex"
export PATH="$WORK_ROOT/bin:$PATH"
export CODEX_RUN_USAGE_LIMIT=off   # the guard reads the real ~/.codex; tests that cover it set a limit and a fixture CODEX_HOME

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL - $1"; [ -n "${2:-}" ] && echo "       $2"; }
assert_eq()           { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected [$3] got [$2]"; fi; }
assert_contains()     { case "$2" in *"$3"*) ok "$1";; *) fail "$1" "missing [$3] in: $2";; esac; }
assert_not_contains() { case "$2" in *"$3"*) fail "$1" "unexpected [$3] in: $2";; *) ok "$1";; esac; }
has_arg()  { grep -qx -- "$1" "$FAKE_CODEX_ARGS"; }
args_str() { local a=(); [ -f "$FAKE_CODEX_ARGS" ] && mapfile -t a < "$FAKE_CODEX_ARGS"; [ ${#a[@]} -eq 0 ] || printf '%s ' "${a[@]}"; }
reset_fake() {   # fresh file names each call, so nothing has to be deleted (an `rm` per test adds up)
  FAKE_N=$((FAKE_N + 1))
  export FAKE_CODEX_ARGS="$WORK/args.$FAKE_N" FAKE_CODEX_STDIN="$WORK/stdin.$FAKE_N"
  unset FAKE_CODEX_THREAD FAKE_CODEX_MSG FAKE_CODEX_RC FAKE_CODEX_TOUCH FAKE_CODEX_EVAL CODEX_RUN_KEEP_LOG
}
lane_setup() {   # NAME : per-lane WORK and TMPDIR
  WORK="$WORK_ROOT/$1"; mkdir -p "$WORK/tmp"
  export TMPDIR="$WORK/tmp"
  FAKE_N=0; reset_fake
}
# run_wrapper ARGS... : runs the wrapper; sets RC, OUT (stdout), ERR (stderr). stdin is inherited.
run_wrapper() {
  local o="$WORK/out" e="$WORK/err"
  bash "$RUN" "$@" >"$o" 2>"$e"; RC=$?
  OUT="$(<"$o")"; ERR="$(<"$e")"
}
log_count() { local f; shopt -s nullglob; f=("$TMPDIR"/codex-run/*); shopt -u nullglob; echo "${#f[@]}"; }
# Platform-specific argv the wrapper adds (Windows needs Codex's Windows sandbox backend enabled).
case "${OSTYPE:-}" in msys*|cygwin*) PLAT=' -c windows.sandbox="unelevated"';; *) PLAT='';; esac
RO_POLICY=' -c approval_policy="never"'
WW_POLICY=' -c sandbox_mode="workspace-write" -c approval_policy="on-request" -c approvals_reviewer="auto_review"'

GIT=(git -c user.name=t -c user.email=t@t)
mk_repo() {   # a.txt committed, b.txt committed then modified (pre-existing change)
  REPO="$WORK/report-repo"; rm -rf "$REPO"; mkdir -p "$REPO"
  git -C "$REPO" init -q
  printf 'one\n' > "$REPO/a.txt"; printf 'one\n' > "$REPO/b.txt"
  "${GIT[@]}" -C "$REPO" add . && "${GIT[@]}" -C "$REPO" commit -q -m init
  printf 'two\n' >> "$REPO/b.txt"
}
repo_json() { (cd "$REPO" && (pwd -W 2>/dev/null || pwd) | sed 's#/#\\\\#g'); }   # C:\\Users\\... as in the JSON

# Fixture CODEX_HOME shaped like the real one (Codex 0.154.0 rollout files): session_meta on line 1,
# a turn_context line, and (for sessions that completed a turn) a token_count event with rate limits.
SID_A="aaaaaaaa-0000-4000-8000-00000000000a"   # in REPO, has usage, newest in REPO
SID_B="bbbbbbbb-0000-4000-8000-00000000000b"   # elsewhere, has usage, newest overall
SID_C="cccccccc-0000-4000-8000-00000000000c"   # in REPO, failed before any usage
SID_G="99999999-0000-4000-8000-000000000099"   # in REPO, newest, but a guardian_review thread (auto reviewer)
mk_rollout() { # file id cwd_json model sandbox approval [usage_line] ; MK_SOURCE overrides thread_source
  { printf '{"timestamp":"2026-09-16T10:03:27.663Z","ordinal":0,"type":"session_meta","payload":{"session_id":"%s","id":"%s","timestamp":"2026-09-16T10:03:27.485Z","cwd":"%s","originator":"codex_exec","cli_version":"0.154.0","source":"exec","thread_source":"%s"}}\n' "$2" "$2" "$3" "${MK_SOURCE:-user}"
    printf '{"timestamp":"2026-09-16T10:03:29.636Z","ordinal":5,"type":"turn_context","payload":{"turn_id":"t","cwd":"%s","approval_policy":"%s","sandbox_policy":{"type":"%s"},"model":"%s","effort":"medium","summary":"auto"}}\n' "$3" "$6" "$5" "$4"
    [ -z "${7-}" ] || printf '%s\n' "$7"
  } > "$1"
}
usage_json() { # total input cached output pct5h pctweek plan
  printf '{"timestamp":"2026-09-16T10:03:25.926Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":%s,"cached_input_tokens":%s,"cache_write_input_tokens":0,"output_tokens":%s,"reasoning_output_tokens":0,"total_tokens":%s},"last_token_usage":{"input_tokens":1,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0,"total_tokens":2},"model_context_window":258400},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":%s,"window_minutes":300,"resets_at":1789568043},"secondary":{"used_percent":%s,"window_minutes":10080,"resets_at":1790088680},"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"individual_limit":null,"spend_control_reached":null,"plan_type":"%s","rate_limit_reached_type":null}}}' "$2" "$3" "$4" "$1" "$5" "$6" "$7"
}
mk_codex_home() {   # sets REPO, REPO_JSON, CH and exports CODEX_HOME
  REPO="$WORK/repo"; mkdir -p "$REPO"
  REPO_JSON="$(repo_json)"
  CH="$WORK/codex-home"; rm -rf "$CH"; mkdir -p "$CH/sessions/2026/09/15" "$CH/sessions/2026/09/16"
  printf '%s\n' 'model = "cfg-model"' 'model_reasoning_effort = "high"' 'approvals_reviewer = "auto_review"' \
    '[projects."x"]' 'model = "not-this-one"' > "$CH/config.toml"
  mk_rollout "$CH/sessions/2026/09/15/rollout-2026-09-15T09-00-00-$SID_C.jsonl" "$SID_C" "$REPO_JSON" "bad-model" "read-only" "never"
  mk_rollout "$CH/sessions/2026/09/16/rollout-2026-09-16T10-00-00-$SID_A.jsonl" "$SID_A" "$REPO_JSON" "model-a" "workspace-write" "on-request" \
    "$(usage_json 24786 24539 11776 247 19.0 34.0 plus)"
  mk_rollout "$CH/sessions/2026/09/16/rollout-2026-09-16T11-00-00-$SID_B.jsonl" "$SID_B" 'D:\\elsewhere' "model-b" "read-only" "never" \
    "$(usage_json 500 400 0 100 77.5 88.0 pro)"
  MK_SOURCE=guardian_review mk_rollout "$CH/sessions/2026/09/16/rollout-2026-09-16T10-30-00-$SID_G.jsonl" "$SID_G" "$REPO_JSON" "codex-auto-review" "read-only" "never"
  export CODEX_HOME="$CH"
}

lane_basic() {   # usage validation, ask
# ---------------------------------------------------------------- usage validation (no codex call)
reset_fake; run_wrapper
assert_eq "no args -> rc 1" "$RC" 1
assert_contains "no args -> usage on stderr" "$ERR" "Usage:"
[ ! -e "$FAKE_CODEX_ARGS" ] && ok "no args -> codex not invoked" || fail "no args -> codex not invoked"

reset_fake; run_wrapper frobnicate "hi"
assert_eq "unknown mode -> rc 1" "$RC" 1
assert_contains "unknown mode -> message" "$ERR" "unknown mode"

reset_fake
o="$(PATH=/nonexistent "$(command -v bash)" "$RUN" --help 2>/dev/null)"; rc=$?
assert_eq "--help works without codex on PATH -> rc 0" "$rc" 0
assert_contains "--help works without codex on PATH -> usage on stdout" "$o" "Usage:"

reset_fake
e="$(PATH=/nonexistent "$(command -v bash)" "$RUN" ask -C "$WORK" "x" 2>&1 >/dev/null)"; rc=$?
assert_eq "codex not on PATH -> rc 2" "$rc" 2
assert_contains "codex not on PATH -> message" "$e" "not found on PATH"

reset_fake; run_wrapper review --base x --commit y
assert_eq "review two targets -> rc 1" "$RC" 1
assert_contains "review two targets -> message" "$ERR" "only one of"

reset_fake; run_wrapper review "please review"
assert_eq "review with PROMPT -> rc 1" "$RC" 1
assert_contains "review with PROMPT -> points to ask" "$ERR" "use 'ask'"

reset_fake; run_wrapper resume "hi" </dev/null
assert_eq "resume with no --last and non-uuid single arg -> rc 1" "$RC" 1
assert_contains "resume non-uuid single arg -> SESSION_ID error" "$ERR" "SESSION_ID must be"

reset_fake; run_wrapper resume
assert_eq "resume with no target -> rc 1" "$RC" 1
assert_contains "resume with no target -> message" "$ERR" "--last or SESSION_ID"

reset_fake; run_wrapper resume --last --mode bogus "hi"
assert_eq "resume bad --mode -> rc 1" "$RC" 1
assert_contains "resume bad --mode -> message" "$ERR" "--mode must be"

reset_fake; run_wrapper ask --uncommitted "hi"
assert_eq "ask with review flag -> rc 1" "$RC" 1

reset_fake; run_wrapper ask -C "$WORK/does-not-exist" "hi"
assert_eq "-C missing dir -> rc 1" "$RC" 1
assert_contains "-C missing dir -> message" "$ERR" "directory not found"

reset_fake; run_wrapper ask </dev/null          # redirect, not a pipe: a pipe would subshell run_wrapper and lose RC/ERR
assert_eq "ask empty stdin -> rc 1" "$RC" 1
assert_contains "ask empty stdin -> message" "$ERR" "prompt is empty"

reset_fake; run_wrapper ask <<< $'  \n\t'
assert_eq "ask whitespace stdin -> rc 1" "$RC" 1

reset_fake; run_wrapper ask "a" "b"
assert_eq "ask two positionals -> rc 1" "$RC" 1

reset_fake; run_wrapper ask -C "$WORK" -m --dangerously-bypass-approvals-and-sandbox "x"
assert_eq "ask -m leading-dash value -> rc 1" "$RC" 1
assert_contains "ask -m leading-dash value -> message" "$ERR" "-m needs a model"
[ ! -e "$FAKE_CODEX_ARGS" ] && ok "ask -m leading-dash value -> codex not invoked" || fail "ask -m leading-dash value -> codex not invoked"

# TTY guard: source the script and stub stdin_is_tty
( source "$RUN"; stdin_is_tty() { return 0; }; resolve_prompt "" ) </dev/null >/dev/null 2>"$WORK/tty.err"; rc=$?
assert_eq "TTY + no PROMPT -> rc 1" "$rc" 1
assert_contains "TTY + no PROMPT -> message" "$(<"$WORK/tty.err")" "stdin is a terminal"
p="$( ( source "$RUN"; stdin_is_tty() { return 0; }; resolve_prompt "given" && printf '%s' "$PROMPT" ) )"
assert_eq "PROMPT arg wins" "$p" "given"
p="$( ( source "$RUN"; stdin_is_tty() { return 0; }; resolve_prompt "-" && printf '%s' "$PROMPT" ) <<< "dash" )"
assert_eq "PROMPT '-' reads stdin even on TTY" "$p" "dash"

# extract_thread_id
t="$( ( source "$RUN"; extract_thread_id "$WORK/does-not-exist" ) )"
assert_eq "extract_thread_id missing file -> empty" "$t" ""
printf '{"type":"item.completed"}\n' > "$WORK/ev-none.jsonl"
t="$( ( set -euo pipefail; source "$RUN"; extract_thread_id "$WORK/ev-none.jsonl"; echo "still-alive" ) )"
assert_eq "extract_thread_id no thread.started under pipefail -> empty, no abort" "$t" "still-alive"

# ---------------------------------------------------------------- ask
reset_fake; run_wrapper ask -C "$WORK" "what is this"
assert_eq "ask -> rc 0" "$RC" 0
assert_contains "ask -> argv" "$(args_str)" "--search exec -s read-only${RO_POLICY}${PLAT} --color never --skip-git-repo-check --json -o "
assert_not_contains "ask -> no write policy" "$(args_str)" "workspace-write"
assert_not_contains "ask -> no approve-for-me" "$(args_str)" "approve"
assert_eq "ask -> prompt via stdin '-'" "$(tail -n 1 "$FAKE_CODEX_ARGS")" "-"
assert_eq "ask -> stdin content" "$(<"$FAKE_CODEX_STDIN")" "what is this"
assert_contains "ask -> header" "$OUT" "[codex ask] cwd="
assert_contains "ask -> header model default" "$OUT" "model=default"
assert_contains "ask -> session line" "$OUT" "session: fake-thread-1"
assert_contains "ask -> final message" "$OUT" "fake answer"
assert_not_contains "ask -> no trailer" "$OUT" "--- git status after Codex ---"
assert_eq "ask success -> no log left" "$(log_count)" 0

reset_fake; run_wrapper ask -C "$WORK" -m gpt-test --effort high <<'EOF'
line one
line two
EOF
assert_eq "ask heredoc -> rc 0" "$RC" 0
assert_eq "ask heredoc -> stdin content" "$(<"$FAKE_CODEX_STDIN")" $'line one\nline two'   # $(...) strips the trailing newline
assert_contains "ask -m -> argv" "$(args_str)" " -m gpt-test "
assert_contains "ask --effort -> argv" "$(args_str)" ' -c model_reasoning_effort="high" '
assert_contains "ask -m -> header" "$OUT" "model=gpt-test"
}

lane_repo() {   # delegate, failure / log retention, resume, review, platform args, sourced helpers
# ---------------------------------------------------------------- delegate
REPO="$WORK/repo"; rm -rf "$REPO"; mkdir -p "$REPO"
git -C "$REPO" init -q
reset_fake; FAKE_CODEX_TOUCH="$REPO/new.txt" run_wrapper delegate -C "$REPO" "make a file"
assert_eq "delegate -> rc 0" "$RC" 0
assert_contains "delegate -> argv" "$(args_str)" "--search exec --approve-for-me${PLAT} --color never --skip-git-repo-check --json -o "
assert_not_contains "delegate -> no -s (mutually exclusive with --approve-for-me in 0.154.0)" "$(args_str)" " -s "
assert_not_contains "delegate -> no approval_policy=never" "$(args_str)" 'approval_policy="never"'
assert_contains "delegate -> trailer" "$OUT" "--- git status after Codex ---"
assert_contains "delegate -> trailer lists file" "$OUT" "?? new.txt"

NOGIT="$(mktemp -d /tmp/codex-nogit.XXXXXX)"   # outside the skill's own git repo, so rev-parse really fails
reset_fake; run_wrapper delegate -C "$NOGIT" "x"
assert_eq "delegate nogit -> rc 0" "$RC" 0
assert_not_contains "delegate nogit -> no trailer" "$OUT" "--- git status after Codex ---"
rm -rf "$NOGIT"

# ---------------------------------------------------------------- failure / log retention
reset_fake; FAKE_CODEX_RC=3 run_wrapper ask -C "$WORK" "q"
assert_eq "codex failure -> same rc" "$RC" 3
assert_contains "codex failure -> stderr tail shown" "$ERR" "fake error on stderr"
kept="$(sed -n 's/.*events log kept at \(.*\)$/\1/p' <<< "$ERR" | head -n 1)"
[ -n "$kept" ] && [ -f "$kept" ] && ok "codex failure -> log file exists" || fail "codex failure -> log file exists" "path=[$kept]"
assert_contains "codex failure -> partial output shown" "$OUT" "fake answer"
rm -rf "$TMPDIR/codex-run"

reset_fake; CODEX_RUN_KEEP_LOG=1 run_wrapper ask -C "$WORK" "q"
assert_eq "KEEP_LOG success -> rc 0" "$RC" 0
assert_contains "KEEP_LOG -> path printed" "$ERR" "events log kept at "
assert_eq "KEEP_LOG -> one log left" "$(log_count)" 1
rm -rf "$TMPDIR/codex-run"

! grep -q dangerously "$RUN" && ok "wrapper contains no dangerously-* flag" || fail "wrapper contains no dangerously-* flag"

# ---------------------------------------------------------------- resume
UUID_A="aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"   # hex letters, so the case-insensitivity test is not vacuous
UUID_B="99999999-8888-7777-6666-555555555555"

reset_fake; run_wrapper resume -C "$REPO" -- --dangerously-bypass-approvals-and-sandbox "x"
assert_eq "resume -- is unknown option -> rc 1" "$RC" 1
assert_contains "resume -- is unknown option -> message" "$ERR" "unknown option"
[ ! -e "$FAKE_CODEX_ARGS" ] && ok "resume -- -> codex not invoked" || fail "resume -- -> codex not invoked"

reset_fake; run_wrapper resume -C "$REPO" "" "hi"
assert_eq "resume empty SESSION_ID -> rc 1" "$RC" 1
assert_contains "resume empty SESSION_ID -> message" "$ERR" "SESSION_ID must be"

reset_fake; run_wrapper resume -C "$REPO" --last "$UUID_A"
assert_eq "resume --last with UUID positional -> rc 1" "$RC" 1
assert_contains "resume --last with UUID positional -> message" "$ERR" "not both"

reset_fake; run_wrapper resume -C "$REPO" --last "follow up"
assert_eq "resume --last -> rc 0" "$RC" 0
assert_contains "resume --last -> argv" "$(args_str)" "--search exec resume --last --skip-git-repo-check --json -o "
assert_contains "resume default -> read-only policy" "$(args_str)" " -c sandbox_mode=\"read-only\"${RO_POLICY}${PLAT} "
assert_not_contains "resume default -> no auto_review" "$(args_str)" "auto_review"
assert_not_contains "resume -> no --color (unsupported on resume)" "$(args_str)" "--color"
assert_not_contains "resume -> no -s flag" "$(args_str)" " -s "
assert_eq "resume -> stdin content" "$(<"$FAKE_CODEX_STDIN")" "follow up"
assert_not_contains "resume read-only -> no trailer" "$OUT" "--- git status after Codex ---"

reset_fake; FAKE_CODEX_TOUCH="$REPO/resumed.txt" run_wrapper resume -C "$REPO" --last --mode workspace-write "write it"
assert_eq "resume ww -> rc 0" "$RC" 0
assert_contains "resume ww -> replicates --approve-for-me" "$(args_str)" "${WW_POLICY}${PLAT} "
assert_not_contains "resume ww -> no approval_policy=never" "$(args_str)" 'approval_policy="never"'
assert_contains "resume ww -> trailer" "$OUT" "--- git status after Codex ---"
assert_contains "resume ww -> trailer lists file" "$OUT" "?? resumed.txt"

reset_fake; FAKE_CODEX_THREAD="$UUID_A" run_wrapper resume -C "$REPO" "$UUID_A" "hi"
assert_eq "resume matching id -> rc 0" "$RC" 0
assert_contains "resume id -> argv has id" "$(args_str)" "--search exec resume $UUID_A "
assert_contains "resume matching id -> session line" "$OUT" "session: $UUID_A"

reset_fake; FAKE_CODEX_THREAD="$(tr 'a-f' 'A-F' <<< "$UUID_A")" run_wrapper resume -C "$REPO" "$UUID_A" "hi"
assert_eq "resume id case-insensitive match -> rc 0" "$RC" 0

reset_fake; FAKE_CODEX_THREAD="" run_wrapper resume -C "$REPO" "$UUID_A" "hi"
assert_eq "resume explicit id but empty thread id -> no mismatch check, rc 0" "$RC" 0
assert_not_contains "resume empty thread id -> no session line" "$OUT" "session:"
assert_contains "resume empty thread id -> warning on stderr" "$ERR" "could not verify"

reset_fake; FAKE_CODEX_THREAD="$UUID_B" run_wrapper resume -C "$REPO" "$UUID_A" "hi"
assert_eq "resume mismatched id -> rc 1" "$RC" 1
assert_contains "resume mismatch -> message" "$ERR" "session was NOT resumed"
assert_contains "resume mismatch -> log kept" "$ERR" "events log kept at "
assert_not_contains "resume mismatch -> no answer printed" "$OUT" "fake answer"
rm -rf "$TMPDIR/codex-run"

# ---------------------------------------------------------------- review
reset_fake; run_wrapper review -C "$REPO"
assert_eq "review default -> rc 0" "$RC" 0
assert_eq "review default -> argv" "$(args_str)" "--search exec -s read-only --color never review --uncommitted -c sandbox_mode=\"read-only\"${RO_POLICY}${PLAT} "
assert_contains "review -> passthrough output" "$OUT" "fake review output"
assert_eq "review success -> no log left" "$(log_count)" 0

reset_fake; run_wrapper review -C "$REPO" --base main
assert_eq "review --base -> argv" "$(args_str)" "--search exec -s read-only --color never review --base main -c sandbox_mode=\"read-only\"${RO_POLICY}${PLAT} "

reset_fake; run_wrapper review -C "$REPO" --base --uncommitted
assert_eq "review --base leading-dash value -> rc 1" "$RC" 1
assert_contains "review --base leading-dash value -> message" "$ERR" "--base needs a branch"

reset_fake; run_wrapper review -C "$REPO" --commit abc123 -m gpt-test --effort low
assert_eq "review --commit -m --effort -> argv" "$(args_str)" "--search exec -s read-only --color never review --commit abc123 -c sandbox_mode=\"read-only\"${RO_POLICY}${PLAT} -c model_reasoning_effort=\"low\" -m gpt-test "

reset_fake; FAKE_CODEX_RC=2 run_wrapper review -C "$REPO"
assert_eq "review failure -> same rc" "$RC" 2
assert_contains "review failure -> stderr tail" "$ERR" "fake error on stderr"
assert_not_contains "review failure -> no empty log reported" "$ERR" "events log kept at"
rm -rf "$TMPDIR/codex-run"

# ---------------------------------------------------------------- platform sandbox args
n="$( ( source "$RUN"; OSTYPE=linux-gnu; set_platform_args; echo "${#PLATFORM_ARGS[@]}" ) )"
assert_eq "non-Windows -> no platform args" "$n" 0
p="$( ( source "$RUN"; OSTYPE=msys; set_platform_args; printf '%s ' "${PLATFORM_ARGS[@]}" ) )"
assert_eq "Windows (msys) -> unelevated sandbox by default" "$p" '-c windows.sandbox="unelevated" '
p="$( ( source "$RUN"; OSTYPE=cygwin; CODEX_RUN_WINDOWS_SANDBOX=elevated set_platform_args; printf '%s ' "${PLATFORM_ARGS[@]}" ) )"
assert_eq "Windows (cygwin) + CODEX_RUN_WINDOWS_SANDBOX=elevated" "$p" '-c windows.sandbox="elevated" '
( source "$RUN"; OSTYPE=msys; CODEX_RUN_WINDOWS_SANDBOX=disabled set_platform_args ) >/dev/null 2>"$WORK/plat.err"; rc=$?
assert_eq "CODEX_RUN_WINDOWS_SANDBOX=disabled -> rejected" "$rc" 1
assert_contains "CODEX_RUN_WINDOWS_SANDBOX=disabled -> message" "$(<"$WORK/plat.err")" "CODEX_RUN_WINDOWS_SANDBOX"

# ---------------------------------------------------------------- JSON / format helpers (sourced)
jv_of() { ( source "$RUN"; jv "$1" "$2"; printf '%s' "$JV" ); }
assert_eq "jv -> string"                    "$(jv_of '{"a":"x","b":2}' a)" "x"
assert_eq "jv -> number"                    "$(jv_of '{"a":"x","b":2}' b)" "2"
assert_eq "jv -> null"                      "$(jv_of '{"e":null}' e)" "null"
assert_eq "jv -> missing key is empty"      "$(jv_of '{"a":"x"}' zz)" ""
assert_eq "jv -> empty string"              "$(jv_of '{"k":"","z":1}' k)" ""
assert_eq "jv -> escaped quotes unescaped"  "$(jv_of '{"t":"Full \"w\" r","u":1}' t)" 'Full "w" r'
assert_eq "jv -> other escapes kept"        "$(jv_of '{"cwd":"C:\\Users\\x"}' cwd)" 'C:\\Users\\x'
assert_eq "jv -> last occurrence wins"      "$(jv_of '{"timestamp":"a","payload":{"timestamp":"b"}}' timestamp)" "b"
assert_eq "jv -> key must match whole name" "$(jv_of '{"creditId":"c","id":"i"}' id)" "i"
assert_eq "fmt_time @EPOCH -> same as date" "$( ( source "$RUN"; fmt_time @1792599994 ) )" "$(date -d @1792599994 '+%Y-%m-%d %H:%M %z')"
assert_eq "fmt_time ISO -> same as date"    "$( ( source "$RUN"; fmt_time 2026-09-16T10:03:25.926Z ) )" "$(date -d 2026-09-16T10:03:25.926Z '+%Y-%m-%d %H:%M %z')"
assert_eq "fmt_time unparsable -> raw"      "$( ( source "$RUN"; fmt_time nonsense ) )" "nonsense"
assert_eq "print_window -> window, trimmed percent, reset time" \
  "$( ( source "$RUN"; print_window '{"window_minutes":300,"used_percent":19.0,"resets_at":1789568043}' window_minutes used_percent resets_at ) )" \
  "  5h window 19% used (resets $(date -d @1789568043 '+%Y-%m-%d %H:%M %z'))"
}

lane_status() {   # offline status against the fixture CODEX_HOME
# ---------------------------------------------------------------- status
mk_codex_home

reset_fake; run_wrapper status
assert_eq "status -> rc 0" "$RC" 0
assert_eq "status -> last codex call is login status" "$(args_str)" "login status "   # fake overwrites argv per call
assert_contains "status -> header" "$OUT" "[codex status]"
assert_contains "status -> codex version" "$OUT" "codex:   fake-codex 9.9.9"
assert_contains "status -> login" "$OUT" "login: Logged in using Fake"
assert_contains "status -> config model/effort/reviewer from top-level keys" "$OUT" "config:  model=cfg-model  effort=high  approvals_reviewer=auto_review"
assert_not_contains "status -> ignores [projects] section" "$OUT" "not-this-one"
assert_contains "status -> wrapper policy line" "$OUT" "read-only modes: approval_policy=never | delegate: --approve-for-me | web search: on"
assert_contains "status -> limits from newest session overall (B)" "$OUT" "limits:  plan=pro  5h window 77.5% used"
assert_contains "status -> weekly window" "$OUT" "weekly 88% used"
assert_contains "status -> limits source noted" "$OUT" "session $SID_B"
assert_not_contains "status without session -> no session block" "$OUT" "tokens:"

reset_fake; run_wrapper status -C "$REPO" --last
assert_eq "status --last -> rc 0" "$RC" 0
assert_contains "status --last -> newest session in DIR, not overall" "$OUT" "session $SID_A"
assert_not_contains "status --last -> skips other dirs" "$OUT" "$SID_B"
assert_not_contains "status --last -> skips the auto-reviewer's guardian_review thread" "$OUT" "$SID_G"
assert_contains "status --last -> effective model/sandbox/approval" "$OUT" "model=model-a  effort=medium  sandbox=workspace-write  approval=on-request"
assert_contains "status --last -> token totals" "$OUT" "tokens: total 24786 = input 24539 (cached 11776) + output 247   context window 258400"
assert_contains "status --last -> limits from that session" "$OUT" "limits:  plan=plus  5h window 19% used"

reset_fake; run_wrapper status "$SID_G"
assert_contains "status SESSION_ID -> explicit id still finds a guardian_review thread" "$OUT" "session $SID_G"

reset_fake; run_wrapper status "${SID_C^^}"
assert_eq "status SESSION_ID -> rc 0" "$RC" 0
assert_contains "status SESSION_ID (upper case) -> case-insensitive lookup" "$OUT" "session $SID_C"
assert_contains "status SESSION_ID without usage -> says so" "$OUT" "tokens: (no usage recorded)"
assert_contains "status SESSION_ID without usage -> limits fall back to newest overall" "$OUT" "limits:  plan=pro"

reset_fake; run_wrapper status "dddddddd-0000-4000-8000-00000000000d"
assert_eq "status unknown SESSION_ID -> rc 1" "$RC" 1
assert_contains "status unknown SESSION_ID -> message" "$ERR" "session not found"

reset_fake; run_wrapper status not-a-uuid
assert_eq "status non-UUID -> rc 1" "$RC" 1
assert_contains "status non-UUID -> message" "$ERR" "SESSION_ID must be the UUID"

reset_fake; run_wrapper status --last "$SID_A"
assert_eq "status --last + SESSION_ID -> rc 1" "$RC" 1
assert_contains "status --last + SESSION_ID -> message" "$ERR" "not both"

EMPTY="$WORK/empty-dir"; mkdir -p "$EMPTY"
reset_fake; run_wrapper status -C "$EMPTY" --last
assert_eq "status --last with no session for DIR -> rc 1" "$RC" 1
assert_contains "status --last with no session for DIR -> message" "$ERR" "no session found for"

reset_fake; run_wrapper status -m x
assert_eq "status -m -> rc 1" "$RC" 1
assert_contains "status -m -> message" "$ERR" "not valid for status"

reset_fake; CODEX_HOME="$WORK/no-such-home" run_wrapper status
assert_eq "status with no sessions dir -> rc 0" "$RC" 0
assert_contains "status with no sessions dir -> limits unknown" "$OUT" "limits:  (no usage recorded yet)"
assert_contains "status with no config -> defaults" "$OUT" "config:  model=(default)  effort=(default)  approvals_reviewer=(default)"
}

lane_resets() {   # status --resets / --use-reset
# ---------------------------------------------------------------- status --resets / --use-reset (fake app-server)
# Result objects shaped like Codex 0.163.0's account/rateLimits/read. rateLimitsByLimitId holds a decoy bucket
# (1h window, plan=other) that must not leak into the limits line.
mk_codex_home
live_read() { # pct5h pctweek count credits_json
  printf '{"ordinaryUsageAllowed":true,"rateLimits":{"limitId":"codex","limitName":null,"normalModelSlug":null,"primary":{"usedPercent":%s,"windowDurationMins":300,"resetsAt":1792599994},"secondary":{"usedPercent":%s,"windowDurationMins":10080,"resetsAt":1793091641},"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"individualLimit":null,"spendControlReached":false,"planType":"plus","rateLimitReachedType":null},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":1,"windowDurationMins":60,"resetsAt":1},"secondary":null,"planType":"other"}},"rateLimitResetCredits":{"availableCount":%s,"credits":%s},"accountId":"acc","rateLimitUpsell":null}' "$1" "$2" "$3" "$4"
}
credit() { # id expiresAt [title_json_body] [description_json_body]
  printf '{"id":"%s","resetType":"codexRateLimits","status":"available","grantedAt":1790106821,"expiresAt":%s,"title":"%s","description":"%s"}' \
    "$1" "$2" "${3:-Full reset (Weekly + 5 hr)}" "${4:-Thanks for using Codex!}"
}
reset_app() {
  reset_fake; export FAKE_APP_LOG="$WORK/app.$FAKE_N.log"
  unset FAKE_APP_READ FAKE_APP_READ_AFTER FAKE_APP_READ_ERROR FAKE_APP_OUTCOME FAKE_APP_EXIT FAKE_APP_NOISE FAKE_APP_HANG
}
app_log() { [ -f "$FAKE_APP_LOG" ] && printf '%s\n' "$(<"$FAKE_APP_LOG")"; }
TWO_CREDITS="[$(credit RateLimitResetCredit_late 1794002027),$(credit RateLimitResetCredit_early 1792698821)]"

reset_app; export FAKE_APP_READ="$(live_read 98.0 15 2 "$TWO_CREDITS")"; run_wrapper status --resets
assert_eq "status --resets -> rc 0" "$RC" 0
assert_contains "status --resets -> live limits from rateLimits" "$OUT" "limits:  plan=plus  5h window 98% used"
assert_contains "status --resets -> live weekly window" "$OUT" "weekly 15% used"
assert_contains "status --resets -> limits marked live" "$OUT" "live (account/rateLimits/read)"
assert_not_contains "status --resets -> ignores rateLimitsByLimitId buckets" "$OUT" "1h window"
assert_not_contains "status --resets -> no offline limits line" "$OUT" "session $SID_B"
assert_contains "status --resets -> available count" "$OUT" "resets:  2 available"
assert_contains "status --resets -> soonest-expiring credit listed first" "$(grep -A1 '^resets:' <<< "$OUT" | tail -n 1)" "1. Full reset (Weekly + 5 hr)"
assert_contains "status --resets -> first row is the early credit" "$(grep -A1 '^resets:' <<< "$OUT" | tail -n 1)" "RateLimitResetCredit_early"
assert_contains "status --resets -> initialize sent" "$(app_log)" '"method":"initialize"'
assert_not_contains "status --resets -> never consumes" "$(app_log)" "rateLimitResetCredit/consume"

reset_app; export FAKE_APP_READ="$(live_read 98.0 15 2 "$TWO_CREDITS")"; run_wrapper status -C "$REPO" --resets --last
assert_eq "status --resets --last -> rc 0" "$RC" 0
assert_contains "status --resets --last -> session block too" "$OUT" "session $SID_A"

reset_app
export FAKE_APP_READ="$(live_read 98.0 15 2 "$TWO_CREDITS")"
export FAKE_APP_READ_AFTER="$(live_read 0 0 1 "[$(credit RateLimitResetCredit_late 1794002027)]")"
run_wrapper status --use-reset
consume="$(app_log | grep 'rateLimitResetCredit/consume' || true)"
assert_eq "status --use-reset -> rc 0" "$RC" 0
assert_contains "status --use-reset -> consumes the soonest-expiring credit" "$consume" '"creditId":"RateLimitResetCredit_early"'
[[ "$consume" =~ \"idempotencyKey\":\"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\" ]] \
  && ok "status --use-reset -> UUIDv4 idempotency key" || fail "status --use-reset -> UUIDv4 idempotency key" "$consume"
assert_eq "status --use-reset -> exactly one consume call" "$(app_log | grep -c 'rateLimitResetCredit/consume')" 1
assert_contains "status --use-reset -> before state" "$OUT" "resets:  2 available"
assert_contains "status --use-reset -> outcome" "$OUT" "reset:   done, used RateLimitResetCredit_early"
assert_contains "status --use-reset -> after state re-read" "$OUT" "5h window 0% used"
assert_contains "status --use-reset -> remaining count" "$OUT" "resets:  1 available"

reset_app; export FAKE_APP_READ="$(live_read 98.0 15 0 "[]")"; run_wrapper status --use-reset
assert_eq "status --use-reset with no credits -> rc 1" "$RC" 1
assert_contains "status --use-reset with no credits -> message" "$OUT" "reset:   not used, no reset credits available"
assert_not_contains "status --use-reset with no credits -> no consume call" "$(app_log)" "rateLimitResetCredit/consume"

reset_app; export FAKE_APP_READ="$(live_read 98.0 15 2 null)"; run_wrapper status --use-reset
assert_eq "status --use-reset without credit details -> rc 0" "$RC" 0
assert_contains "status --use-reset without credit details -> count still shown" "$OUT" "resets:  2 available (no details returned)"
assert_not_contains "status --use-reset without credit details -> backend picks the credit" "$(app_log)" '"creditId"'

reset_app; export FAKE_APP_READ="$(live_read 3 1 2 "$TWO_CREDITS")" FAKE_APP_OUTCOME=nothingToReset; run_wrapper status --use-reset
assert_eq "status --use-reset nothingToReset -> rc 1" "$RC" 1
assert_contains "status --use-reset nothingToReset -> message" "$OUT" "no current rate-limit window is eligible"

reset_app; export FAKE_APP_READ="$(live_read 98.0 15 2 "$TWO_CREDITS")" FAKE_APP_OUTCOME=weird; run_wrapper status --use-reset
assert_eq "status --use-reset unknown outcome -> rc 1" "$RC" 1
assert_contains "status --use-reset unknown outcome -> message" "$OUT" "unexpected outcome: weird"

reset_app; export FAKE_APP_READ_ERROR="chatgpt authentication required"; run_wrapper status --use-reset
assert_eq "status --use-reset read error -> rc 1" "$RC" 1
assert_contains "status --use-reset read error -> offline limits as fallback" "$OUT" "limits:  plan=pro"
assert_contains "status --use-reset read error -> server message" "$OUT" "resets:  unavailable: chatgpt authentication required"
assert_not_contains "status --use-reset read error -> no consume call" "$(app_log)" "rateLimitResetCredit/consume"

reset_app; export FAKE_APP_EXIT=1; run_wrapper status --resets
assert_eq "status --resets app-server dies -> rc 1" "$RC" 1
assert_contains "status --resets app-server dies -> message" "$OUT" "resets:  unavailable: codex app-server exited"
assert_contains "status --resets app-server dies -> its stderr" "$OUT" "fake app-server crashed"
[ "$(find "$TMPDIR" -maxdepth 1 -name 'codex-run-app.*' | wc -l | tr -d ' ')" = 0 ] \
  && ok "status --resets -> app-server stderr file removed" || fail "status --resets -> app-server stderr file removed"

# Credit picking must not trust a list it cannot fully account for: a "{" inside a string hides that credit
# from the parser, and the backend may cap the list below availableCount. Either way the server picks.
reset_app
export FAKE_APP_READ="$(live_read 98.0 15 2 "[$(credit RateLimitResetCredit_early 1792698821 'Full reset' 'Use {weekly} quota'),$(credit RateLimitResetCredit_late 1794002027)]")"
run_wrapper status --use-reset
assert_eq "status --use-reset with braces in a description -> rc 0" "$RC" 0
assert_not_contains "status --use-reset with braces in a description -> does not pin the later credit" "$(app_log)" '"creditId"'
assert_contains "status --use-reset with braces in a description -> says the server picks" "$OUT" "the server picks which credit to use"

reset_app; export FAKE_APP_READ="$(live_read 98.0 15 3 "[$(credit RateLimitResetCredit_late 1794002027)]")"; run_wrapper status --use-reset
assert_eq "status --use-reset with a capped list -> rc 0" "$RC" 0
assert_contains "status --use-reset with a capped list -> lists what it got" "$OUT" "1. Full reset (Weekly + 5 hr)"
assert_not_contains "status --use-reset with a capped list -> does not pin a listed credit" "$(app_log)" '"creditId"'
assert_contains "status --use-reset with a capped list -> says the server picks" "$OUT" "the server picks which credit to use"
assert_contains "status --use-reset with a capped list -> reports the gap" "$OUT" "1 of 3 listed"

reset_app; export FAKE_APP_READ="$(live_read 98.0 15 1 "[$(credit RateLimitResetCredit_q 1794002027 'Full \"weekly\" reset')]")"; run_wrapper status --resets
assert_contains "status --resets -> escaped quotes in a title are unescaped" "$OUT" '1. Full "weekly" reset  expires'
assert_not_contains "status --resets -> complete list -> no server-picks note" "$OUT" "the server picks"

# A server that keeps sending notifications but never answers must still hit the RPC timeout,
# and one that ignores stdin EOF must not keep the wrapper waiting.
# run_wrapper_capped ARGS... : run_wrapper with a 30s hard stop where `timeout` exists, so a hang fails instead of stalling.
run_wrapper_capped() {
  local o="$WORK/out" e="$WORK/err" cap=()
  command -v timeout >/dev/null 2>&1 && cap=(timeout -k 5 30)
  "${cap[@]}" bash "$RUN" "$@" >"$o" 2>"$e"; RC=$?
  OUT="$(<"$o")"; ERR="$(<"$e")"
}
reset_app; export FAKE_APP_NOISE=1; t0=$SECONDS; CODEX_RUN_RPC_TIMEOUT=2 run_wrapper_capped status --resets; dt=$((SECONDS - t0))
assert_eq "status --resets with endless notifications -> rc 1" "$RC" 1
assert_contains "status --resets with endless notifications -> timeout message" "$OUT" "resets:  unavailable: no reply to account/rateLimits/read within 2s"
[ "$dt" -lt 15 ] && ok "status --resets with endless notifications -> returns (${dt}s)" || fail "status --resets with endless notifications -> returns" "took ${dt}s"

reset_app; export FAKE_APP_HANG=1 FAKE_APP_READ="$(live_read 98.0 15 2 "$TWO_CREDITS")"; t0=$SECONDS; CODEX_RUN_APP_GRACE=1 run_wrapper_capped status --resets; dt=$((SECONDS - t0))
assert_eq "status --resets with a server that ignores EOF -> rc 0" "$RC" 0
assert_contains "status --resets with a server that ignores EOF -> output intact" "$OUT" "resets:  2 available"
[ "$dt" -lt 15 ] && ok "status --resets with a server that ignores EOF -> returns (${dt}s)" || fail "status --resets with a server that ignores EOF -> returns" "took ${dt}s"

reset_app; export FAKE_APP_HANG=term FAKE_APP_READ="$(live_read 98.0 15 2 "$TWO_CREDITS")"; t0=$SECONDS; CODEX_RUN_APP_GRACE=1 run_wrapper_capped status --resets; dt=$((SECONDS - t0))
assert_eq "status --resets with a server that ignores SIGTERM -> rc 0" "$RC" 0
assert_contains "status --resets with a server that ignores SIGTERM -> output intact" "$OUT" "resets:  2 available"
[ "$dt" -lt 15 ] && ok "status --resets with a server that ignores SIGTERM -> returns (${dt}s)" || fail "status --resets with a server that ignores SIGTERM -> returns" "took ${dt}s"

# A "}" inside a string cuts a row short without losing it, so row counts still add up; the row has lost
# expiresAt, so it cannot be ranked and the server must pick.
reset_app
export FAKE_APP_READ="$(live_read 98.0 15 2 '[{"id":"RateLimitResetCredit_early","resetType":"codexRateLimits","status":"available","description":"Use } quota","expiresAt":100,"title":"Early"},{"id":"RateLimitResetCredit_late","resetType":"codexRateLimits","status":"available","expiresAt":200,"title":"Late"}]')"
run_wrapper status --use-reset
assert_eq "status --use-reset with a row cut short -> rc 0" "$RC" 0
assert_not_contains "status --use-reset with a row cut short -> does not pin the later credit" "$(app_log)" '"creditId"'
assert_contains "status --use-reset with a row cut short -> says the server picks" "$OUT" "the server picks which credit to use"

reset_app; export FAKE_APP_READ="$(live_read 98.0 15 2 "$TWO_CREDITS")"; run_wrapper status
assert_not_contains "plain status -> stays offline (no app-server)" "$(app_log)" "initialize"

reset_app; run_wrapper ask --resets "hi"
assert_eq "ask --resets -> rc 1" "$RC" 1
assert_contains "ask --resets -> message" "$ERR" "only valid for status"
reset_app; run_wrapper resume --last --use-reset "hi"
assert_eq "resume --use-reset -> rc 1" "$RC" 1
assert_contains "resume --use-reset -> message" "$ERR" "only valid for status"
reset_app
unset FAKE_APP_LOG
unset CODEX_HOME
}

lane_report() {   # change report after write runs
# ---------------------------------------------------------------- change report / --verify
mk_repo
reset_fake; FAKE_CODEX_EVAL='printf "more\n" >> a.txt; printf "x\ny\n" > new.txt' run_wrapper delegate -C "$REPO" "edit"
assert_eq "report -> rc 0" "$RC" 0
assert_contains "report -> header" "$OUT" "--- codex-run verification ---"
assert_contains "report -> two files touched" "$OUT" "files touched by Codex: 2"
assert_contains "report -> pre-existing change left alone" "$OUT" "left alone: 1"
assert_contains "report -> modified file with numstat" "$OUT" " M a.txt   (+1 -0)"
assert_contains "report -> new file with line count" "$OUT" "?? new.txt   (new file, 2 lines; read it)"
assert_not_contains "report -> pre-existing b.txt not attributed to Codex" "$OUT" "  M b.txt   ("
assert_contains "report -> no warnings" "$OUT" "  (none)"

reset_fake; FAKE_CODEX_EVAL='printf "more\n" >> b.txt' run_wrapper delegate -C "$REPO" "edit"
assert_contains "report -> touching a pre-existing dirty file is flagged" "$OUT" "[had changes before the run"

mk_repo
reset_fake; FAKE_CODEX_EVAL='rm a.txt' run_wrapper delegate -C "$REPO" "edit"
assert_contains "report -> deleted tracked file" "$OUT" "files touched by Codex: 1"
assert_contains "report -> deleted file listed" "$OUT" " D a.txt"

mk_repo
reset_fake; run_wrapper delegate -C "$REPO" "edit"
assert_contains "report -> nothing changed warns" "$OUT" "no files changed"

reset_fake; FAKE_CODEX_MSG="I could not run the tests (sandbox)" run_wrapper delegate -C "$REPO" "edit"
assert_contains "report -> message signal" "$OUT" "message says: I could not run the tests (sandbox)"

reset_fake; FAKE_CODEX_EVAL=': > "$out"' run_wrapper delegate -C "$REPO" "edit"
assert_contains "report -> empty message warns" "$OUT" "final message is empty"

mk_repo
reset_fake; FAKE_CODEX_EVAL='printf "z\n" > c.txt; git add c.txt; git -c user.name=t -c user.email=t@t commit -q -m sneaky' run_wrapper delegate -C "$REPO" "edit"
assert_contains "report -> HEAD moved" "$OUT" "HEAD moved:"
assert_contains "report -> HEAD moved lists commit" "$OUT" "sneaky"
assert_contains "report -> HEAD moved warns" "$OUT" "Codex committed despite"
assert_not_contains "report -> committed work is not 'no files changed'" "$OUT" "no files changed"

mk_repo
reset_fake; FAKE_CODEX_EVAL='printf "a
b
c
" > "한글 파일.txt"; mkdir sub && git -C sub init -q && printf "x
" > sub/f && printf "m
" >> a.txt' run_wrapper delegate -C "$REPO" "edit"
assert_eq "report -> unreadable/odd untracked entries do not break it -> rc 0" "$RC" 0
assert_contains "report -> non-ASCII name shown, not quoted" "$OUT" "한글 파일.txt   (new file, 3 lines; read it)"
assert_contains "report -> numstat still found after odd entries" "$OUT" " M a.txt   (+1 -0)"

mk_repo
reset_fake; FAKE_CODEX_RC=1 FAKE_CODEX_EVAL='printf "half\n" > half.txt' run_wrapper delegate -C "$REPO" "edit"
assert_eq "report on failure -> rc passes through" "$RC" 1
assert_contains "report on failure -> still printed" "$OUT" "?? half.txt"
assert_contains "report on failure -> warns" "$OUT" "Codex exited with status 1"

reset_fake; run_wrapper resume --last -C "$REPO" --mode workspace-write "go"
assert_contains "report -> resume workspace-write" "$OUT" "--- codex-run verification ---"
reset_fake; run_wrapper resume --last -C "$REPO" "go"
assert_not_contains "report -> not for read-only resume" "$OUT" "codex-run verification"
reset_fake; run_wrapper ask -C "$REPO" "q"
assert_not_contains "report -> not for ask" "$OUT" "codex-run verification"

NOGIT="$(mktemp -d /tmp/codex-nogit.XXXXXX)"; printf 'old\n' > "$NOGIT/old.txt"; sleep 1
reset_fake; FAKE_CODEX_EVAL='printf "n\n" > fresh.txt' run_wrapper delegate -C "$NOGIT" "x"
assert_contains "report nogit -> says so" "$OUT" "not a git work tree: files modified since the run started: 1"
assert_contains "report nogit -> lists new file" "$OUT" "  fresh.txt"
assert_not_contains "report nogit -> old file not listed" "$OUT" "old.txt"
assert_eq "report nogit -> marker file cleaned up" "$(find "$TMPDIR/codex-run" -name "marker.*" 2>/dev/null | wc -l | tr -d " ")" 0
rm -rf "$NOGIT"
}

lane_verify() {   # --verify
mk_repo
reset_fake; run_wrapper delegate -C "$REPO" --verify "echo all-green" "edit"
assert_eq "verify pass -> rc 0" "$RC" 0
assert_contains "verify pass -> PASSED" "$OUT" 'verify: PASSED  $ echo all-green'
assert_contains "verify pass -> output shown" "$OUT" "    all-green"
reset_fake; run_wrapper delegate -C "$REPO" --verify "echo boom; exit 3" "edit"
assert_eq "verify fail -> rc 4" "$RC" 4
assert_contains "verify fail -> FAILED with status" "$OUT" "verify: FAILED (exit 3)"
assert_contains "verify fail -> output shown" "$OUT" "    boom"
reset_fake; CODEX_RUN_VERIFY_TIMEOUT=1 run_wrapper delegate -C "$REPO" --verify "sleep 5" "edit"
assert_eq "verify timeout -> rc 4" "$RC" 4
assert_contains "verify timeout -> message" "$OUT" "verify: TIMED OUT after 1s"
reset_fake; FAKE_CODEX_RC=1 run_wrapper delegate -C "$REPO" --verify "true" "edit"
assert_contains "verify skipped when Codex failed" "$OUT" "verify: skipped (Codex failed)"
reset_fake; run_wrapper delegate -C "$REPO" --verify "pwd" "edit"
assert_contains "verify runs in DIR" "$OUT" "report-repo"
reset_fake; run_wrapper ask -C "$REPO" --verify "true" "q"
assert_eq "--verify on ask -> rc 1" "$RC" 1
assert_contains "--verify on ask -> message" "$ERR" "--verify is only valid"
reset_fake; run_wrapper resume --last -C "$REPO" --verify "true" "q"
assert_eq "--verify on read-only resume -> rc 1" "$RC" 1
assert_contains "--verify on read-only resume -> message" "$ERR" "--verify needs resume --mode workspace-write"
reset_fake; run_wrapper delegate -C "$REPO" --verify
assert_eq "--verify without command -> rc 1" "$RC" 1
}

lane_guard() {   # usage guard
# ---------------------------------------------------------------- usage guard
mk_repo; REPO_JSON="$(repo_json)"
UCH="$WORK/usage-home"; rm -rf "$UCH"; mkdir -p "$UCH/sessions/2026/10/01"
SID_U="dddddddd-0000-4000-8000-00000000000d"
FUT='s/1789568043/4102444800/; s/1790088680/4102444800/'   # push both reset times far into the future
mk_rollout "$UCH/sessions/2026/10/01/rollout-2026-10-01T10-00-00-$SID_U.jsonl" "$SID_U" "$REPO_JSON" "m" "read-only" "never" \
  "$(usage_json 10 5 5 1 85.0 40.0 plus | sed "$FUT")"
export CODEX_HOME="$UCH"; export CODEX_RUN_USAGE_LIMIT=80

reset_fake; run_wrapper delegate -C "$REPO" "edit"
assert_eq "guard: delegate at 85% -> rc 3" "$RC" 3
assert_contains "guard: names the window" "$ERR" "5h window 85% used"
assert_contains "guard: says nothing started" "$ERR" "nothing was started"
assert_contains "guard: points to --ignore-usage" "$ERR" "--ignore-usage"
[ ! -e "$FAKE_CODEX_ARGS" ] && ok "guard: codex not invoked" || fail "guard: codex not invoked"
reset_fake; run_wrapper resume --last -C "$REPO" --mode workspace-write "go"
assert_eq "guard: resume workspace-write -> rc 3" "$RC" 3
reset_fake; run_wrapper ask -C "$REPO" --effort high "q"
assert_eq "guard: ask --effort high -> rc 3" "$RC" 3
reset_fake; run_wrapper review -C "$REPO" --effort max
assert_eq "guard: review --effort max -> rc 3" "$RC" 3
reset_fake; run_wrapper ask -C "$REPO" "q"
assert_eq "guard: plain ask passes" "$RC" 0
reset_fake; run_wrapper ask -C "$REPO" --effort medium "q"
assert_eq "guard: ask --effort medium passes" "$RC" 0
reset_fake; run_wrapper resume --last -C "$REPO" "q"
assert_eq "guard: read-only resume passes" "$RC" 0
reset_fake; run_wrapper delegate -C "$REPO" --ignore-usage "edit"
assert_eq "guard: --ignore-usage passes" "$RC" 0
reset_fake; CODEX_RUN_USAGE_LIMIT=90 run_wrapper delegate -C "$REPO" "edit"
assert_eq "guard: limit above reading passes" "$RC" 0
reset_fake; CODEX_RUN_USAGE_LIMIT=85 run_wrapper delegate -C "$REPO" "edit"
assert_eq "guard: limit equal to reading blocks" "$RC" 3
reset_fake; CODEX_RUN_USAGE_LIMIT=off run_wrapper delegate -C "$REPO" "edit"
assert_eq "guard: limit off passes" "$RC" 0
reset_fake; CODEX_RUN_USAGE_LIMIT=lots run_wrapper delegate -C "$REPO" "edit"
assert_eq "guard: bad limit -> rc 1" "$RC" 1
assert_contains "guard: bad limit -> message" "$ERR" "CODEX_RUN_USAGE_LIMIT must be"
reset_fake; run_wrapper status
assert_eq "guard: status unaffected" "$RC" 0
reset_fake; run_wrapper status --ignore-usage
assert_eq "--ignore-usage on status -> rc 1" "$RC" 1

# the weekly window alone can trip it, and the worse one is named
mk_rollout "$UCH/sessions/2026/10/01/rollout-2026-10-01T10-00-00-$SID_U.jsonl" "$SID_U" "$REPO_JSON" "m" "read-only" "never" \
  "$(usage_json 10 5 5 1 20.0 95.0 plus | sed "$FUT")"
reset_fake; run_wrapper delegate -C "$REPO" "edit"
assert_eq "guard: weekly window trips it" "$RC" 3
assert_contains "guard: weekly window named" "$ERR" "weekly 95% used"

# a missing window (null) must not abort the guard silently
mk_rollout "$UCH/sessions/2026/10/01/rollout-2026-10-01T10-00-00-$SID_U.jsonl" "$SID_U" "$REPO_JSON" "m" "read-only" "never"   "$(usage_json 10 5 5 1 90.0 40.0 plus | sed "$FUT; s/\"secondary\":{[^}]*}/\"secondary\":null/")"
reset_fake; run_wrapper delegate -C "$REPO" "edit"
assert_eq "guard: null secondary window still reports -> rc 3" "$RC" 3
assert_contains "guard: null secondary -> message" "$ERR" "5h window 90% used"

# a window whose reset time has passed is stale and ignored (fixture reset times are in the past)
mk_rollout "$UCH/sessions/2026/10/01/rollout-2026-10-01T10-00-00-$SID_U.jsonl" "$SID_U" "$REPO_JSON" "m" "read-only" "never" \
  "$(usage_json 10 5 5 1 99.0 99.0 plus)"
reset_fake; run_wrapper delegate -C "$REPO" "edit"
assert_eq "guard: reading whose windows already reset passes" "$RC" 0

rm -rf "$UCH/sessions"
reset_fake; run_wrapper delegate -C "$REPO" "edit"
assert_eq "guard: no recorded usage passes" "$RC" 0
unset CODEX_HOME; export CODEX_RUN_USAGE_LIMIT=off
}

# ---------------------------------------------------------------- run the lanes
LANES=(lane_basic lane_repo lane_status lane_resets lane_report lane_verify lane_guard)
run_lane() {   # NAME : output to .work/NAME.out, "PASS FAIL" to .work/NAME.count
  ( lane_setup "$1"; "$1"; echo "$PASS $FAIL" > "$WORK_ROOT/$1.count" ) > "$WORK_ROOT/$1.out" 2>&1
}
if [ "${CODEX_TEST_SERIAL:-0}" = 1 ]; then
  for lane in "${LANES[@]}"; do run_lane "$lane"; done
else
  for lane in "${LANES[@]}"; do run_lane "$lane" & done
  wait
fi
for lane in "${LANES[@]}"; do
  echo "# $lane"
  printf '%s\n' "$(<"$WORK_ROOT/$lane.out")"
  if [ -f "$WORK_ROOT/$lane.count" ] && read -r p f < "$WORK_ROOT/$lane.count"; then
    PASS=$((PASS + p)); FAIL=$((FAIL + f))
  else
    fail "$lane finished" "the lane aborted before its last test; see its output above"
  fi
done

# ---------------------------------------------------------------- SKILL.md
SKILL="$HERE/../skills/codex/SKILL.md"
assert_eq "SKILL.md frontmatter opens" "$(head -n 1 "$SKILL" 2>/dev/null)" "---"
assert_contains "SKILL.md name" "$(head -n 5 "$SKILL" 2>/dev/null)" "name: codex"
assert_contains "SKILL.md calls the wrapper via CLAUDE_SKILL_DIR" "$(cat "$SKILL")" '"${CLAUDE_SKILL_DIR}/scripts/codex-run.sh"'
assert_not_contains "SKILL.md has no hard-coded install path" "$(cat "$SKILL")" "~/.claude/skills"

# ---------------------------------------------------------------- plugin manifests
PLUGIN_JSON="$(cat "$HERE/../.claude-plugin/plugin.json" 2>/dev/null)"
MARKET_JSON="$(cat "$HERE/../.claude-plugin/marketplace.json" 2>/dev/null)"
assert_contains "plugin.json name" "$PLUGIN_JSON" '"name": "codex"'
assert_contains "plugin.json skills dir" "$PLUGIN_JSON" '"skills": "./skills/"'
assert_contains "marketplace.json lists the plugin" "$MARKET_JSON" '"name": "codex"'
assert_contains "marketplace.json source is the repo root" "$MARKET_JSON" '"source": "./"'

# ---------------------------------------------------------------- summary
echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
