---
name: decision-recorder
description: >
  Records architecture and implementation decisions, tradeoffs, assumptions, and rejected alternatives to the shared decision log. Invoked by project-planner and feature-orchestrator at every approval gate, at delivery, and at every scope or story amendment — unconditionally, regardless of a story's context_mode.
user-invocable: false
---

Runs inline, deliberately, not as an isolated agent — the decision being recorded just happened in this same conversation, so writing it up benefits from the full context of how it was made rather than a summary handed in from outside. It's also invoked at least three times per story plus every amendment, the highest frequency of anything in this system; re-establishing context that's already present, over and over, has no upside here.

Record the decision that was just made in this session, matching `decision-log.schema.json`. Where it's written depends on this project's `state_backend` in `config/orchestration.yaml`:
- `file` (default): one line appended to `.claude/state/decision-log.jsonl` — JSON Lines, one compact object per line. Never rewrite existing lines; only append.
- `turso`: one row inserted via the `turso-state` MCP server's `append_decision` tool. The tool assigns the sequential id itself, atomically, at the database — skip step 1 below entirely in this mode, and use the `id` the tool call returns.

To write an entry:
1. **file mode only** — if `decision-log.jsonl` exists, read it and find the highest `DEC-####` id present. Use the next number. If the file doesn't exist or is empty, start at `DEC-0001`. **turso mode skips this step** — `append_decision` assigns the id.
2. Construct the entry with:
   - `date` — today, ISO 8601 (`YYYY-MM-DD`)
   - `story_id` — the current story's id, or `program` if this is being recorded during /project-planner
   - `significance` — `architectural` if the calling skill tells you this one is (service boundaries, data ownership, integration patterns, an irreversible or foundational choice), otherwise `routine`. This isn't your judgment call — record whatever the caller states; if it states nothing, default to `routine`.
   - `context` — what situation led to this decision
   - `decision` — what was decided
   - `reasoning` — why
   - `alternatives_considered` — what else was on the table
   - `consequences` — what this leads to
   - `tradeoffs` — what was given up
3. Write it:
   - **file mode**: prepend the `id` from step 1, and append the whole object as a single compact JSON line — no pretty-printing, one line per entry, consistent with every other line in the file.
   - **turso mode**: call `append_decision` with the fields from step 2 (no `id` — the tool assigns it). Use the `id` the tool returns for anything else this call needs to reference. If the call fails (network, auth, Turso outage), that's a hard stop — surface the error to whatever invoked decision-recorder rather than retrying silently or falling back to file mode.

Keep entries concise and implementation-relevant, but capture enough that someone with none of this conversation — a different engineer, a different story, weeks later — can understand what happened and why. Never skip a write when invoked.

Don't worry about the log growing large over a project's lifetime — periodic rotation (`scripts/rotate-decision-log.ps1`) moves older entries into a compressed archive, and `significance: architectural` entries can be rendered as ADR files (`scripts/export-adrs.ps1`) — both run separately and aren't something this skill needs to think about.
