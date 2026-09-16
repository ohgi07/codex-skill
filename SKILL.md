---
name: codex
description: Call the locally installed OpenAI Codex CLI from Claude Code — for a Codex second opinion, a Codex code review, or delegating an implementation task to Codex and verifying its result. Use when the user says "codex", "코덱스", "codex 리뷰", "codex한테 시켜/맡겨", "코덱스한테도 물어봐", "Codex second opinion", or "다른 모델, 특히 Codex 의견". Do NOT use for generic "think about it from another angle" requests that don't name Codex.
---

# Codex

Wrapper script (bash — run it with the Bash tool):

```
~/.claude/skills/codex/scripts/codex-run.sh <mode> [-C DIR] [options] [PROMPT | -]
```

## Modes

| mode | use when | permissions | notes |
|---|---|---|---|
| `review` | user wants Codex's built-in code review of a diff | read-only | target: `--uncommitted` (default), `--base BRANCH`, `--commit SHA`. **No PROMPT** — free-form review instructions go through `ask`. |
| `ask` | second opinion, explanation, design critique, free-form review | read-only | Codex can read the repo but cannot write. |
| `delegate` | user asks Codex to implement / modify something | workspace-write | approvals go through Codex automatic review. |
| `resume` | follow-up on a previous Codex session | `--mode read-only` (default) or `--mode workspace-write` | `--last` or the `session:` id printed earlier. |

Shared options: `-C DIR` (project root), `-m MODEL`, `--effort low|medium|high|…` (passthrough to Codex's `model_reasoning_effort`).

## Rules

1. **Always pass `-C` with the absolute project path** (forward slashes, e.g. `-C "D:/Code Projects/x"`). The wrapper `cd`s there; `resume --last` is scoped to that directory.
2. **Feed the prompt on stdin with a quoted heredoc** — no shell-quoting problems, multi-line friendly:
   ```bash
   ~/.claude/skills/codex/scripts/codex-run.sh ask -C "D:/Code Projects/x" <<'EOF'
   Review src/auth.ts for security issues. Focus on token handling.
   EOF
   ```
3. **Timeouts:** use Bash tool `timeout: 600000`. For large delegations use `run_in_background: true` and report to the user when it finishes.
4. **After `delegate` (or `resume --mode workspace-write`): run `git diff` and review the changes yourself before telling the user it's done.** Codex's output is a proposal, not a verified result. The trailer `--- git status after Codex ---` is a plain `git status --short` — on a dirty tree it also lists pre-existing changes.
5. **Attribute Codex's answer as Codex's** (e.g. "Codex says: …") and keep your own assessment clearly separate.
6. **`resume` defaults to read-only.** Pass `--mode workspace-write` only when the follow-up is meant to edit files.
7. **Never** edit the wrapper to add `--dangerously-*` flags, and never call `codex` directly with them.

## Output format

```
[codex <mode>] cwd=<dir> model=<model|default>
session: <id>                      ← use this with `resume <id>`

<Codex's final message>

--- git status after Codex ---     ← delegate / resume --mode workspace-write only
 M src/foo.ts
?? src/bar.ts
```

On failure the wrapper prints Codex's stderr tail and `codex-run: events log kept at <path>` (raw JSONL for debugging). `CODEX_RUN_KEEP_LOG=1` keeps the log on success too.

## Examples

Codex second opinion on a design:
```bash
~/.claude/skills/codex/scripts/codex-run.sh ask -C "D:/Code Projects/x" --effort high <<'EOF'
We plan to move session storage from Redis to Postgres. Read src/session/ and list the risks.
EOF
```

Built-in review of uncommitted changes:
```bash
~/.claude/skills/codex/scripts/codex-run.sh review -C "D:/Code Projects/x" --uncommitted
```

Delegate a task, then verify:
```bash
~/.claude/skills/codex/scripts/codex-run.sh delegate -C "D:/Code Projects/x" <<'EOF'
Add input validation to POST /users in src/routes/users.ts. Reject empty names. Add a test.
EOF
```
then `git -C "D:/Code Projects/x" diff` and read it before reporting.

Follow-up on that session (read-only):
```bash
~/.claude/skills/codex/scripts/codex-run.sh resume -C "D:/Code Projects/x" <session-id> <<'EOF'
Why did you choose a regex over a schema library?
EOF
```
