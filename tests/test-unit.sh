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

reset_fake; run_wrapper ask </dev/null          # redirect, not a pipe: a pipe would subshell run_wrapper and lose RC/ERR
assert_eq "ask empty stdin -> rc 1" "$RC" 1
assert_contains "ask empty stdin -> message" "$ERR" "prompt is empty"

reset_fake; run_wrapper ask <<< $'  \n\t'
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
printf '{"type":"item.completed"}\n' > "$WORK/ev-none.jsonl"
t="$( ( set -euo pipefail; source "$RUN"; extract_thread_id "$WORK/ev-none.jsonl"; echo "still-alive" ) )"
assert_eq "extract_thread_id no thread.started under pipefail -> empty, no abort" "$t" "still-alive"

# ---------------------------------------------------------------- ask
reset_fake; run_wrapper ask -C "$WORK" "what is this"
assert_eq "ask -> rc 0" "$RC" 0
assert_contains "ask -> argv" "$(args_str)" "exec -s read-only --color never --skip-git-repo-check --json -o "
assert_eq "ask -> prompt via stdin '-'" "$(tail -n 1 "$FAKE_CODEX_ARGS")" "-"
assert_eq "ask -> stdin content" "$(cat "$FAKE_CODEX_STDIN")" "what is this"
assert_contains "ask -> header" "$OUT" "[codex ask] cwd="
assert_contains "ask -> header model default" "$OUT" "model=default"
assert_contains "ask -> session line" "$OUT" "session: fake-thread-1"
assert_contains "ask -> final message" "$OUT" "fake answer"
assert_not_contains "ask -> no trailer" "$OUT" "--- git status after Codex ---"
assert_not_contains "ask -> never workspace-write" "$(args_str)" "workspace-write"
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
assert_contains "delegate -> argv" "$(args_str)" "exec -s workspace-write --approve-for-me --color never --skip-git-repo-check --json -o "
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

reset_fake; run_wrapper resume -C "$REPO" --last "follow up"
assert_eq "resume --last -> rc 0" "$RC" 0
assert_contains "resume --last -> argv" "$(args_str)" "exec resume --last --skip-git-repo-check --json -o "
assert_contains "resume default -> sandbox read-only" "$(args_str)" ' -c sandbox_mode="read-only" '
assert_not_contains "resume -> no --color (unsupported on resume)" "$(args_str)" "--color"
assert_not_contains "resume -> no -s flag" "$(args_str)" " -s "
assert_eq "resume -> stdin content" "$(cat "$FAKE_CODEX_STDIN")" "follow up"
assert_not_contains "resume read-only -> no trailer" "$OUT" "--- git status after Codex ---"
assert_contains "resume -> header" "$OUT" "[codex resume] cwd="

reset_fake; FAKE_CODEX_TOUCH="$REPO/resumed.txt" run_wrapper resume -C "$REPO" --last --mode workspace-write "write it"
assert_eq "resume ww -> rc 0" "$RC" 0
assert_contains "resume ww -> sandbox workspace-write" "$(args_str)" ' -c sandbox_mode="workspace-write" '
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

reset_fake; FAKE_CODEX_THREAD="$UUID_B" run_wrapper resume -C "$REPO" "$UUID_A" "hi"
assert_eq "resume mismatched id -> rc 1" "$RC" 1
assert_contains "resume mismatch -> message" "$ERR" "session was NOT resumed"
assert_contains "resume mismatch -> log kept" "$ERR" "events log kept at "
assert_not_contains "resume mismatch -> no answer printed" "$OUT" "fake answer"
rm -rf "$TMPDIR/codex-run"

reset_fake; FAKE_CODEX_THREAD="$UUID_B" run_wrapper resume -C "$REPO" "my-thread-name" "hi"
assert_eq "resume by thread name -> no mismatch check, rc 0" "$RC" 0

reset_fake; FAKE_CODEX_THREAD="$UUID_B" run_wrapper resume -C "$REPO" --last "hi"
assert_eq "resume --last -> no mismatch check" "$RC" 0

# ---------------------------------------------------------------- review
reset_fake; run_wrapper review -C "$REPO"
assert_eq "review default -> rc 0" "$RC" 0
assert_eq "review default -> argv" "$(args_str)" 'exec -s read-only --color never review --uncommitted -c sandbox_mode="read-only" '
assert_contains "review -> header" "$OUT" "[codex review] cwd="
assert_contains "review -> passthrough output" "$OUT" "fake review output"
assert_not_contains "review -> no --json" "$(args_str)" "--json"
assert_eq "review success -> no log left" "$(log_count)" 0

reset_fake; run_wrapper review -C "$REPO" --base main
assert_eq "review --base -> argv" "$(args_str)" 'exec -s read-only --color never review --base main -c sandbox_mode="read-only" '

reset_fake; run_wrapper review -C "$REPO" --commit abc123 -m gpt-test --effort low
assert_eq "review --commit -m --effort -> argv" "$(args_str)" 'exec -s read-only --color never review --commit abc123 -c sandbox_mode="read-only" -c model_reasoning_effort="low" -m gpt-test '

reset_fake; FAKE_CODEX_RC=2 run_wrapper review -C "$REPO"
assert_eq "review failure -> same rc" "$RC" 2
assert_contains "review failure -> stderr tail" "$ERR" "fake error on stderr"
rm -rf "$TMPDIR/codex-run"

# ---------------------------------------------------------------- summary
echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
