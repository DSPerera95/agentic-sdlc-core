# Story state

This is the default location - the actual path is `stories_dir` in
`config/orchestration.yaml`, independently configurable and not assumed to
sit under `state/` at all. If you've pointed `stories_dir` elsewhere, this
folder (and this file) won't exist; the same layout below applies wherever
it's configured to.

One directory per story, named `<story-id>-<short-slug>/`, created when
project-planner approves the backlog. Each contains:

- `spec.md` — this story's approved spec (from spec-writer)
- `plan.json` — this story's task graph (from plan-writer; see
  schemas/task-graph.schema.json in agentic-sdlc-core). Drives how
  feature-orchestrator sequences and parallelizes implementer — it is
  internal execution state, not mirrored into the ticket system.
- `ticket.json` — the story's one ticket id (created by story-converter in
  spec mode) plus a short log of the amendment/completion syncs applied to
  it by story-converter in plan mode. There is exactly one ticket per story;
  this file is never a task-level mapping.

These need to be committed as work progresses, not just produced in a chat
session — a different engineer's feature-orchestrator run for a sibling story
may depend on being able to read this story's committed state.
