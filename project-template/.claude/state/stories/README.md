# Story state

One directory per story, named `<story-id>-<short-slug>/`, created when
project-scoper approves the backlog. Each contains:

- `spec.md` — this story's approved spec (from spec-writer)
- `plan.json` — this story's task graph (from implementation-planner; see
  schemas/task-graph.schema.json in agentic-sdlc-core)
- `tickets.json` — task id → ticket id mapping, maintained by story-converter
  in plan mode across its repeated create/sync invocations

These need to be committed as work progresses, not just produced in a chat
session — a different engineer's feature-orchestrator run for a sibling story
may depend on being able to read this story's committed state.
