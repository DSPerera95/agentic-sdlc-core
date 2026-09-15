# Project state

## decision-log.jsonl

Append-only, one compact JSON object per line, matching
`schemas/decision-log.schema.json` in agentic-sdlc-core. Written by
`decision-recorder` — at program planning, at each story's spec/plan approval,
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
kicking off `/project-planner` again on an existing project:

```powershell
.claude/scripts/rotate-decision-log.ps1
```

Thresholds default to 6 months / 200 entries; override with
`-MaxAgeMonths`/`-MaxEntries` to match `config/orchestration.yaml`'s
`decision_log_rotation` block, or run with `-DryRun` first to see what it
would do.

## story-backlog.json

Written once per project by `story-converter` in spec mode, matching
`schemas/story-backlog.schema.json` in agentic-sdlc-core. A single JSON
object (`project`, `program_spec_ref`, `architecture_mode`, `stories`) - not
JSON Lines, since it's written once rather than appended to. A point-in-time
snapshot of what spec mode produced: `story-converter`'s plan mode (ticket
syncs on scope/story amendment or completion) never rewrites this file, only
the ticket system reflects what changed after creation.

If `project-planner` runs again against a project that's already been
planned, `story-converter` reads this file first so it doesn't duplicate an
existing story id or recreate a ticket that already exists.

## stories/ (path configurable)

Defaults to `state/stories/`, but the actual location comes from
`stories_dir` in `config/orchestration.yaml` - it isn't assumed to sit
under `state/` at all, so check that value rather than assuming this path.
See `stories/README.md` (or wherever `stories_dir` actually points) for
what lives inside each story's own directory.
