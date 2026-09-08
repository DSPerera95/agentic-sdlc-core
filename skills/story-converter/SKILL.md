---
name: story-converter
description: >
  Converts either a program-level spec or an approved implementation plan into Jira or Azure DevOps epics, user stories, tasks, subtasks, and acceptance criteria. Two modes: spec mode (program spec → initial story backlog, no technical tasks yet — used once per project by /project-scoper) and plan mode (a story's implementation plan → tracked tasks, created when the plan is approved and synced as it changes or completes — used repeatedly across a /feature-orchestrator run).
user-invocable: true
---

## Spec mode — program spec into a story backlog

Used once per project, by /project-scoper, before any story has its own implementation plan.

Convert the approved program-level spec into:
- epics
- user stories, each with acceptance criteria
- dependencies between stories, where genuinely required — avoid inventing sequencing that doesn't exist
- a `context_mode` per story: `full-spec`, `decision-log-only`, or `independent`, based on whether the story touches shared or foundational surface. Default to the project's configured default; override per story only with clear reason (e.g. a story modifying the shared auth layer gets `full-spec` even if the project default is `independent`)

Do not generate technical tasks or subtasks in this mode. No implementation plan exists yet for any story, so there's nothing to decompose into tasks — stories at this stage are acceptance-criteria-level only.

## Plan mode — implementation plan into tracked work

Used per story, invoked multiple times across a single /feature-orchestrator run rather than once at the end:

- **First invocation** — right after the plan is approved, before implementation starts. Create one ticket per task id, carrying that task's description, `depends_on`, `parallel_group`, `files_touched`, and acceptance criteria. This is what makes tasks visible and assignable while work happens, not just after — the point where tasks in the same `parallel_group` could be picked up by different engineers, not only AI subagents.
- **Later invocations** — whenever the Scope amendment loop or Story amendment loop changes the plan, and once more at story completion. These are syncs, not fresh conversions: match against ticket-to-task-id mappings already created, update existing tickets rather than duplicating them, add tickets only for genuinely new tasks, and mark tickets complete at final sync.

Convert into:
- technical tasks (one per task id)
- subtasks, where a task's scope genuinely needs breaking down further
- acceptance criteria — inherited from the story, refined if the plan revealed detail the story level didn't have
- dependencies, mapped directly from `depends_on`

## Both modes

Ensure:
- stories/tasks are independently understandable
- tasks are implementation-oriented
- acceptance criteria are measurable
- work remains properly scoped
- tasks map directly to implementation work

Prefer:
- small actionable stories
- deterministic acceptance criteria
- clear technical descriptions

Avoid:
- vague stories
- oversized tasks
- unrelated work grouping
- ambiguous acceptance criteria
- generating technical tasks in spec mode, or omitting them in plan mode — each mode's output shape is deliberate, not interchangeable
- duplicating a ticket for a task id that already has one — later plan-mode invocations sync existing tickets, they don't recreate them

Structure output cleanly for Jira or Azure DevOps import.
