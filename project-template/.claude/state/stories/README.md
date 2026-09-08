# Story state

One directory per story, named `<story-id>-<short-slug>/`, created when
project-scoper approves the backlog. Each contains:

- `spec.md` — this story's approved spec (from spec-writer)
- `plan.json` — this story's task graph (from implementation-planner; see
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
