# Codex skill for Claude Code — design

Date: 2026-09-16
Status: implemented (mode table updated with what the smoke test on Codex 0.154.0 / Windows actually required)

## Goal

Let Claude Code call the locally installed OpenAI Codex CLI (`codex` 0.154.0) for
two purposes:

1. **Second opinion / code review** — Codex reads the repo, never writes.
2. **Delegation** — Codex implements or modifies code in the workspace; Claude
   then verifies the result.

Follow-up turns on a prior Codex session are supported via `resume`.

## Non-goals

- MCP server / structured tool schema (may come later; the script is the seam).
- Streaming Codex's progress events into Claude — only the final message and a
  post-run `git status` matter.
- Any path that bypasses Codex's sandbox or approval flow.
- PowerShell twin (`codex-run.ps1`). Bash only; Claude Code on Windows already
  ships Git Bash.

## Deliverables

```
~/.claude/skills/codex/
├── SKILL.md              # when/how Claude uses it
├── scripts/codex-run.sh  # the wrapper (bash, Git Bash compatible)
└── DESIGN.md             # copy of this spec, kept next to the skill
```

User-level install so it works in every project.

## Script interface

```
codex-run.sh review   [-C DIR] [-m MODEL] [--effort X] [--uncommitted | --base BRANCH | --commit SHA]
codex-run.sh ask      [-C DIR] [-m MODEL] [--effort X] [PROMPT | -]
codex-run.sh delegate [-C DIR] [-m MODEL] [--effort X] [PROMPT | -]
codex-run.sh resume   [-C DIR] (--last | SESSION_ID) [--mode read-only|workspace-write] [PROMPT | -]
```

- `PROMPT` is the last positional argument. Resolution rules:
  - PROMPT given → use it.
  - PROMPT is `-`, or omitted while stdin is piped → read stdin
    (heredoc-friendly, avoids shell quoting problems on Windows).
  - PROMPT omitted while stdin is a TTY → usage error immediately (never
    block a human at an interactive terminal waiting for stdin).
  - Resulting prompt empty or whitespace-only → usage error.
- `review` takes **no** PROMPT: in 0.154.0 `--uncommitted`, `--base`, `--commit`
  are mutually exclusive with the positional prompt (verified:
  `error: the argument '--uncommitted' cannot be used with '[PROMPT]'`).
  Free-form review instructions go through `ask`.
- `-C DIR` defaults to `$PWD`. The script `cd`s into DIR before invoking codex
  (needed because `exec resume` has no `-C`; also scopes `--last` to that repo).
- `-m MODEL` is passed through. `--effort X` becomes
  `-c model_reasoning_effort="X"`; X is a passthrough string, not validated by
  the wrapper (codex does not reject unknown values at startup either).
  Documented values: `low | medium | high` plus whatever the installed Codex
  accepts.
- `--color never` is always passed on subcommands that accept it.

## Mode → codex invocation

| mode | command | permissions |
|---|---|---|
| `review` | `codex exec -s read-only --color never review <target> -c sandbox_mode="read-only" RO PLAT` — default target `--uncommitted` | read-only, enforced by the wrapper (not assumed from the reviewer). `-s` lives on `exec` (the `review` subcommand has no `-s`); the `-c sandbox_mode` override is added on `review` as well so the guarantee does not depend on how the parent flag propagates. |
| `ask` | `codex exec -s read-only RO PLAT --json -o OUT --skip-git-repo-check -` | read-only |
| `delegate` | `codex exec --approve-for-me PLAT --json -o OUT --skip-git-repo-check -` | workspace-write; approval requests are routed through Codex automatic review, subject to the effective policy/config. **No explicit `-s`**: in 0.154.0 `--approve-for-me` is mutually exclusive with `--sandbox` (verified: `error: the argument '--sandbox <SANDBOX_MODE>' cannot be used with '--approve-for-me'`) and already selects the workspace-write sandbox. |
| `resume` | `codex exec resume (--last \| ID) POLICY PLAT --json -o OUT --skip-git-repo-check -` | resumes conversation context; execution permissions are resolved from **this** invocation, default `read-only` |

Where:

- `RO` = `-c approval_policy="never"` — removes the only path out of a read-only sandbox (an approved escalation). Verified: with the user's `approvals_reviewer = "auto_review"` config and without `RO`, a read-only run still wrote a file.
- `POLICY` for `resume` = `-c sandbox_mode="read-only" RO` (default) or, for `--mode workspace-write`, `-c sandbox_mode="workspace-write" -c approval_policy="on-request" -c approvals_reviewer="auto_review"` — exactly what `--approve-for-me` expands to in 0.154.0 (from the binary's own strings), spelled out because `exec resume` has no such flag.
- `PLAT` = `-c windows.sandbox="<level>"` on Windows only (`$OSTYPE` is `msys*` or `cygwin*`), level from `CODEX_RUN_WINDOWS_SANDBOX` (`unelevated` default, `elevated` allowed, anything else is a usage error). See "Windows sandbox" below.

### Windows sandbox

Smoke-testing on the user's Windows 10 machine showed that Codex 0.154.0 has **no OS sandbox on Windows unless its Windows sandbox backend is enabled** (`[windows] sandbox = "unelevated" | "elevated"` in config.toml; docs: learn.chatgpt.com/docs/windows/windows-sandbox). Without it:

- `-s read-only` on its own did not stop a write (`codex exec -s read-only "create a.txt"` → file created; the command ran through PowerShell, no approval event, `auto_review` in effect).
- `-s read-only -c approval_policy="never"` stopped the write but also every read (`Get-Content` "blocked by policy"), because PowerShell commands are not in Codex's safe-command list. Same with `--ignore-user-config`.

With `-c windows.sandbox="unelevated"` (restricted token + ACL boundary, no admin needed), read-only is enforced by the OS: reads and directory listings succeed, and `[System.IO.File]::WriteAllText`, `Set-Content`, `New-Item` and `cmd /c echo >` all fail with `UnauthorizedAccessException`; `--approve-for-me` still writes inside the workspace. The wrapper therefore passes it on every Windows invocation rather than depending on the user's config.toml. Sandboxed commands have no network access, so `ask`/`review` cannot fetch URLs.

Facts about `codex exec resume` in 0.154.0 that drive the design (verified via
`--help`): it accepts `-m`, `--json`, `-o`, `--skip-git-repo-check`, `-c`; it
does **not** accept `-s/--sandbox`, `-C`, or `--approve-for-me`. Hence the
sandbox is enforced with `-c sandbox_mode=...` and the default is `read-only`
so `ask → resume` can never silently gain write access.
`--mode workspace-write` must be explicit.

(Resolved during the smoke test: the approval keys 0.154.0 honours are
`approval_policy` and `approvals_reviewer`; see the mode table above.)

The wrapper exposes no way to pass `--dangerously-bypass-approvals-and-sandbox`
or `--dangerously-bypass-hook-trust`.

Sandbox invariants the wrapper guarantees on its own, without relying on Codex
subcommand defaults or the user's config.toml: `review` and `ask` always carry
`-s read-only` plus `approval_policy="never"`; `resume` always carries an
explicit `-c sandbox_mode=...` plus the matching approval policy; on Windows
every mode carries `-c windows.sandbox=...`; only `delegate` and
`resume --mode workspace-write` can write.

### Resume session verification

Codex has been observed to start a fresh thread when given a non-existent or
malformed session id instead of failing. To prevent a silent "resume" that is
actually a new session, an explicit-`SESSION_ID` resume compares the requested
id with the `thread_id` in the `thread.started` event of the JSONL stream:

```
requested SESSION_ID = A
thread.started.thread_id = B
A != B  →  stderr error, exit 1, keep JSONL
```

`--last` is excluded from this check (the expected id is not known in advance).

### No `jq` dependency

Git Bash does not guarantee `jq`. The only JSON the wrapper needs to read is
the `thread.started` event, which is a flat one-line object:

```json
{"type":"thread.started","thread_id":"019d..."}
```

Extract `thread_id` with `sed`/`grep`, not `jq`.

## Output contract (stdout)

```
[codex <mode>] cwd=<DIR> model=<model or "default">
session: <thread id>          # parsed from the --json `thread.started` event; line omitted if not found

<final assistant message from the -o file>

--- git status after Codex ---   # delegate, and resume with --mode workspace-write; only if DIR is a git repo
 M src/foo.ts
?? src/bar.ts
```

- The trailer is deliberately named "git status after Codex": on an already
  dirty repo it cannot distinguish Codex's edits from pre-existing ones.
  Claude is instructed to run `git diff` itself. No before/after snapshot logic.
- `review` has no `--json`/`-o`; its stdout is passed through unchanged after
  the header line.

## Raw JSONL log

- `umask 077` is set before any temp file is created, so the JSONL and the
  `-o` output file are owner-readable only on Unix-like filesystems.
- Created with `mktemp` under `${TMPDIR:-/tmp}/codex-run/`.
- **Success:** deleted.
- **Failure:** kept; path printed to stderr.
- `CODEX_RUN_KEEP_LOG=1`: kept regardless; path printed to stderr.

Rationale: the event stream can contain prompts, file contents and model
output; it should not accumulate silently.

## Error handling

| condition | behaviour |
|---|---|
| `codex` not on PATH | message on stderr, exit 2 |
| no mode / unknown mode | usage, exit 1 |
| `review` with more than one of `--uncommitted/--base/--commit`, or a PROMPT | usage, exit 1 |
| `resume` without `--last` or SESSION_ID, or `--mode` outside the two values | usage, exit 1 |
| PROMPT omitted and stdin is a TTY (ask/delegate/resume) | usage, exit 1 |
| empty or whitespace-only prompt for ask/delegate/resume | usage, exit 1 |
| `-C DIR` missing | message, exit 1 (before invoking codex) |
| codex exits non-zero | print last 20 lines of codex stderr, print partial `-o` content if present, exit with codex's code, keep JSONL |
| `resume SESSION_ID` emitted a different `thread_id` | stderr error, exit 1, keep JSONL |

## SKILL.md contents

Frontmatter `name: codex`, description listing the triggers.

Triggers (deliberately narrow so generic "think about it differently" requests
do not fire):
`codex`, `코덱스`, `codex 리뷰`, `codex한테 시켜/맡겨`, `코덱스한테도 물어봐`,
`Codex second opinion`, "다른 모델, 특히 Codex 의견".

Rules for Claude:
1. Always pass `-C` with the absolute project path; feed prompts via heredoc on stdin.
2. Bash tool `timeout: 600000`; for large delegations use `run_in_background: true` and report when done.
3. After `delegate` (or `resume --mode workspace-write`): run `git diff` and
   review the changes yourself before telling the user it's done — Codex's
   output is a proposal, not a verified result.
4. Present Codex's answer attributed as Codex's; keep your own assessment separate.
5. Never edit the script to add bypass flags.
6. `resume` defaults to read-only; pass `--mode workspace-write` only when the
   follow-up is meant to edit files.

Mode table with one example each.

## Test plan (executed during implementation)

1. **Usage validation** (no codex invoked): no args; unknown mode;
   `review --base x --commit y`; `review "prompt"`; `resume` with no target;
   `ask` with empty stdin; `ask` with whitespace-only stdin; `ask` with no
   PROMPT and stdin attached to a TTY (simulated with `script`/`</dev/tty`
   where available, otherwise by asserting the `[ -t 0 ]` branch in a unit
   harness); `-C /nonexistent`.
2. **ask / session extraction** — temp dir, trivial prompt → answer printed,
   `session:` line present, JSONL deleted on success.
3. **delegate / write / status** — temp git repo, "create hello.txt containing hi"
   → file exists, trailer shows `?? hello.txt`. Capture SESSION_ID.
4. **resume read-only** — `resume -C "$repo" "$SESSION_ID" "create should-not-exist.txt"`
   with default mode → file does not exist afterwards.
5. **resume workspace-write** — `resume -C "$repo" "$SESSION_ID" --mode workspace-write "create resumed.txt"`
   → file exists. If it stalls on approval, investigate the real `-c` key (see above).
6. **`--last` repo scoping** — `resume -C "$repo" --last "..."` inside the repo
   resumes the expected session (compare the printed `session:` id).
7. **review** — `review -C "$repo" --uncommitted` → review text printed.
8. **failure path** — force a codex error (e.g. `-m nonexistent-model`) → stderr
   tail shown, non-zero exit, JSONL path printed and file kept.
9. **bogus SESSION_ID** — `resume -C "$repo" 00000000-0000-0000-0000-000000000000 "hi"`
   → must not silently succeed as a fresh session: either Codex itself errors,
   or the wrapper detects the `thread_id` mismatch and exits 1 with the JSONL kept.

Tests 2–9 hit the real Codex API on the user's account; keep prompts tiny.
