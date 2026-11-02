# Consulting Codex over several turns

For when the user wants Claude and Codex to exchange views ("코덱스랑 의견 주고받아", "debate it with Codex"),
not a single second opinion. Everything in SKILL.md still applies; this adds the round structure.

## Ground rules

- **2 Codex calls by default, 3 at most.** One `ask`, then `resume` calls.
- **Same session throughout:** pass the UUID from the first `session:` line to every `resume`. Never `--last`:
  any other Codex run in the same directory in the meantime would take over.
- **Read-only.** A discussion never authorises file changes; if it ends in "let's change X", that is a separate
  `delegate` (or Claude's own edit) after the user agrees.
- Each call follows rule 3 in SKILL.md (background, wait for the notification).

## Round 1 — independent review (`ask`)

Send: goal, the criteria for a good answer, paths to read, constraints, observed facts, open questions,
decisions already made (marked as decided).

- **If the point is to find problems Claude has not seen,** keep Claude's candidate solutions and preferences out
  of this turn; they would anchor the answer. Send them in round 2.
- **If the point is to critique a specific proposal,** include the proposal in this turn.

Ask for: every important claim with an ID (`C1`, `C2`, …), its evidence (`file:line`, command output, or source),
assumptions and unverified points listed separately.

## Between rounds — Claude's own check

Spot-check the evidence behind each claim Codex made (rule 5): open the cited lines, run what can be run.
Note which claims held up, which did not, and why.

## Round 2 — counterpoints and re-evaluation (`resume <uuid>`)

Send:
- what changed since round 1 (files, decisions; usually nothing in a read-only discussion),
- the result of Claude's spot-check, per claim ID,
- Claude's counterpoints and new evidence, per claim ID,
- any candidate solutions held back in round 1.

Ask for: per claim, **keep / revise / withdraw** with the reason; the changed recommendations; only the issues
that remain open. Not a full rewrite of round 1.

## Round 3 — only if it would change the outcome (`resume <uuid>`)

Run it only when an important open issue has new evidence, or a concrete question this call can settle. Send that
issue and the new material only. Ask whether anything changes the recommendation.

## Stop

Stop as soon as there is enough to decide. Also stop when there is no new evidence or checkable question, or the
call limit is reached. Never add a call just to reach agreement; disagreement is a valid result.

## Report to the user

1. What Claude and Codex agree on (attributed: "Codex says …", "I checked …").
2. What remains disputed, with each side's reason.
3. Claude's own judgement, clearly marked as Claude's.
4. What neither side verified.
5. A concrete next step if one follows (e.g. implementing the agreed items), asked as a question.
