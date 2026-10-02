#!/usr/bin/env bash
# Unit tests for scripts/codex-run.sh. No network: a fake `codex` is put on PATH.
# Run: bash tests/test-unit.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="$HERE/../scripts/codex-run.sh"
WORK="$HERE/.work"
rm -rf "$WORK"; mkdir -p "$WORK/bin" "$WORK/tmp"
cp "$HERE/fake-codex" "$WORK/bin/codex"; chmod +x "$WORK/bin/codex"
export PATH="$WORK/bin:$PATH"
export TMPDIR="$WORK/tmp"
export FAKE_CODEX_ARGS="$WORK/args"
export FAKE_CODEX_STDIN="$WORK/stdin"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL - $1"; [ -n "${2:-}" ] && echo "       $2"; }
assert_eq()           { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected [$3] got [$2]"; fi; }
assert_contains()     { case "$2" in *"$3"*) ok "$1";; *) fail "$1" "missing [$3] in: $2";; esac; }
assert_not_contains() { case "$2" in *"$3"*) fail "$1" "unexpected [$3] in: $2";; *) ok "$1";; esac; }
has_arg()  { grep -qx -- "$1" "$FAKE_CODEX_ARGS"; }
args_str() { tr '\n' ' ' < "$FAKE_CODEX_ARGS" 2>/dev/null; }
reset_fake() {
  rm -f "$FAKE_CODEX_ARGS" "$FAKE_CODEX_STDIN"
  unset FAKE_CODEX_THREAD FAKE_CODEX_MSG FAKE_CODEX_RC FAKE_CODEX_TOUCH CODEX_RUN_KEEP_LOG
}
# run_wrapper ARGS... : runs the wrapper; sets RC, OUT (stdout), ERR (stderr). stdin is inherited.
run_wrapper() {
  local o="$WORK/out" e="$WORK/err"
  bash "$RUN" "$@" >"$o" 2>"$e"; RC=$?
  OUT="$(cat "$o")"; ERR="$(cat "$e")"
}
log_count() { find "$TMPDIR/codex-run" -type f 2>/dev/null | wc -l | tr -d ' '; }
# Platform-specific argv the wrapper adds (Windows needs Codex's Windows sandbox backend enabled).
case "${OSTYPE:-}" in msys*|cygwin*) PLAT=' -c windows.sandbox="unelevated"';; *) PLAT='';; esac
RO_POLICY=' -c approval_policy="never"'
WW_POLICY=' -c sandbox_mode="workspace-write" -c approval_policy="on-request" -c approvals_reviewer="auto_review"'

# ---------------------------------------------------------------- shim sanity
reset_fake
echo "hello" | FAKE_CODEX_THREAD=t-1 codex exec --json -o "$WORK/o1" - >"$WORK/shim.out"
assert_eq "shim records argv" "$(args_str)" "exec --json -o $WORK/o1 - "
assert_eq "shim captures stdin" "$(cat "$FAKE_CODEX_STDIN")" "hello"
assert_eq "shim writes -o file" "$(cat "$WORK/o1")" "fake answer"
assert_contains "shim emits thread.started" "$(cat "$WORK/shim.out")" '{"type":"thread.started","thread_id":"t-1"}'

# ---------------------------------------------------------------- usage validation (no codex call)
reset_fake; run_wrapper
assert_eq "no args -> rc 1" "$RC" 1
assert_contains "no args -> usage on stderr" "$ERR" "Usage:"
[ ! -e "$FAKE_CODEX_ARGS" ] && ok "no args -> codex not invoked" || fail "no args -> codex not invoked"

reset_fake; run_wrapper frobnicate "hi"
assert_eq "unknown mode -> rc 1" "$RC" 1
assert_contains "unknown mode -> message" "$ERR" "unknown mode"

reset_fake; run_wrapper --help
assert_eq "--help -> rc 0" "$RC" 0
assert_contains "--help -> usage on stdout" "$OUT" "Usage:"

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

reset_fake; run_wrapper ask -C "$WORK" -- "x"
assert_eq "ask -- is unknown option -> rc 1" "$RC" 1
assert_contains "ask -- is unknown option -> message" "$ERR" "unknown option"

reset_fake; run_wrapper ask -C "$WORK" -m --dangerously-bypass-approvals-and-sandbox "x"
assert_eq "ask -m leading-dash value -> rc 1" "$RC" 1
assert_contains "ask -m leading-dash value -> message" "$ERR" "-m needs a model"
[ ! -e "$FAKE_CODEX_ARGS" ] && ok "ask -m leading-dash value -> codex not invoked" || fail "ask -m leading-dash value -> codex not invoked"

# TTY guard: source the script and stub stdin_is_tty
( source "$RUN"; stdin_is_tty() { return 0; }; resolve_prompt "" ) </dev/null >/dev/null 2>"$WORK/tty.err"; rc=$?
assert_eq "TTY + no PROMPT -> rc 1" "$rc" 1
assert_contains "TTY + no PROMPT -> message" "$(cat "$WORK/tty.err")" "stdin is a terminal"
p="$( ( source "$RUN"; stdin_is_tty() { return 1; }; resolve_prompt "" && printf '%s' "$PROMPT" ) <<< "from pipe" )"
assert_eq "piped + no PROMPT -> reads stdin" "$p" "from pipe"   # $(...) strips the trailing newline
p="$( ( source "$RUN"; stdin_is_tty() { return 0; }; resolve_prompt "given" && printf '%s' "$PROMPT" ) )"
assert_eq "PROMPT arg wins" "$p" "given"
p="$( ( source "$RUN"; stdin_is_tty() { return 0; }; resolve_prompt "-" && printf '%s' "$PROMPT" ) <<< "dash" )"
assert_eq "PROMPT '-' reads stdin even on TTY" "$p" "dash"

# extract_thread_id
printf '{"type":"thread.started","thread_id":"019d-abc"}\n{"type":"item.completed"}\n' > "$WORK/ev.jsonl"
t="$( ( source "$RUN"; extract_thread_id "$WORK/ev.jsonl" ) )"
assert_eq "extract_thread_id" "$t" "019d-abc"
t="$( ( source "$RUN"; extract_thread_id "$WORK/does-not-exist" ) )"
assert_eq "extract_thread_id missing file -> empty" "$t" ""
printf '{"type":"item.completed"}\n' > "$WORK/ev-none.jsonl"
t="$( ( set -euo pipefail; source "$RUN"; extract_thread_id "$WORK/ev-none.jsonl"; echo "still-alive" ) )"
assert_eq "extract_thread_id no thread.started under pipefail -> empty, no abort" "$t" "still-alive"

# ---------------------------------------------------------------- ask
reset_fake; run_wrapper ask -C "$WORK" "what is this"
assert_eq "ask -> rc 0" "$RC" 0
assert_contains "ask -> argv" "$(args_str)" "exec -s read-only${RO_POLICY}${PLAT} --color never --skip-git-repo-check --json -o "
assert_not_contains "ask -> no write policy" "$(args_str)" "workspace-write"
assert_not_contains "ask -> no approve-for-me" "$(args_str)" "approve"
assert_eq "ask -> prompt via stdin '-'" "$(tail -n 1 "$FAKE_CODEX_ARGS")" "-"
assert_eq "ask -> stdin content" "$(cat "$FAKE_CODEX_STDIN")" "what is this"
assert_contains "ask -> header" "$OUT" "[codex ask] cwd="
assert_contains "ask -> header model default" "$OUT" "model=default"
assert_contains "ask -> session line" "$OUT" "session: fake-thread-1"
assert_contains "ask -> final message" "$OUT" "fake answer"
assert_not_contains "ask -> no trailer" "$OUT" "--- git status after Codex ---"
assert_eq "ask success -> no log left" "$(log_count)" 0

reset_fake; run_wrapper ask -C "$WORK" <<'EOF'
line one
line two
EOF
assert_eq "ask heredoc -> rc 0" "$RC" 0
assert_eq "ask heredoc -> stdin content" "$(cat "$FAKE_CODEX_STDIN")" $'line one\nline two'   # $(...) strips the trailing newline

reset_fake; run_wrapper ask -C "$WORK" -m gpt-test --effort high "q"
assert_contains "ask -m -> argv" "$(args_str)" " -m gpt-test "
assert_contains "ask --effort -> argv" "$(args_str)" ' -c model_reasoning_effort="high" '
assert_contains "ask -m -> header" "$OUT" "model=gpt-test"

reset_fake; FAKE_CODEX_THREAD="" run_wrapper ask -C "$WORK" "q"
assert_eq "ask empty thread id -> rc 0" "$RC" 0
assert_not_contains "ask empty thread id -> no session line" "$OUT" "session:"

# ---------------------------------------------------------------- delegate
REPO="$WORK/repo"; rm -rf "$REPO"; mkdir -p "$REPO"
git -C "$REPO" init -q && git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
reset_fake; FAKE_CODEX_TOUCH="$REPO/new.txt" run_wrapper delegate -C "$REPO" "make a file"
assert_eq "delegate -> rc 0" "$RC" 0
assert_contains "delegate -> argv" "$(args_str)" "exec --approve-for-me${PLAT} --color never --skip-git-repo-check --json -o "
assert_not_contains "delegate -> no -s (mutually exclusive with --approve-for-me in 0.154.0)" "$(args_str)" " -s "
assert_not_contains "delegate -> no approval_policy=never" "$(args_str)" 'approval_policy="never"'
assert_contains "delegate -> header" "$OUT" "[codex delegate] cwd="
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
assert_contains "codex failure -> log kept message" "$ERR" "events log kept at "
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
[ ! -e "$FAKE_CODEX_ARGS" ] && ok "resume -- -> codex not invoked" || fail "resume -- -> codex not invoked"

reset_fake; run_wrapper resume -C "$REPO" "" "hi"
assert_eq "resume empty SESSION_ID -> rc 1" "$RC" 1
assert_contains "resume empty SESSION_ID -> message" "$ERR" "SESSION_ID must be"

reset_fake; run_wrapper resume -C "$REPO" "my-thread-name" "hi"
assert_eq "resume thread name is not a valid SESSION_ID -> rc 1" "$RC" 1
assert_contains "resume thread name -> message" "$ERR" "SESSION_ID must be"

reset_fake; run_wrapper resume -C "$REPO" --last "$UUID_A"
assert_eq "resume --last with UUID positional -> rc 1" "$RC" 1
assert_contains "resume --last with UUID positional -> message" "$ERR" "not both"

reset_fake; run_wrapper resume -C "$REPO" --last "follow up"
assert_eq "resume --last -> rc 0" "$RC" 0
assert_contains "resume --last -> argv" "$(args_str)" "exec resume --last --skip-git-repo-check --json -o "
assert_contains "resume default -> sandbox read-only" "$(args_str)" ' -c sandbox_mode="read-only" '
assert_contains "resume default -> read-only policy" "$(args_str)" " -c sandbox_mode=\"read-only\"${RO_POLICY}${PLAT} "
assert_not_contains "resume default -> no auto_review" "$(args_str)" "auto_review"
assert_not_contains "resume -> no --color (unsupported on resume)" "$(args_str)" "--color"
assert_not_contains "resume -> no -s flag" "$(args_str)" " -s "
assert_eq "resume -> stdin content" "$(cat "$FAKE_CODEX_STDIN")" "follow up"
assert_not_contains "resume read-only -> no trailer" "$OUT" "--- git status after Codex ---"
assert_contains "resume -> header" "$OUT" "[codex resume] cwd="

reset_fake; FAKE_CODEX_TOUCH="$REPO/resumed.txt" run_wrapper resume -C "$REPO" --last --mode workspace-write "write it"
assert_eq "resume ww -> rc 0" "$RC" 0
assert_contains "resume ww -> sandbox workspace-write" "$(args_str)" ' -c sandbox_mode="workspace-write" '
assert_contains "resume ww -> replicates --approve-for-me" "$(args_str)" "${WW_POLICY}${PLAT} "
assert_not_contains "resume ww -> no approval_policy=never" "$(args_str)" 'approval_policy="never"'
assert_contains "resume ww -> trailer" "$OUT" "--- git status after Codex ---"
assert_contains "resume ww -> trailer lists file" "$OUT" "?? resumed.txt"

reset_fake; FAKE_CODEX_THREAD="$UUID_A" run_wrapper resume -C "$REPO" "$UUID_A" "hi"
assert_eq "resume matching id -> rc 0" "$RC" 0
assert_contains "resume id -> argv has id" "$(args_str)" "exec resume $UUID_A "
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

reset_fake; FAKE_CODEX_THREAD="$UUID_B" run_wrapper resume -C "$REPO" --last "hi"
assert_eq "resume --last -> no mismatch check" "$RC" 0

# ---------------------------------------------------------------- review
reset_fake; run_wrapper review -C "$REPO"
assert_eq "review default -> rc 0" "$RC" 0
assert_eq "review default -> argv" "$(args_str)" "exec -s read-only --color never review --uncommitted -c sandbox_mode=\"read-only\"${RO_POLICY}${PLAT} "
assert_contains "review -> header" "$OUT" "[codex review] cwd="
assert_contains "review -> passthrough output" "$OUT" "fake review output"
assert_not_contains "review -> no --json" "$(args_str)" "--json"
assert_eq "review success -> no log left" "$(log_count)" 0

reset_fake; run_wrapper review -C "$REPO" --base main
assert_eq "review --base -> argv" "$(args_str)" "exec -s read-only --color never review --base main -c sandbox_mode=\"read-only\"${RO_POLICY}${PLAT} "

reset_fake; run_wrapper review -C "$REPO" --base --uncommitted
assert_eq "review --base leading-dash value -> rc 1" "$RC" 1
assert_contains "review --base leading-dash value -> message" "$ERR" "--base needs a branch"

reset_fake; run_wrapper review -C "$REPO" --commit abc123 -m gpt-test --effort low
assert_eq "review --commit -m --effort -> argv" "$(args_str)" "exec -s read-only --color never review --commit abc123 -c sandbox_mode=\"read-only\"${RO_POLICY}${PLAT} -c model_reasoning_effort=\"low\" -m gpt-test "

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
assert_contains "CODEX_RUN_WINDOWS_SANDBOX=disabled -> message" "$(cat "$WORK/plat.err")" "CODEX_RUN_WINDOWS_SANDBOX"

# ---------------------------------------------------------------- status
# Fixture CODEX_HOME shaped like the real one (Codex 0.154.0 rollout files): session_meta on line 1,
# a turn_context line, and (for sessions that completed a turn) a token_count event with rate limits.
CH="$WORK/codex-home"; rm -rf "$CH"; mkdir -p "$CH/sessions/2026/09/15" "$CH/sessions/2026/09/16"
printf '%s\n' 'model = "cfg-model"' 'model_reasoning_effort = "high"' 'approvals_reviewer = "auto_review"' \
  '[projects."x"]' 'model = "not-this-one"' > "$CH/config.toml"
SID_A="aaaaaaaa-0000-4000-8000-00000000000a"   # in REPO, has usage, newest in REPO
SID_B="bbbbbbbb-0000-4000-8000-00000000000b"   # elsewhere, has usage, newest overall
SID_C="cccccccc-0000-4000-8000-00000000000c"   # in REPO, failed before any usage
REPO_JSON="$(cd "$REPO" && (pwd -W 2>/dev/null || pwd) | sed 's#/#\\\\#g')"   # C:\\Users\\... as in the JSON
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
mk_rollout "$CH/sessions/2026/09/15/rollout-2026-09-15T09-00-00-$SID_C.jsonl" "$SID_C" "$REPO_JSON" "bad-model" "read-only" "never"
mk_rollout "$CH/sessions/2026/09/16/rollout-2026-09-16T10-00-00-$SID_A.jsonl" "$SID_A" "$REPO_JSON" "model-a" "workspace-write" "on-request" \
  "$(usage_json 24786 24539 11776 247 19.0 34.0 plus)"
mk_rollout "$CH/sessions/2026/09/16/rollout-2026-09-16T11-00-00-$SID_B.jsonl" "$SID_B" 'D:\\elsewhere' "model-b" "read-only" "never" \
  "$(usage_json 500 400 0 100 77.5 88.0 pro)"
MK_SOURCE=guardian_review mk_rollout "$CH/sessions/2026/09/16/rollout-2026-09-16T10-30-00-$SID_G.jsonl" "$SID_G" "$REPO_JSON" "codex-auto-review" "read-only" "never"
export CODEX_HOME="$CH"

reset_fake; run_wrapper status
assert_eq "status -> rc 0" "$RC" 0
assert_eq "status -> codex only asked for version/login" "$(args_str)" "login status "
assert_contains "status -> header" "$OUT" "[codex status]"
assert_contains "status -> codex version" "$OUT" "codex:   fake-codex 9.9.9"
assert_contains "status -> login" "$OUT" "login: Logged in using Fake"
assert_contains "status -> config model/effort/reviewer from top-level keys" "$OUT" "config:  model=cfg-model  effort=high  approvals_reviewer=auto_review"
assert_not_contains "status -> ignores [projects] section" "$OUT" "not-this-one"
assert_contains "status -> wrapper policy line" "$OUT" "read-only modes: approval_policy=never | delegate: --approve-for-me"
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

reset_fake; run_wrapper status "$SID_C"
assert_eq "status SESSION_ID -> rc 0" "$RC" 0
assert_contains "status SESSION_ID -> session block" "$OUT" "session $SID_C"
assert_contains "status SESSION_ID without usage -> says so" "$OUT" "tokens: (no usage recorded)"
assert_contains "status SESSION_ID without usage -> limits fall back to newest overall" "$OUT" "limits:  plan=pro"

reset_fake; run_wrapper status "${SID_A^^}"
assert_contains "status SESSION_ID -> case-insensitive lookup" "$OUT" "session $SID_A"

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
unset CODEX_HOME

# ---------------------------------------------------------------- SKILL.md
SKILL="$HERE/../SKILL.md"
[ -f "$SKILL" ] && ok "SKILL.md exists" || fail "SKILL.md exists"
assert_eq "SKILL.md frontmatter opens" "$(head -n 1 "$SKILL" 2>/dev/null)" "---"
assert_contains "SKILL.md name" "$(head -n 5 "$SKILL" 2>/dev/null)" "name: codex"
for trig in "codex" "코덱스" "codex 리뷰" "codex한테 시켜" "코덱스한테도 물어봐" "Codex second opinion"; do
  assert_contains "SKILL.md trigger: $trig" "$(head -n 4 "$SKILL" 2>/dev/null)" "$trig"   # description is line 3
done
assert_contains "SKILL.md mentions git diff rule" "$(cat "$SKILL" 2>/dev/null)" "git diff"
assert_contains "SKILL.md mentions background run" "$(cat "$SKILL" 2>/dev/null)" "run_in_background: true"
assert_contains "SKILL.md mentions timeout" "$(cat "$SKILL" 2>/dev/null)" "7200000"
assert_contains "SKILL.md mentions resume default read-only" "$(cat "$SKILL" 2>/dev/null)" "--mode workspace-write"
assert_contains "SKILL.md documents status mode" "$(cat "$SKILL" 2>/dev/null)" '`status`'
[ -f "$HERE/../DESIGN.md" ] && ok "DESIGN.md exists" || fail "DESIGN.md exists"

# ---------------------------------------------------------------- summary
echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
