# Project state

## decision-log.jsonl

Append-only, one compact JSON object per line, matching
`schemas/decision-log.schema.json` in agentic-sdlc-core. Written by
`decision-recorder` — at program scoping, at each story's spec/plan approval,
at delivery, and at every scope amendment, story amendment, or context
escalation. Never skipped regardless of a story's `context_mode`; never
rewritten, only appended to.

Don't hand-edit this file. If you need to remove or correct something in it,
that's a `decision-recorder`-style append (a correction is itself a decision
worth recording), not a manual edit of history.

## decision-log-archive/

Where older entries land once `scripts/rotate-decision-log.ps1` runs — one
file per rotation, named by the date it ran, each entry stripped down to
`id`, `date`, `story_id`, `decision`, and `consequences`. Not loaded by any
`context_mode` automatically; a story or a person consults an archive file
directly only when there's a specific reason to look at older history.

Rotation isn't automatic — run the script yourself, periodically, or before
kicking off `/project-scoper` again on an existing project:

```powershell
.claude/scripts/rotate-decision-log.ps1
```

Thresholds default to 6 months / 200 entries; override with
`-MaxAgeMonths`/`-MaxEntries` to match `config/orchestration.yaml`'s
`decision_log_rotation` block, or run with `-DryRun` first to see what it
would do.

## stories/

See `stories/README.md`.
