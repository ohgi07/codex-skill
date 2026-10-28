#!/usr/bin/env bash
# End-to-end smoke test: calls the REAL Codex CLI (costs API usage). Run on demand:
#   bash tests/test-smoke.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="$HERE/../skills/codex/scripts/codex-run.sh"
export TMPDIR="${TMPDIR:-$HERE/.work/smoke-tmp}"; mkdir -p "$TMPDIR"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL - $1"; [ -n "${2:-}" ] && echo "       $2"; }
assert_contains() { case "$2" in *"$3"*) ok "$1";; *) fail "$1" "missing [$3] in: ${2:0:400}";; esac; }
run_wrapper() { local o="$TMPDIR/out" e="$TMPDIR/err"; bash "$RUN" "$@" >"$o" 2>"$e"; RC=$?; OUT="$(cat "$o")"; ERR="$(cat "$e")"; }

REPO="$(mktemp -d "$TMPDIR/repo.XXXXXX")"
git -C "$REPO" init -q
echo "# smoke" > "$REPO/README.md"
git -C "$REPO" add -A && git -C "$REPO" -c user.name=t -c user.email=t@t commit -q -m init
echo "repo: $REPO"

# 2. ask / session extraction
run_wrapper ask -C "$REPO" "Reply with exactly the word PONG and nothing else."
[ "$RC" -eq 0 ] && ok "ask rc 0" || fail "ask rc 0" "rc=$RC err=$ERR"
assert_contains "ask answer" "$OUT" "PONG"
assert_contains "ask session line" "$OUT" "session: "
[ "$(find "$TMPDIR/codex-run" -type f 2>/dev/null | wc -l | tr -d ' ')" = 0 ] && ok "ask log deleted" || fail "ask log deleted"

# 3. delegate / write / status
run_wrapper delegate -C "$REPO" "Create a file named hello.txt in the current directory containing exactly: hi"
[ "$RC" -eq 0 ] && ok "delegate rc 0" || fail "delegate rc 0" "rc=$RC err=$ERR"
[ -f "$REPO/hello.txt" ] && ok "delegate created hello.txt" || fail "delegate created hello.txt" "$OUT"
assert_contains "delegate trailer" "$OUT" "--- git status after Codex ---"
assert_contains "delegate trailer lists hello.txt" "$OUT" "?? hello.txt"
SID="$(sed -n 's/^session: //p' <<< "$OUT" | head -n 1)"
[ -n "$SID" ] && ok "delegate session id captured ($SID)" || fail "delegate session id captured"

# 4. resume read-only must not write
run_wrapper resume -C "$REPO" "$SID" "Create a file named should-not-exist.txt containing: no"
[ ! -f "$REPO/should-not-exist.txt" ] && ok "resume read-only refused write" || fail "resume read-only refused write" "$OUT"
echo "   (resume read-only rc=$RC; Codex said: ${OUT:0:200})"

# 5. resume workspace-write
run_wrapper resume -C "$REPO" "$SID" --mode workspace-write "Create a file named resumed.txt in the current directory containing exactly: yes"
[ "$RC" -eq 0 ] && ok "resume ww rc 0" || fail "resume ww rc 0" "rc=$RC err=$ERR out=${OUT:0:400}"
[ -f "$REPO/resumed.txt" ] && ok "resume ww created resumed.txt" || fail "resume ww created resumed.txt" "if this stalled on approval, find the approval -c key 0.154.0 honours; see DESIGN.md"
assert_contains "resume ww trailer" "$OUT" "--- git status after Codex ---"

# 6. --last scoping
run_wrapper resume -C "$REPO" --last "Reply with exactly the word LAST and nothing else."
assert_contains "resume --last picks repo session" "$OUT" "session: $SID"

# 7. review
run_wrapper review -C "$REPO" --uncommitted
[ "$RC" -eq 0 ] && ok "review rc 0" || fail "review rc 0" "rc=$RC err=$ERR"
[ "${#OUT}" -gt 60 ] && ok "review produced output" || fail "review produced output" "$OUT"

# 8. failure path
run_wrapper ask -C "$REPO" -m nonexistent-model-xyz "hi"
[ "$RC" -ne 0 ] && ok "bad model -> non-zero" || fail "bad model -> non-zero" "$OUT"
assert_contains "bad model -> log kept" "$ERR" "events log kept at "
kept="$(sed -n 's/.*events log kept at \(.*\)$/\1/p' <<< "$ERR" | head -n 1)"
[ -n "$kept" ] && [ -f "$kept" ] && ok "bad model -> log file exists" || fail "bad model -> log file exists"
rm -rf "$TMPDIR/codex-run"

# 9. bogus SESSION_ID must not silently succeed as a fresh session
run_wrapper resume -C "$REPO" 00000000-0000-0000-0000-000000000000 "Reply with exactly: FRESH"
[ "$RC" -ne 0 ] && ok "bogus session id -> non-zero (rc=$RC)" || fail "bogus session id -> non-zero" "$OUT"
rm -rf "$TMPDIR/codex-run"

echo; echo "passed=$PASS failed=$FAIL  (repo left at $REPO)"
[ "$FAIL" -eq 0 ]
