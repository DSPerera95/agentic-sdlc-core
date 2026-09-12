---
name: project-scoper
description: >
  Entry point for scoping a new project or engagement from a PRD, requirements document, or an existing repository. Analyzes the input, runs a scope-defining grill-me session (or a deeper architecture-mode session, if requested), produces a program-level spec, and converts it into an initial story backlog. Use at project kickoff, before any individual feature work begins — for greenfield projects with a PRD/requirements doc, or brownfield projects with an existing repo that needs scoping.
user-invocable: true
---

# Program-level scoping

Runs once per project or engagement, before any story-level work begins. Produces the story backlog that individual /feature-orchestrator runs will later pick up one at a time, often by different engineers.

The story-converter agent (Phase 5) is a fixed-identity subagent, not a skill — always isolated, always on Claude Haiku 4.5, same as its default tier when /feature-orchestrator calls it. /decision-recorder (Phase 4) runs inline instead, same reasoning as in /feature-orchestrator: it's capturing this session's own reasoning, so isolating it would mean re-explaining that reasoning rather than saving anything.

## Architecture mode

Off by default. Turn it on only when explicitly requested at invocation (e.g. "greenfield, use architecture mode") — this skill doesn't infer it from the PRD or from what /repo-discovery finds. When on, it changes Phase 2 and Phase 3 below, and nothing else; /grill-me and /spec-writer themselves are unchanged, since the constraint that normally keeps them scope-level lives entirely in how this skill instructs them, not in either of their own files.

## Phase 1 — Understand the starting point

- If a PRD, requirements document, or other client documents are provided: read them in full before proceeding.
- If an existing repository is provided (brownfield): invoke /repo-discovery for a broad, architecture-level pass — not scoped to any single story yet.
- If both are provided, do both before moving to Phase 2.

## Phase 2 — Define scope

**Architecture mode off (default):** invoke /grill-me, scope-defining rather than feature-defining — resolve ambiguity about what's in scope, what's explicitly out of scope, target users, constraints, and priorities for the engagement as a whole, not implementation detail for any single feature.

**Architecture mode on:** invoke /grill-me with the opposite instruction — go deep. Service boundaries, data ownership, integration patterns, and other decisions that can't safely be deferred to individual stories without risking one story's implementation conflicting with a boundary an earlier story assumed. This is real design work, not scope clarification; let it take as many questions as it needs.

STOP. Wait for user answers before proceeding.

## Phase 3 — Program-level spec

**Architecture mode off (default):** invoke /spec-writer to produce a spec covering the whole engagement's scope. Overview, functional requirements, architecture overview, out-of-scope, and acceptance criteria should be filled in fully; API changes, database changes, and other implementation-level sections may stay high-level or be marked "to be determined per story" — that detail belongs to each story's own /spec-writer pass later, not here.

**Architecture mode on:** invoke /spec-writer with the same overall coverage, but write the API/database/integration detail down now rather than deferring it — Phase 2's deeper /grill-me pass actually produced that detail, and deferring it after going to the trouble of surfacing it would throw the work away.

STOP. Present spec. Ask: "Approve program spec? (yes / feedback)"
Do not proceed until approved.

## Phase 4 — Record scoping decisions

Invoke /decision-recorder to capture the scope decisions made in Phases 2-3. This becomes the shared reference every story can draw on later, regardless of any individual story's `context_mode`. If architecture mode was on for this run, also record that fact and why, tagged `significance: architectural`.

## Phase 5 — Story backlog

Delegate to the story-converter agent, in spec mode, against the approved program spec. Read `context_mode_default` and `stories_dir` from `config/orchestration.yaml` and pass both explicitly, alongside whether architecture mode was on for this run — story-converter has no project config access of its own, so all three have to come from you, not be assumed. story-converter sets `architecture_mode` on the backlog output (see `story-backlog.schema.json`) and weighs it toward more stories defaulting to `full-spec` context_mode, since a project that warranted deep upfront design is more likely to have stories touching shared surface those decisions established.

For each resulting story, story-converter also assigns a `context_mode`:
- `full-spec` — story touches shared or foundational surface (auth, shared schema, core interfaces); its /feature-orchestrator run should load the full program spec as reference
- `decision-log-only` — story is largely independent but should stay aware of engagement-wide decisions
- `independent` — story is fully self-contained

The default `context_mode` for the project is the `context_mode_default` value you just passed in; story-converter may override it per story where it has clear reason to.

STOP. Present the story backlog with each story's `context_mode`. Ask: "Approve backlog? (yes / feedback)"

## Guardrails

- Never generate implementation-level tasks, file lists, or technical plans here — that's /implementation-planner's job, once per story, later. This holds even in architecture mode: deeper design detail in the spec is not the same thing as a task breakdown.
- Never skip Phase 2 even if a PRD looks complete — written requirements from a client still need a clarification pass.
- If the repo (brownfield) reveals a hard architectural constraint that conflicts with the PRD, surface it before writing the spec rather than writing around it silently.
- Never turn architecture mode on unrequested, and never silently skip it when it was explicitly requested — it's an explicit choice made once at invocation, not something to infer or second-guess mid-run.
- This skill produces the backlog; it does not execute any story. Hand each approved story off to /feature-orchestrator as an independent run — except a story with a non-empty `depends_on`, which shouldn't be handed off until every story it depends on has actually merged, not just started. `depends_on` is meaningless if nothing checks it. It should also be rare: story-converter only sets it for genuine contract dependencies, not for stories that would merely benefit from awareness of each other — that case is handled by context escalation inside each story's own run, not by blocking at scoping time.
