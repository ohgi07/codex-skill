# codex-run output, warnings and failures

## Layout

```
[codex <mode>] cwd=<dir> model=<model|default>
session: <id>

<Codex's final message>

--- git status after Codex ---
 M src/foo.ts
?? src/bar.ts

--- codex-run verification ---
files changed during the run: 2   (changes already present before the run and left alone: 1)
   M src/foo.ts   (+12 -3)
  ?? src/bar.ts   (new file, 40 lines; read it)
warnings:
  (none)
message hints (phrases worth checking in Codex's reply; not a verdict):
  - I could not run the e2e tests (sandbox)
(the list above was taken before --verify ran; files the command creates are not in it)
verify: PASSED  $ npm test
```

- `model=default` means no `-m` was given; the wrapper does not report the model actually used — `status <session-id>` does.
- `session:` appears whenever the run emitted a `thread.started` event, on success and on failure; use it with `resume <id>`. Never printed by `review` (Codex's review text follows the header as-is) or `status`.
- The `git status` trailer appears only for `delegate` / `resume --mode workspace-write` inside a git work tree, and only when Codex succeeded. It is a plain `git status --short`, so on a dirty tree it also lists pre-existing changes.
- The verification report appears for the same runs with or without git, and also when Codex fails or a resume started the wrong session.
  - **"files changed during the run"** compares the tree before and after (git status code + content hash of each listed path). It sees state, not authorship: anything else writing to the tree during the run shows up too, and a change only to the index with the same work-tree content is not seen. `[had changes before the run; the numbers include them]` marks a path that was already dirty.
  - Outside git it lists files modified since the run started (no deletions, at most 200, `.git` and `node_modules` skipped).
- **Warnings** are observed facts: non-zero Codex exit, no files changed, empty final message, HEAD moved, session was not resumed.
- **Message hints** are lines of Codex's reply matching "could not / skipped / failed / sandbox / 못했 …". The match is broad ("Fixed the sandbox issue" matches), so read the line before treating it as a problem.
- `verify:` is `PASSED`, `FAILED (exit N)`, `TIMED OUT after Ns`, `skipped (Codex failed)` or `skipped (session was not resumed)`, followed by the command's last 20 output lines. The file list is taken before the command runs. Without a `timeout` command on PATH it prints a note and runs without a time limit.

## Failures

Every failure the wrapper recognises prints one `codex-run: error=<kind> …` line on stderr. Go by that line: the
exit code alone cannot say who failed, because Codex's own exit code is passed through unchanged.

| `error=` | exit | what happened | what to do |
|---|---|---|---|
| `args` | 1 | bad arguments, missing `-C` directory, unknown session in `status` | fix the call; nothing ran |
| `codex_missing` | 2 | `codex` not on PATH | tell the user (`npm i -g @openai/codex`) |
| `usage_guard` | 3 | last recorded usage ≥ `CODEX_RUN_USAGE_LIMIT` | SKILL.md rule 11; nothing ran |
| `codex_exit codex_rc=N` | N | Codex itself failed | read the stderr tail and `--- partial output ---`; in write modes check the tree — nothing was rolled back |
| `session_mismatch requested=A started=B` | 1 | `resume A` started a new thread B without the earlier context | the answer is not printed; in write modes the change report still shows what B changed and `--verify` is skipped. Resume B only if its result is what you wanted, otherwise start over |
| `verify_failed verify_rc=N` | 4 | Codex succeeded, the `--verify` command failed | read the diff and the command output |
| `verify_timeout` | 4 | the `--verify` command exceeded `CODEX_RUN_VERIFY_TIMEOUT` | same |

On a Codex failure the wrapper prints the last 20 lines of Codex's stderr, error events from the event stream,
`--- partial output ---` if a partial message exists, and `codex-run: events log kept at <path>` (`ask` /
`delegate` / `resume`, only if the log is non-empty). The log is also kept on `session_mismatch`, and on success
with `CODEX_RUN_KEEP_LOG=1`.

`resume <SESSION_ID>` with no `thread.started` event at all only warns (`could not verify that session … was
resumed`); the exit code is unchanged.

`status` failures (live read failed, reset not used) exit 1 with their reason on the `resets:` / `reset:` line;
see `status.md`.
