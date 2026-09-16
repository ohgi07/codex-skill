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

# ---------------------------------------------------------------- summary
echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
