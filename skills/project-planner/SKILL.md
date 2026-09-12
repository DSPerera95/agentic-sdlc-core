---
name: project-planner
description: >
  Entry point for planning a new project or engagement from a PRD, requirements document, or an existing repository. Analyzes the input, runs a project-level grill-me session (or a deeper architecture-mode session, if requested — which also proposes and generates architecture diagrams), produces a program-level spec, and converts it into an initial story backlog. Use at project kickoff, before any individual feature work begins — for greenfield projects with a PRD/requirements doc, or brownfield projects with an existing repo that needs planning.
user-invocable: true
---

# Program-level planning

Runs once per project or engagement, before any story-level work begins. Produces the story backlog that individual /feature-orchestrator runs will later pick up one at a time, often by different engineers.

The story-converter agent (Phase 6) is a fixed-identity subagent, not a skill — always isolated, always on Claude Haiku 4.5, same as its default tier when /feature-orchestrator calls it. /decision-recorder (Phase 5) runs inline instead, same reasoning as in /feature-orchestrator: it's capturing this session's own reasoning, so isolating it would mean re-explaining that reasoning rather than saving anything.

## Architecture mode

Off by default. Turn it on only when explicitly requested at invocation (e.g. "greenfield, use architecture mode") — this skill doesn't infer it from the PRD or from what /repo-discovery finds. When on, it changes Phase 2's posture below, adds Phase 3 entirely (skipped in default mode), and adds one instruction to Phase 4; nothing else. /grill-me and /spec-writer themselves are unchanged, since the constraint that normally keeps them project-level lives entirely in how this skill instructs them, not in either of their own files.

## Phase 1 — Understand the starting point

- If a PRD, requirements document, or other client documents are provided: read them in full before proceeding.
- If an existing repository is provided (brownfield): invoke /repo-discovery for a broad, architecture-level pass — not scoped to any single story yet.
- If both are provided, do both before moving to Phase 2.

## Phase 2 — Define scope

**Architecture mode off (default):** invoke /grill-me, project-level rather than feature-level — resolve ambiguity about what's in scope, what's explicitly out of scope, target users, constraints, and priorities for the engagement as a whole, not implementation detail for any single feature.

**Architecture mode on:** invoke /grill-me with the opposite instruction — go deep. Service boundaries, data ownership, integration patterns, and other decisions that can't safely be deferred to individual stories without risking one story's implementation conflicting with a boundary an earlier story assumed. This is real design work, not scope clarification; let it take as many questions as it needs. Additionally, /grill-me must not accept a stated architectural decision at face value: for each one, it must state a specific concern, risk, or trade-off before accepting it, or propose an alternative — the way a senior architect reviewing a peer's design would, not the way a facilitator merely records what's said. This is a directive on posture, not just depth, and it has no mechanical enforcement — it raises the odds of a genuinely challenging session, it doesn't guarantee one.

STOP. Wait for user answers before proceeding.

## Phase 3 — Architecture diagrams (architecture mode only)

Skipped entirely in default mode — go directly from Phase 2 to Phase 4.

1. Based on what Phase 2's grilling surfaced, propose a diagram list:
   - Always propose: a C4 Context diagram and a C4 Container diagram.
   - Propose a data flow, sequence, activity, deployment, or integration/network architecture diagram only where something specific from Phase 2 grounds it — state that grounding in one line per proposed diagram (e.g. "sequence diagram for the checkout flow — Phase 2 surfaced a multi-service transaction boundary here"). Never propose one with no such grounding.

STOP. Present the proposed list with each diagram's one-line grounding. Ask: "Which of these should I generate? (list which ones, 'all', or 'none')"
Do not proceed until the user responds. A C4 diagram can be deselected too — this is a strong proposal, not a forced inclusion; the user is the actual architect here.

2. Read `diagrams_dir` from `config/orchestration.yaml`. For each selected diagram, generate it as Mermaid and write it to `<diagrams_dir>/<diagram-name>.mmd`, using descriptive, kebab-case filenames: `c4-context.mmd`, `c4-container.mmd`, `sequence-checkout.mmd`, `deployment-overview.mmd`, and so on.

3. Self-check (mechanical, not just instructed): after writing, confirm every selected diagram's file actually exists at its expected path under `diagrams_dir`. If any is missing, do not proceed to Phase 4 — report which one(s) are missing and retry writing them before continuing. This is a fact to verify, not an instruction to trust silently succeeded.

If the user selected "none," skip straight to Phase 4 with nothing to reference there.

## Phase 4 — Program-level spec

**Architecture mode off (default):** invoke /spec-writer to produce a spec covering the whole engagement's scope. Overview, functional requirements, architecture overview, out-of-scope, and acceptance criteria should be filled in fully; API changes, database changes, and other implementation-level sections may stay high-level or be marked "to be determined per story" — that detail belongs to each story's own /spec-writer pass later, not here.

**Architecture mode on:** invoke /spec-writer with the same overall coverage, but write the API/database/integration detail down now rather than deferring it — Phase 2's deeper /grill-me pass actually produced that detail, and deferring it after going to the trouble of surfacing it would throw the work away. If Phase 3 generated any diagrams, also instruct /spec-writer to reference each one by its file path in the architecture overview section it already writes. If Phase 3 was skipped, or the user selected "none," give no such instruction — never reference a diagram that doesn't exist.

STOP. Present spec. Ask: "Approve program spec? (yes / feedback)"
Do not proceed until approved.

## Phase 5 — Record planning decisions

Invoke /decision-recorder to capture the planning decisions made in Phases 2-4. This becomes the shared reference every story can draw on later, regardless of any individual story's `context_mode`. If architecture mode was on for this run, also record that fact and why, tagged `significance: architectural`, including which diagrams (if any) were generated and why they were proposed.

## Phase 6 — Story backlog

Delegate to the story-converter agent, in spec mode, against the approved program spec. Read `context_mode_default` and `stories_dir` from `config/orchestration.yaml` and pass both explicitly, alongside whether architecture mode was on for this run — story-converter has no project config access of its own, so all three have to come from you, not be assumed. story-converter sets `architecture_mode` on the backlog output (see `story-backlog.schema.json`) and weighs it toward more stories defaulting to `full-spec` context_mode, since a project that warranted deep upfront design is more likely to have stories touching shared surface those decisions established.

For each resulting story, story-converter also assigns a `context_mode`:
- `full-spec` — story touches shared or foundational surface (auth, shared schema, core interfaces); its /feature-orchestrator run should load the full program spec as reference
- `decision-log-only` — story is largely independent but should stay aware of engagement-wide decisions
- `independent` — story is fully self-contained

The default `context_mode` for the project is the `context_mode_default` value you just passed in; story-converter may override it per story where it has clear reason to.

STOP. Present the story backlog with each story's `context_mode`. Ask: "Approve backlog? (yes / feedback)"

## Guardrails

- Never generate implementation-level tasks, file lists, or technical plans here — that's /plan-writer's job, once per story, later. This holds even in architecture mode: deeper design detail in the spec is not the same thing as a task breakdown.
- Never skip Phase 2 even if a PRD looks complete — written requirements from a client still need a clarification pass.
- If the repo (brownfield) reveals a hard architectural constraint that conflicts with the PRD, surface it before writing the spec rather than writing around it silently.
- Never turn architecture mode on unrequested, and never silently skip it when it was explicitly requested — it's an explicit choice made once at invocation, not something to infer or second-guess mid-run.
- Never propose a non-mandatory diagram type in Phase 3 without a specific, stated reason tied to something Phase 2's grilling actually surfaced — a diagram proposed "just in case" defeats the point of grounding the list in what was actually learned.
- Never skip Phase 3's self-check step or proceed to Phase 4 with a selected diagram unwritten, even under time pressure — it exists precisely to catch that.
- Diagrams generated in Phase 3 are a point-in-time artifact, same as the program spec — this skill does not regenerate or update them on a re-run against an already-planned project. That's a deliberate limitation, not an oversight; if the architecture changes later, treat updating the diagrams as its own explicit decision, not something to infer.
- This skill produces the backlog; it does not execute any story. Hand each approved story off to /feature-orchestrator as an independent run — except a story with a non-empty `depends_on`, which shouldn't be handed off until every story it depends on has actually merged, not just started. `depends_on` is meaningless if nothing checks it. It should also be rare: story-converter only sets it for genuine contract dependencies, not for stories that would merely benefit from awareness of each other — that case is handled by context escalation inside each story's own run, not by blocking at planning time.
