# Story state

This is the default location - the actual path is `stories_dir` in
`config/orchestration.yaml`, independently configurable and not assumed to
sit under `state/` at all. If you've pointed `stories_dir` elsewhere, this
folder (and this file) won't exist; the same layout below applies wherever
it's configured to.

One directory per story, named `<story-id>/` (story id only - no slug in
the directory name), created when project-planner approves the backlog.
Each contains:

- `ticket.json` — the story's one ticket id (created by story-converter in
  spec mode), the `slug` story-converter derived from the story's title,
  plus a short log of the amendment/completion syncs applied to it by
  story-converter in plan mode. There is exactly one ticket per story; this
  file is never a task-level mapping.
- `spec/` — this story's approved spec (from spec-writer), one file per
  version: `<name>-v1.md`, `<name>-v2.md` if a Story amendment produced a
  new approved version, and so on. `<name>` comes from rendering
  `story_file_name_format` (in `config/orchestration.yaml`) against this
  story's `ticket_id`/`slug` - e.g. `{ticket_id}-{slug}` produces
  `MPMD-123-project-scaffold-v1.md`. The current version is whichever has
  the highest `-v<N>` - there's no separate pointer file, it's always
  resolved from what's actually on disk.
- `plan/` — this story's task graph (from plan-writer; see
  schemas/task-graph.schema.json in agentic-sdlc-core), versioned the same
  way as `spec/` and independently of it - amending the plan doesn't bump
  the spec's version or vice versa. Drives how feature-orchestrator
  sequences and parallelizes implementer — it is internal execution state,
  not mirrored into the ticket system. Routine per-task `status` updates
  during execution happen in place on the current version and do not
  create a new one; only an actual content amendment (a Scope or Story
  amendment) does.

These need to be committed as work progresses, not just produced in a chat
session — a different engineer's feature-orchestrator run for a sibling story
may depend on being able to read this story's committed state.
