---
name: codex
description: Use when the user names Codex — "codex", "코덱스", "codex 리뷰", "codex한테 시켜/맡겨", "코덱스한테도 물어봐", "Codex second opinion", "다른 모델, 특히 Codex 의견" — for a second opinion or code review from the locally installed OpenAI Codex CLI, or to delegate an implementation task to Codex and verify its result. Do NOT use for generic "think about it from another angle" requests that don't name Codex.
---

# Codex

Wrapper script (bash — run it with the Bash tool; `--help` lists every option):

```
"${CLAUDE_SKILL_DIR}/scripts/codex-run.sh" <mode> [-C DIR] [options] [PROMPT | -]
```

`scripts/` sits next to this SKILL.md. If the path above did not come out as an absolute path, use this skill's base directory (shown when the skill loaded) in its place.

## Modes

| mode | use when | permissions | notes |
|---|---|---|---|
| `review` | user wants Codex's built-in code review of a diff | read-only | target: `--uncommitted` (default), `--base BRANCH`, `--commit SHA` (one of them). **No PROMPT and no stdin** — text piped to `review` is dropped without an error; review instructions go through `ask`. |
| `ask` | second opinion, explanation, design critique, free-form review | read-only | Codex can read the repo but cannot write. |
| `delegate` | user asks Codex to implement / modify something | workspace-write | edits land on disk immediately; approvals go through Codex automatic review. Prints a verification report afterwards (rule 4); `--verify CMD` runs a test command after the run. |
| `resume` | follow-up on a previous Codex session | `--mode read-only` (default) or `--mode workspace-write` | `--last`, or the UUID from the `session:` line (nothing else is accepted). |
| `status` | user asks about Codex's setup, model, login, rate-limit / token usage, or what a session ran with | none (offline; reads `$CODEX_HOME`, default `~/.codex`; no API call) | header only, or add `--last` (newest session in `-C DIR`) / SESSION_ID for that session's model, sandbox, approval and token totals. Not for `-m` / `--effort`. |
| `status --resets` | user asks about current/live usage or rate-limit reset credits ("초기화권", "리셋 몇 개 남았어") | read-only API call (`codex app-server`) | live limits plus each reset credit with its expiry, soonest first. Combines with `--last` / SESSION_ID. |
| `status --use-reset` | user explicitly asks to use a reset credit ("초기화권 써줘") | **spends a credit — irreversible** | shows the live state, consumes the soonest-expiring credit, then shows usage and credits again. See rule 10. |

Shared options: `-C DIR` (project root), `-m MODEL`, `--effort low|medium|high|…` (passed through unvalidated to Codex's `model_reasoning_effort`), `--ignore-usage` (skip the usage guard, rule 11).

Write-mode options: `--verify CMD` (`delegate`, `resume --mode workspace-write`) — a shell command run in DIR after a successful run, outside Codex's sandbox with your permissions, e.g. `--verify "npm test"`. Passes → `verify: PASSED`; fails or exceeds `CODEX_RUN_VERIFY_TIMEOUT` seconds (default 600) → the wrapper exits 4.

## Rules

1. **Always pass `-C` with the absolute project path** (e.g. `-C "/path/to/project"`; on Windows use forward slashes, e.g. `-C "C:/src/project"`). The wrapper `cd`s there; `resume --last` is scoped to that directory.
2. **`ask` / `delegate` / `resume`: feed the prompt on stdin with a quoted heredoc** — no shell-quoting problems, multi-line friendly:
   ```bash
   "${CLAUDE_SKILL_DIR}/scripts/codex-run.sh" ask -C "/path/to/project" <<'EOF'
   ...prompt...
   EOF
   ```
   `review` and `status` take no prompt (a positional PROMPT is a usage error; `review` reads stdin from `/dev/null`).
3. **Running:** Bash tool with `run_in_background: true` and `timeout: 7200000`. Tell the user Codex is running, then wait for the completion notification — don't poll, sleep, or re-run it meanwhile — and report the result when it arrives. Don't edit the files Codex may touch while it runs.
4. **Before `delegate` (or `resume --mode workspace-write`), record the starting state: in a git repo `git status --short` and, if it has a commit, `git rev-parse HEAD`; outside git (the wrapper allows it), list the files you expect to change. Afterwards the files are already changed — verify before telling the user it's done:** `git status --short`, `git diff`, `git diff --cached`, read every new untracked file (outside git, read each expected file), run the relevant tests. Codex's message is a claim, not a verified result: exit 0 does not mean the task is done (the message may say "could not" / "skipped", or be empty), and a non-zero exit rolls nothing back — check the tree before re-running. The trailer `--- git status after Codex ---` is a plain `git status --short`; on a dirty tree it also lists pre-existing changes, which is why you noted them first. The wrapper also takes its own before/after snapshot and prints a `--- codex-run verification ---` report (files Codex touched vs. changes already there, HEAD moved, warnings, `--verify` result). It narrows down where to look; it does not replace reading the diff and the new files. Pass `--verify "<test command>"` whenever you know the project's test command; it runs with your permissions and executes whatever Codex just changed (test scripts included), so skim the diff first when the task touched build or test files.
5. **Attribute Codex's answer as Codex's** (e.g. "Codex says: …") and keep your own assessment clearly separate. Spot-check its `file:line` citations before repeating them.
6. **`resume` defaults to read-only.** Pass `--mode workspace-write` only when the follow-up is meant to edit files — including "now add a test" after a `delegate`. Keep the UUID from `session:` for follow-ups on a specific job; `--last` moves to whatever session ran most recently in that directory.
7. **Never** edit the wrapper to add `--dangerously-*` flags, and never call `codex` directly with them.
8. **Codex never commits; Claude does, after review.** Every `delegate` / `resume --mode workspace-write` prompt ends with "Do not commit." Claude commits after reviewing the diff, following the user's and the project's commit conventions (including any rules on AI attribution). If HEAD moved during the run (compare with the value recorded in rule 4), inspect `git log <before>..HEAD`; only when every commit in that range is Codex's (made during the run, touching its task) undo them with `git reset --soft <before>` (changes stay staged), review, then commit yourself. Anything else in that range — ask the user.
9. **Read-only modes run Codex in a real sandbox** (`ask`, `review`, `resume` without `--mode workspace-write`): writes are refused at the OS level, shell commands have **no network access** (`curl`, `pip install`, `git fetch` fail) — web search still works (`--search` on every call; the tool runs on OpenAI's side) — and `approval_policy=never` means Codex cannot ask for an escalation. On Windows the wrapper enables Codex's Windows sandbox backend per call (`unelevated`); `CODEX_RUN_WINDOWS_SANDBOX=elevated` selects the elevated backend if the user has set it up.
10. **Reset credits are spent only on the user's explicit go-ahead.** Run `status --resets` first and show the user the live usage and credits (count, soonest expiry). Then run `status --use-reset` only after they confirm in chat for this specific reset; a vague "check my limits" or a high usage reading is never a reason to spend one on your own. Run it once: a re-run is a new attempt that can spend another credit. `nothingToReset` means no window was eligible; report it rather than retrying.
11. **Usage guard.** `delegate`, `resume --mode workspace-write` and `--effort high|xhigh|max` runs exit 3 without starting when the last recorded usage is at or above `CODEX_RUN_USAGE_LIMIT` percent (default 80). Show the user the guard's message and ask whether to go ahead; only then re-run with `--ignore-usage`. The reading is Codex's last recorded one, not live; `status --resets` gives live numbers.

## Writing the prompt

Codex gets only the prompt text and whatever it reads itself starting from `DIR` — nothing from this conversation, the user's decisions, or what Claude already checked is passed along. `resume` carries the earlier Codex turns, not what happened on Claude's side since. Use `--effort high` for design critique and free-form review; omit it (Codex's config default) for small, well-scoped delegations.

A prompt has these parts, in this order:

1. **Goal and done criterion** — what to explain or change, and the observable result that means done.
2. **Context** — paths to read (not their contents), current vs. expected behavior, repro steps, error text, and facts already established ("X was ruled out because …").
3. **Scope and constraints** — APIs/behavior to keep, whether new dependencies are allowed, "preserve existing uncommitted changes", and for write modes "Do not commit."
4. **Verification** — which tests/commands to run; if it cannot run them, report the command and why.
5. **Answer shape** — `ask`: findings ranked by importance, each with `file:line` evidence, assumptions and unverified points listed separately. `delegate`: files changed, what was done, test results, open problems. Name the answer language if not English.

For `ask` and read-only `resume` also say: put reports or patches in the final message, not in files (writes fail); a test or build that needs to write caches, snapshots or generated files is blocked by the sandbox — report that as "could not run (sandbox)", distinct from a test that ran and failed; Codex can use its web search tool, but commands that need network (installs, `curl`) fail in the sandbox.

## Output format

```
[codex <mode>] cwd=<dir> model=<model|default>
session: <id>

<Codex's final message>

--- git status after Codex ---
 M src/foo.ts
?? src/bar.ts

--- codex-run verification ---
files touched by Codex: 2   (changes already present before the run and left alone: 1)
   M src/foo.ts   (+12 -3)
  ?? src/bar.ts   (new file, 40 lines; read it)
warnings:
  (none)
verify: PASSED  $ npm test
```

- `model=default` means no `-m` was given; the wrapper does not report the model actually used — `status <session-id>` does.
- `session:` appears only when the run emitted a `thread.started` event; use it with `resume <id>`. Never printed by `review` (Codex's review text follows the header as-is) or `status`.
- The trailer appears only for `delegate` / `resume --mode workspace-write` inside a git work tree. The verification report appears for the same runs with or without git (outside git it lists files modified since the run started), and also when Codex fails. Warnings it can raise: non-zero Codex exit, no files changed, empty final message, HEAD moved, and lines of Codex's message that say "could not / skipped / failed / sandbox" (a hint, not a verdict). `verify: skipped (Codex failed)` when Codex failed.
- Exit codes added by the wrapper: 3 = usage guard stopped the run before it started; 4 = Codex succeeded but the `--verify` command failed or timed out.
- `status` has its own layout: codex version/login, config.toml model/effort/reviewer, the wrapper's policy, `limits:` (the last rate-limit reading Codex recorded — not live — with its timestamp and source session; if the requested session recorded none, the newest session that did is shown), then with `--last`/SESSION_ID that session's model/sandbox/approval and token totals.
- `status --resets` replaces that `limits:` line with the live one (`live (account/rateLimits/read)` under it) and adds `resets:  N available` with one numbered row per credit: title, `expires <time>`, `id=`. A trailing `(N of M listed or parsed; the server picks which credit to use)` means the list was incomplete, so `--use-reset` lets the server choose instead of the soonest row shown. If the live read fails, the recorded `limits:` line is shown with `resets:  unavailable: <reason>` and exit 1. `--use-reset` adds `reset:   done, used <id>` (or `not used, <reason>`, exit 1) followed by the re-read `limits:` (`after reset, live …`) and `resets:` lines.

Failures: argument errors exit 1 and a missing `codex` exits 2 before Codex runs. When Codex itself fails, the wrapper exits with Codex's code and prints the last 20 lines of its stderr, `--- partial output ---` if a partial message exists, and `codex-run: events log kept at <path>` (`ask`/`delegate`/`resume`, only if the log is non-empty — an empty log is deleted without a message). `resume <SESSION_ID>` that started a different thread exits 1 with "session was NOT resumed" — checked after the run, so a write-mode follow-up may already have changed files; no `thread.started` event at all is only a warning. `CODEX_RUN_KEEP_LOG=1` keeps the log on success too.

## Examples

Second opinion on a design:
```bash
"${CLAUDE_SKILL_DIR}/scripts/codex-run.sh" ask -C "/path/to/project" --effort high <<'EOF'
Goal: assess the risks of moving session storage from Redis to Postgres.
Read src/session/ and its tests. Sessions expire by TTL and several app instances share the store; both must keep working.
Do not modify files or install anything; analysis only.
Answer with risks ranked by severity, each with file:line evidence; list assumptions and anything you could not verify separately.
EOF
```

Built-in review of uncommitted changes:
```bash
"${CLAUDE_SKILL_DIR}/scripts/codex-run.sh" review -C "/path/to/project" --uncommitted
```

Delegate a task, then verify (rule 4):
```bash
"${CLAUDE_SKILL_DIR}/scripts/codex-run.sh" delegate -C "/path/to/project" --verify "npm test" <<'EOF'
Add input validation to POST /users in src/routes/users.ts.
Done when a missing, empty or whitespace-only name returns 400 in the existing error-response shape and valid input behaves as before.
Add a test next to the existing route tests. Keep the current uncommitted changes; no new dependencies. Do not commit.
Run the route tests; if you cannot, report the command and why.
Final message: files changed, what was done, test results, open problems.
EOF
```

Codex setup and remaining rate limit, plus what the last session in this repo used:
```bash
"${CLAUDE_SKILL_DIR}/scripts/codex-run.sh" status -C "/path/to/project" --last
```

Live usage and reset credits, then (after the user confirms, rule 10) spend one:
```bash
"${CLAUDE_SKILL_DIR}/scripts/codex-run.sh" status --resets
"${CLAUDE_SKILL_DIR}/scripts/codex-run.sh" status --use-reset
```

Follow-up on that session (read-only):
```bash
"${CLAUDE_SKILL_DIR}/scripts/codex-run.sh" resume -C "/path/to/project" <session-id> <<'EOF'
Why did you choose a regex over a schema library?
EOF
```
