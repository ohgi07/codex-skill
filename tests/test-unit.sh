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

reset_fake; run_wrapper review --base x --commit y
assert_eq "review two targets -> rc 1" "$RC" 1
assert_contains "review two targets -> message" "$ERR" "only one of"

reset_fake; run_wrapper review "please review"
assert_eq "review with PROMPT -> rc 1" "$RC" 1
assert_contains "review with PROMPT -> points to ask" "$ERR" "use 'ask'"

reset_fake; run_wrapper resume "hi" </dev/null
assert_eq "resume with no --last and non-uuid single arg is treated as SESSION_ID" "$RC" 1
assert_contains "resume single arg -> empty prompt error" "$ERR" "prompt is empty"

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

reset_fake; : | run_wrapper ask
assert_eq "ask empty stdin -> rc 1" "$RC" 1
assert_contains "ask empty stdin -> message" "$ERR" "prompt is empty"

reset_fake; printf '  \n\t\n' | run_wrapper ask
assert_eq "ask whitespace stdin -> rc 1" "$RC" 1

reset_fake; run_wrapper ask "a" "b"
assert_eq "ask two positionals -> rc 1" "$RC" 1

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

# ---------------------------------------------------------------- summary
echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
