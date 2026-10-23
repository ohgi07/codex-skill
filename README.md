# codex-skill

A [Claude Code](https://docs.claude.com/en/docs/claude-code) skill that lets Claude call the locally installed
[OpenAI Codex CLI](https://github.com/openai/codex) for a second opinion, a code review, or a delegated
implementation task — and then check Codex's work instead of taking its word for it.

You ask in plain language ("ask Codex what it thinks of this design", "codex 리뷰 해줘", "have Codex implement
this"), and Claude runs the wrapper script with the right mode, sandbox and prompt, then reports Codex's answer
separately from its own assessment.

## What it does

| mode | what Codex can do | typical request |
|---|---|---|
| `review` | read only | "Have Codex review my uncommitted changes" |
| `ask` | read only | "Ask Codex for a second opinion on this approach" |
| `delegate` | edit files in the project | "Let Codex implement the validation" |
| `resume` | read only by default, write on request | "Ask Codex why it chose that" |
| `status` | nothing (reads local Codex state) | "How much Codex usage do I have left?" |

What the wrapper adds on top of `codex exec`:

- **Real sandboxing for read-only modes.** `ask`, `review` and read-only `resume` run with Codex's read-only
  sandbox and `approval_policy=never`, so a "just look" request cannot turn into file edits.
- **Verification after write runs.** `delegate` snapshots the tree before and after and prints which files Codex
  touched, which changes were already there, whether HEAD moved, and suspicious phrases in Codex's reply
  ("could not", "skipped"). `--verify "npm test"` runs your test command afterwards.
- **A usage guard.** Write runs and high-effort runs stop before starting when Codex's last recorded rate-limit
  usage is above a threshold (default 80%), so Claude asks you first.
- **Status without an API call.** `status` shows the Codex version, login, configured model and effort, and token
  totals of a past session from `~/.codex`; `status --resets` reads live limits and reset credits.
- **No silent commits.** Delegated prompts end with "Do not commit"; Claude reviews the diff and commits itself.

`SKILL.md` holds the rules Claude follows; `DESIGN.md` explains why the wrapper works the way it does.

## Requirements

- Claude Code
- Codex CLI on `PATH` and logged in (`npm i -g @openai/codex`, then `codex login`)
- bash 4 or newer, git, and coreutils. On Windows, the Git Bash that Claude Code uses is enough. On macOS the
  system bash (3.2) is too old; install a newer one, e.g. `brew install bash`.

Developed and tested on Windows with Git Bash. Other platforms should work wherever the requirements are met, but
have seen less testing.

## Install

Clone into your user-level skills folder so it is available in every project:

```bash
git clone https://github.com/ohgi07/codex-skill.git ~/.claude/skills/codex
```

Restart Claude Code (or start a new session) and the `codex` skill appears in its skill list. The folder must be
named `codex`: `SKILL.md` calls the wrapper at `~/.claude/skills/codex/scripts/codex-run.sh`.

## Using the wrapper directly

Claude normally runs it for you, but it works on its own too:

```bash
~/.claude/skills/codex/scripts/codex-run.sh --help

~/.claude/skills/codex/scripts/codex-run.sh review -C "/path/to/project" --uncommitted

~/.claude/skills/codex/scripts/codex-run.sh ask -C "/path/to/project" --effort high <<'EOF'
What are the risks of moving session storage from Redis to Postgres? Read src/session/ first.
EOF
```

Environment variables: `CODEX_RUN_USAGE_LIMIT` (guard threshold in percent, or `off`), `CODEX_RUN_VERIFY_TIMEOUT`
(seconds, default 600), `CODEX_RUN_KEEP_LOG=1` (keep the raw event log), and on Windows
`CODEX_RUN_WINDOWS_SANDBOX=elevated` (use Codex's elevated sandbox backend).

## Tests

```bash
bash tests/test-unit.sh    # offline; puts a fake `codex` on PATH
bash tests/test-smoke.sh   # calls the real Codex CLI and uses your Codex quota
```

## Notes

- `delegate` lets Codex change files on disk immediately, and `--verify` runs a command with your own permissions
  outside Codex's sandbox. Read the diff before trusting either.
- `status --use-reset` spends a rate-limit reset credit and cannot be undone. The skill tells Claude to do it only
  after you confirm.
- This is an independent project, not affiliated with OpenAI or Anthropic.

## License

[MIT](LICENSE)
