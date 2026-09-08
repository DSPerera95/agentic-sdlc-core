---
name: project-scoper
description: >
  Entry point for scoping a new project or engagement from a PRD, requirements document, or an existing repository. Analyzes the input, runs a scope-defining grill-me session, produces a program-level spec, and converts it into an initial story backlog. Use at project kickoff, before any individual feature work begins — for greenfield projects with a PRD/requirements doc, or brownfield projects with an existing repo that needs scoping.
user-invocable: true
---

# Program-level scoping

Runs once per project or engagement, before any story-level work begins. Produces the story backlog that individual /feature-orchestrator runs will later pick up one at a time, often by different engineers.

## Phase 1 — Understand the starting point

- If a PRD, requirements document, or other client documents are provided: read them in full before proceeding.
- If an existing repository is provided (brownfield): invoke /repo-discovery for a broad, architecture-level pass — not scoped to any single story yet.
- If both are provided, do both before moving to Phase 2.

## Phase 2 — Define scope

Invoke /grill-me, scope-defining rather than feature-defining: resolve ambiguity about what's in scope, what's explicitly out of scope, target users, constraints, and priorities for the engagement as a whole — not implementation detail for any single feature.

STOP. Wait for user answers before proceeding.

## Phase 3 — Program-level spec

Invoke /spec-writer to produce a spec covering the whole engagement's scope. At this level:
- overview, functional requirements, architecture overview, out-of-scope, and acceptance criteria should be filled in fully
- API changes, database changes, and other implementation-level sections may stay high-level or be marked "to be determined per story" — that detail belongs to each story's own /spec-writer pass later, not here

STOP. Present spec. Ask: "Approve program spec? (yes / feedback)"
Do not proceed until approved.

## Phase 4 — Record scoping decisions

Invoke /decision-recorder to capture the scope decisions made in Phases 2-3. This becomes the shared reference every story can draw on later, regardless of any individual story's `context_mode`.

## Phase 5 — Story backlog

Invoke /story-converter in spec mode against the approved program spec. For each resulting story, /story-converter also assigns a `context_mode`:
- `full-spec` — story touches shared or foundational surface (auth, shared schema, core interfaces); its /feature-orchestrator run should load the full program spec as reference
- `decision-log-only` — story is largely independent but should stay aware of engagement-wide decisions
- `independent` — story is fully self-contained

The default `context_mode` for the project comes from project config; /story-converter may override it per story where it has clear reason to.

STOP. Present the story backlog with each story's `context_mode`. Ask: "Approve backlog? (yes / feedback)"

## Guardrails

- Never generate implementation-level tasks, file lists, or technical plans here — that's /implementation-planner's job, once per story, later.
- Never skip Phase 2 even if a PRD looks complete — written requirements from a client still need a clarification pass.
- If the repo (brownfield) reveals a hard architectural constraint that conflicts with the PRD, surface it before writing the spec rather than writing around it silently.
- This skill produces the backlog; it does not execute any story. Hand each approved story off to /feature-orchestrator as an independent run.
