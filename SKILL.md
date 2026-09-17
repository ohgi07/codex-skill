---
name: codex
description: Use when the user names Codex — "codex", "코덱스", "codex 리뷰", "codex한테 시켜/맡겨", "코덱스한테도 물어봐", "Codex second opinion", "다른 모델, 특히 Codex 의견" — for a second opinion or code review from the locally installed OpenAI Codex CLI, or to delegate an implementation task to Codex and verify its result. Do NOT use for generic "think about it from another angle" requests that don't name Codex.
---

# Codex

Wrapper script (bash — run it with the Bash tool; `--help` lists every option):

```
~/.claude/skills/codex/scripts/codex-run.sh <mode> [-C DIR] [options] [PROMPT | -]
```

## Modes

| mode | use when | permissions | notes |
|---|---|---|---|
| `review` | user wants Codex's built-in code review of a diff | read-only | target: `--uncommitted` (default), `--base BRANCH`, `--commit SHA` (one of them). **No PROMPT and no stdin** — text piped to `review` is dropped without an error; review instructions go through `ask`. |
| `ask` | second opinion, explanation, design critique, free-form review | read-only | Codex can read the repo but cannot write. |
| `delegate` | user asks Codex to implement / modify something | workspace-write | edits land on disk immediately; approvals go through Codex automatic review. |
| `resume` | follow-up on a previous Codex session | `--mode read-only` (default) or `--mode workspace-write` | `--last`, or the UUID from the `session:` line (nothing else is accepted). |
| `status` | user asks about Codex's setup, model, login, rate-limit / token usage, or what a session ran with | none (offline; reads `$CODEX_HOME`, default `~/.codex`; no API call) | header only, or add `--last` (newest session in `-C DIR`) / SESSION_ID for that session's model, sandbox, approval and token totals. Not for `-m` / `--effort`. |

Shared options: `-C DIR` (project root), `-m MODEL`, `--effort low|medium|high|…` (passed through unvalidated to Codex's `model_reasoning_effort`).

## Rules

1. **Always pass `-C` with the absolute project path** (forward slashes, e.g. `-C "D:/Code Projects/x"`). The wrapper `cd`s there; `resume --last` is scoped to that directory.
2. **`ask` / `delegate` / `resume`: feed the prompt on stdin with a quoted heredoc** — no shell-quoting problems, multi-line friendly:
   ```bash
   ~/.claude/skills/codex/scripts/codex-run.sh ask -C "D:/Code Projects/x" <<'EOF'
   ...prompt...
   EOF
   ```
   `review` and `status` take no prompt (a positional PROMPT is a usage error; `review` reads stdin from `/dev/null`).
3. **Timeouts:** use Bash tool `timeout: 600000`. For large delegations use `run_in_background: true` and report to the user when it finishes; don't edit the same files while it runs.
4. **Before `delegate` (or `resume --mode workspace-write`), record the starting state: in a git repo `git status --short` and, if it has a commit, `git rev-parse HEAD`; outside git (the wrapper allows it), list the files you expect to change. Afterwards the files are already changed — verify before telling the user it's done:** `git status --short`, `git diff`, `git diff --cached`, read every new untracked file (outside git, read each expected file), run the relevant tests. Codex's message is a claim, not a verified result: exit 0 does not mean the task is done (the message may say "could not" / "skipped", or be empty), and a non-zero exit rolls nothing back — check the tree before re-running. The trailer `--- git status after Codex ---` is a plain `git status --short`; on a dirty tree it also lists pre-existing changes, which is why you noted them first.
5. **Attribute Codex's answer as Codex's** (e.g. "Codex says: …") and keep your own assessment clearly separate. Spot-check its `file:line` citations before repeating them.
6. **`resume` defaults to read-only.** Pass `--mode workspace-write` only when the follow-up is meant to edit files — including "now add a test" after a `delegate`. Keep the UUID from `session:` for follow-ups on a specific job; `--last` moves to whatever session ran most recently in that directory.
7. **Never** edit the wrapper to add `--dangerously-*` flags, and never call `codex` directly with them.
8. **Codex never commits; Claude does, after review.** Every `delegate` / `resume --mode workspace-write` prompt ends with "Do not commit." Claude commits after reviewing the diff, following the user's and the project's commit conventions (including any rules on AI attribution). If HEAD moved during the run (compare with the value recorded in rule 4), inspect `git log <before>..HEAD`; only when every commit in that range is Codex's (made during the run, touching its task) undo them with `git reset --soft <before>` (changes stay staged), review, then commit yourself. Anything else in that range — ask the user.
9. **Read-only modes run Codex in a real sandbox** (`ask`, `review`, `resume` without `--mode workspace-write`): writes are refused at the OS level, there is **no network access**, and `approval_policy=never` means Codex cannot ask for an escalation. On Windows the wrapper enables Codex's Windows sandbox backend per call (`unelevated`); `CODEX_RUN_WINDOWS_SANDBOX=elevated` selects the elevated backend if the user has set it up.

## Writing the prompt

Codex gets only the prompt text and whatever it reads itself starting from `DIR` — nothing from this conversation, the user's decisions, or what Claude already checked is passed along. `resume` carries the earlier Codex turns, not what happened on Claude's side since. Use `--effort high` for design critique and free-form review; omit it (Codex's config default) for small, well-scoped delegations.

A prompt has these parts, in this order:

1. **Goal and done criterion** — what to explain or change, and the observable result that means done.
2. **Context** — paths to read (not their contents), current vs. expected behavior, repro steps, error text, and facts already established ("X was ruled out because …").
3. **Scope and constraints** — APIs/behavior to keep, whether new dependencies are allowed, "preserve existing uncommitted changes", and for write modes "Do not commit."
4. **Verification** — which tests/commands to run; if it cannot run them, report the command and why.
5. **Answer shape** — `ask`: findings ranked by importance, each with `file:line` evidence, assumptions and unverified points listed separately. `delegate`: files changed, what was done, test results, open problems. Name the answer language if not English.

For `ask` and read-only `resume` also say: put reports or patches in the final message, not in files (writes fail); a test or build that needs to write caches, snapshots or generated files is blocked by the sandbox — report that as "could not run (sandbox)", distinct from a test that ran and failed; any web content is fetched by Claude and pasted into the prompt.

## Output format

```
[codex <mode>] cwd=<dir> model=<model|default>
session: <id>

<Codex's final message>

--- git status after Codex ---
 M src/foo.ts
?? src/bar.ts
```

- `model=default` means no `-m` was given; the wrapper does not report the model actually used — `status <session-id>` does.
- `session:` appears only when the run emitted a `thread.started` event; use it with `resume <id>`. Never printed by `review` (Codex's review text follows the header as-is) or `status`.
- The trailer appears only for `delegate` / `resume --mode workspace-write` inside a git work tree.
- `status` has its own layout: codex version/login, config.toml model/effort/reviewer, the wrapper's policy, `limits:` (the last rate-limit reading Codex recorded — not live — with its timestamp and source session; if the requested session recorded none, the newest session that did is shown), then with `--last`/SESSION_ID that session's model/sandbox/approval and token totals.

Failures: argument errors exit 1 and a missing `codex` exits 2 before Codex runs. When Codex itself fails, the wrapper exits with Codex's code and prints the last 20 lines of its stderr, `--- partial output ---` if a partial message exists, and `codex-run: events log kept at <path>` (`ask`/`delegate`/`resume`, only if the log is non-empty — an empty log is deleted without a message). `resume <SESSION_ID>` that started a different thread exits 1 with "session was NOT resumed" — checked after the run, so a write-mode follow-up may already have changed files; no `thread.started` event at all is only a warning. `CODEX_RUN_KEEP_LOG=1` keeps the log on success too.

## Examples

Second opinion on a design:
```bash
~/.claude/skills/codex/scripts/codex-run.sh ask -C "D:/Code Projects/x" --effort high <<'EOF'
Goal: assess the risks of moving session storage from Redis to Postgres.
Read src/session/ and its tests. Sessions expire by TTL and several app instances share the store; both must keep working.
Do not modify files or install anything; analysis only.
Answer with risks ranked by severity, each with file:line evidence; list assumptions and anything you could not verify separately.
EOF
```

Built-in review of uncommitted changes:
```bash
~/.claude/skills/codex/scripts/codex-run.sh review -C "D:/Code Projects/x" --uncommitted
```

Delegate a task, then verify (rule 4):
```bash
~/.claude/skills/codex/scripts/codex-run.sh delegate -C "D:/Code Projects/x" <<'EOF'
Add input validation to POST /users in src/routes/users.ts.
Done when a missing, empty or whitespace-only name returns 400 in the existing error-response shape and valid input behaves as before.
Add a test next to the existing route tests. Keep the current uncommitted changes; no new dependencies. Do not commit.
Run the route tests; if you cannot, report the command and why.
Final message: files changed, what was done, test results, open problems.
EOF
```

Codex setup and remaining rate limit, plus what the last session in this repo used:
```bash
~/.claude/skills/codex/scripts/codex-run.sh status -C "D:/Code Projects/x" --last
```

Follow-up on that session (read-only):
```bash
~/.claude/skills/codex/scripts/codex-run.sh resume -C "D:/Code Projects/x" <session-id> <<'EOF'
Why did you choose a regex over a schema library?
EOF
```
