---
name: story-converter
description: >
  Converts a program-level spec into Jira or Azure DevOps epics and user stories. This is the only place stories get created in the tracker — one story, one ticket. Also syncs an existing story's ticket, but only when /feature-orchestrator's amendment loops surface something that changed, or when a story reaches a terminal status.
user-invocable: true
---

## Spec mode — program spec into a story backlog

Used once per project, by /project-scoper, before any story has its own implementation plan. This is where tickets get created — nowhere else.

Convert the approved program-level spec into:
- epics
- user stories, each with acceptance criteria
- dependencies between stories, where genuinely required — avoid inventing sequencing that doesn't exist
- a `context_mode` per story: `full-spec`, `decision-log-only`, or `independent`, based on whether the story touches shared or foundational surface. Default to the project's configured default; override per story only with clear reason (e.g. a story modifying the shared auth layer gets `full-spec` even if the project default is `independent`)

Create one ticket per story in the configured ticket system, and record the resulting ticket id on the story entry. Do not generate technical tasks or subtasks in this mode. No implementation plan exists yet for any story, so there's nothing to decompose into tasks — a story's ticket stays at the acceptance-criteria level until something during implementation gives reason to update it.

## Plan mode — syncing a story's existing ticket

Used per story, but only when /feature-orchestrator calls it — never on a routine schedule, and never right after a plan is approved. There is exactly one ticket per story, created back in spec mode; plan mode updates that same ticket, it never creates a new one.

/feature-orchestrator invokes this in three situations, and no others:
- **Scope amendment** — /implementer needed a file outside its declared `files_touched`. Reflect the amended scope on the story's ticket.
- **Story amendment** — acceptance criteria changed after the spec was approved. Reflect the new criteria and note what changed and why.
- **Story completion** — the story passed validation. Mark the ticket's status complete.

In every case, this is an update to the one existing ticket, not a fresh conversion: pull the ticket id from the story's state, describe the specific delta (what changed, not the whole plan restated), and leave everything else on the ticket untouched. The full task graph (`depends_on`, `parallel_group`, `files_touched` per task) stays internal to /implementation-planner's output — it drives how /feature-orchestrator sequences and parallelizes /implementer, but it isn't mirrored into the tracker as separate tasks or subtasks.

## Both modes

Ensure:
- stories are independently understandable
- acceptance criteria are measurable
- work remains properly scoped

Prefer:
- small actionable stories
- deterministic acceptance criteria
- clear technical descriptions

Avoid:
- vague stories
- ambiguous acceptance criteria
- creating a second ticket for a story that already has one — plan mode always updates the existing ticket by id
- restating the whole story or plan on every sync — describe the delta, not the total state

Structure output cleanly for Jira or Azure DevOps import.
