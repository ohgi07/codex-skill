# status, live usage and reset credits

## Calls

Codex setup and the last recorded rate limit, plus what the last session in this repo used (offline, no API call;
reads `$CODEX_HOME`, default `~/.codex`):
```bash
"${CLAUDE_SKILL_DIR}/scripts/codex-run.sh" status -C "/path/to/project" --last
```
`--last` picks the newest session started in `-C DIR` (the auto-reviewer's threads are skipped); a SESSION_ID
picks that session. `-m` / `--effort` are not valid for `status`.

Live usage and reset credits (read-only API call through `codex app-server`):
```bash
"${CLAUDE_SKILL_DIR}/scripts/codex-run.sh" status --resets
```

Spend one credit — only after the user confirmed this specific reset in chat (SKILL.md rule 10), and only once:
```bash
"${CLAUDE_SKILL_DIR}/scripts/codex-run.sh" status --use-reset
```

## Layout

- Header: codex version and login, config.toml `model` / `model_reasoning_effort` / `approvals_reviewer`, the
  policy the wrapper applies.
- `limits:` — the last rate-limit reading Codex recorded, **not live**, with its timestamp and source session. It
  comes from the most recently written session file that has a reading (a resumed older session can hold the
  latest one). If the requested session recorded none, the newest reading overall is shown.
- With `--last` / SESSION_ID: that session's model, effort, sandbox, approval policy and token totals
  (cumulative over the whole session, resumes included).

`status --resets` replaces the `limits:` line with the live one (`live (account/rateLimits/read)` under it) and
adds `resets:  N available` with one numbered row per credit, soonest expiry first: title, `expires <time>`,
`id=`. A trailing `(N of M listed or parsed; the server picks which credit to use)` means the list was incomplete,
so `--use-reset` lets the server choose instead of the soonest row shown. If the live read fails, the recorded
`limits:` line is shown with `resets:  unavailable: <reason>` and exit 1.

`status --use-reset` adds `reset:   done, used <id>` (or `not used, <reason>`, exit 1), then the re-read
`limits:` (`after reset, live …`) and `resets:` lines. `nothingToReset` means no window was eligible: report it,
do not retry. A re-run is a new attempt and can spend another credit.
