# Architecture-mode diagram generation and senior-architect grilling posture Implementation Plan

**Goal:** In `project-planner`'s architecture mode, make `/grill-me` actively challenge architectural decisions instead of just agreeing, and add a new phase that proposes and generates C4 (and, where warranted, other) diagrams as Mermaid files, referenced from the program spec.

**Architecture:** All changes live in `skills/project-planner/SKILL.md` — no change to `grill-me.md` or `spec-writer.md` themselves, consistent with the existing pattern where architecture mode's differences live entirely in how `project-planner` instructs those two skills each run. One new config key (`diagrams_dir`) in the project template. Everything is gated behind architecture mode, which is itself off by default and explicit-at-invocation-only — default-mode behavior is untouched.

**Tech Stack:** Prose/markdown skill files only — no code, no automated test suite. Verification is a manual run-through per the spec's own Testing section.

## Global Constraints

- Diagram format: Mermaid (`.mmd` files), per the approved design — not PlantUML.
- C4 levels generated: Context and Container only, never Component or Code.
- Diagram selection (beyond the two C4 diagrams) is always an explicit approval gate — Claude proposes with a stated reason, the user picks; never autonomous.
- The self-check after diagram generation (files actually exist) is mechanical and mandatory — this is the one part of the feature that can be verified, not just instructed, per `docs/DESIGN-PRINCIPLES.md`'s existing belt-and-suspenders precedent (`feature-orchestrator` passing model/effort explicitly rather than trusting subagent frontmatter alone).
- Never claim the grilling-posture instruction is a guarantee — it's a directive with no mechanical enforcement, and the plan's own doc updates must not oversell it either.
- Version: stays at `9.0.0` — folded into the same not-yet-released version as the project-planner/plan-writer rename already committed in this worktree, rather than a separate bump. This CHANGELOG entry is added to the existing `9.0.0` section, not a new one.

---

### Task 1: Add `diagrams_dir` to the project template config

**Files:**
- Modify: `project-template/.claude/config/orchestration.yaml`

**Interfaces:**
- Produces: a `diagrams_dir` top-level key, read by `project-planner`'s Phase 3 (Task 2) when writing diagram files. Follows the exact same pattern as the existing `stories_dir` key in this file.

- [ ] **Step 1: Add the `diagrams_dir` key**

Open `project-template/.claude/config/orchestration.yaml`. Find the `stories_dir` block:

```yaml
# Where per-story state (spec.md, plan.json, ticket.json) is written, one
# folder per story. Independently configurable, not assumed to sit inside
# state_dir above - point it wherever suits this project's layout.
stories_dir: .claude/state/stories
```

Immediately after it, add:

```yaml

# Where architecture-mode diagrams (Mermaid) are saved. Only used when
# architecture mode is on and at least one diagram is generated. Independently
# configurable, not assumed to sit inside state_dir - point it wherever suits
# this project's documentation layout.
diagrams_dir: docs/architecture/diagrams
```

- [ ] **Step 2: Verify the file is still valid YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('project-template/.claude/config/orchestration.yaml'))" 2>&1 || python3 -c "import sys; sys.path.insert(0,''); import json" `

If `python3`/PyYAML isn't available, instead visually confirm indentation and the `key: value` line match every other entry in the file exactly (2-space top-level, no tabs).

- [ ] **Step 3: Commit**

```bash
git add project-template/.claude/config/orchestration.yaml
git commit -m "feat(project-planner): add diagrams_dir config key for architecture-mode diagrams"
```

---

### Task 2: Rewrite `project-planner/SKILL.md` — posture, new Phase 3, renumbering

**Files:**
- Modify: `skills/project-planner/SKILL.md` (entire file — phase renumbering touches most of it)

**Interfaces:**
- Consumes: `diagrams_dir` from `config/orchestration.yaml` (Task 1).
- Produces: the new Phase 3 (architecture diagrams) that later tasks (README/HOW-IT-WORKS updates) describe; the diagram file paths that Phase 4 (spec) and Phase 5 (decisions) reference.

- [ ] **Step 1: Replace the entire file**

Replace the full contents of `skills/project-planner/SKILL.md` with:

```markdown
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
```

- [ ] **Step 2: Verify the phase numbering is internally consistent**

Run: `grep -n "^## Phase" skills/project-planner/SKILL.md`
Expected output — exactly six lines, in order: `Phase 1`, `Phase 2`, `Phase 3`, `Phase 4`, `Phase 5`, `Phase 6`.

Run: `grep -n "Phase [0-9]" skills/project-planner/SKILL.md`
Read through every match and confirm every cross-reference (the intro paragraph's "(Phase 6)"/"(Phase 5)", Phase 5's "Phases 2-4", the Architecture mode section's phase mentions) points at the correct phase under the new numbering — there is no automated check for this, it's a careful manual read.

- [ ] **Step 3: Commit**

```bash
git add skills/project-planner/SKILL.md
git commit -m "feat(project-planner): challenging grilling posture and architecture-diagram generation in architecture mode"
```

---

### Task 3: Update README.md and HOW-IT-WORKS.md

**Files:**
- Modify: `README.md`
- Modify: `HOW-IT-WORKS.md`

**Interfaces:**
- Consumes: the final Phase numbering and behavior from Task 2 — this task's prose must match it exactly, not describe an earlier draft.

- [ ] **Step 1: Update `README.md`'s program-planning bullet**

Find:

```
  - **Program planning** (`project-planner`) — turns a PRD or an existing repo into an approved story backlog, run once per project.
```

Replace with:

```
  - **Program planning** (`project-planner`) — turns a PRD or an existing repo into an approved story backlog, run once per project. In architecture mode, also challenges architectural decisions during grilling and proposes/generates C4 and other architecture diagrams as Mermaid files.
```

- [ ] **Step 2: Update `HOW-IT-WORKS.md`'s "Starting a new project" section**

Find the numbered list and the two paragraphs immediately after it:

```
Run `project-planner` with a PRD, an existing repo, or both. It:

1. Runs `repo-discovery` (broad pass, brownfield only) and reads any provided PRD.
2. Runs a `grill-me` session — project-level by default (what's in scope, what's explicitly out, constraints, priorities), or a deeper architecture-mode session if you asked for one (see below). **Stops for your approval.**
3. Writes a program-level spec via `spec-writer` — high-level on API/database detail by default, or fully specified if architecture mode produced that detail. **Stops for your approval.**
4. Invokes `decision-recorder` to record planning decisions.
5. Delegates to the `story-converter` agent in **spec mode**, producing a backlog: each story gets acceptance criteria and a `context_mode` (see below), one ticket per story in the configured tracker, and the whole backlog written locally to `.claude/state/story-backlog.json`. **Stops for your approval.**

Each approved story is then handed off as an independent `feature-orchestrator` run — to you, or to a different engineer.

**Architecture mode** is off by default, and only turns on when you explicitly ask for it at invocation — `project-planner` doesn't infer it from the PRD or from what `repo-discovery` finds. On, it changes steps 2 and 3 above: `grill-me` goes deep on service boundaries, data ownership, and integration patterns instead of staying project-level, and `spec-writer` writes that detail into the program spec now instead of deferring it per-story. Worth it for genuinely greenfield or multi-service work, where a story-by-story approach to those decisions risks one story's implementation conflicting with a boundary an earlier story assumed. Not worth it for a bounded feature on a well-understood system — the default light-touch planning already covers that well.

Neither `grill-me` nor `spec-writer` changed to support this — the constraint that normally keeps them at project level lives entirely in how `project-planner` instructs them each run, not in either skill's own file, so architecture mode is really just `project-planner` telling them something different, not new capability elsewhere. Whether it was on for a project persists on the backlog itself (`architecture_mode` in `story-backlog.schema.json`), and `story-converter` weighs it toward more stories defaulting to `full-spec` context_mode.
```

Replace with:

```
Run `project-planner` with a PRD, an existing repo, or both. It:

1. Runs `repo-discovery` (broad pass, brownfield only) and reads any provided PRD.
2. Runs a `grill-me` session — project-level by default (what's in scope, what's explicitly out, constraints, priorities), or a deeper, actively-challenging architecture-mode session if you asked for one (see below). **Stops for your approval.**
3. **Architecture mode only:** proposes a diagram list (C4 Context and Container always; others only where the grilling actually grounds one) and generates the ones you select as Mermaid files under `diagrams_dir`. **Stops for your selection.**
4. Writes a program-level spec via `spec-writer` — high-level on API/database detail by default, or fully specified and referencing any generated diagrams if architecture mode produced that detail. **Stops for your approval.**
5. Invokes `decision-recorder` to record planning decisions, including which diagrams were generated in architecture mode.
6. Delegates to the `story-converter` agent in **spec mode**, producing a backlog: each story gets acceptance criteria and a `context_mode` (see below), one ticket per story in the configured tracker, and the whole backlog written locally to `.claude/state/story-backlog.json`. **Stops for your approval.**

Each approved story is then handed off as an independent `feature-orchestrator` run — to you, or to a different engineer.

**Architecture mode** is off by default, and only turns on when you explicitly ask for it at invocation — `project-planner` doesn't infer it from the PRD or from what `repo-discovery` finds. On, it changes step 2 above, adds step 3 entirely, and adds a diagram-reference instruction to step 4: `grill-me` goes deep on service boundaries, data ownership, and integration patterns instead of staying project-level, and is instructed to actively push back on stated decisions with a specific concern or trade-off rather than simply agree — a directive on posture with no mechanical enforcement, not a guarantee of how the session actually goes. Diagram generation's own self-check (files actually exist before the run proceeds) is the one part of this that is mechanically verified. Worth it for genuinely greenfield or multi-service work, where a story-by-story approach to those decisions risks one story's implementation conflicting with a boundary an earlier story assumed. Not worth it for a bounded feature on a well-understood system — the default light-touch planning already covers that well.

Neither `grill-me` nor `spec-writer` changed to support this — the constraint that normally keeps them at project level, and the diagram-generation step itself, live entirely in how `project-planner` instructs them each run, not in either skill's own file. Whether it was on for a project persists on the backlog itself (`architecture_mode` in `story-backlog.schema.json`), and `story-converter` weighs it toward more stories defaulting to `full-spec` context_mode. Diagrams generated during this run are a point-in-time artifact, same as the program spec — not kept in sync with later architecture decisions automatically.
```

- [ ] **Step 3: Grep for any other numbered-step references to this section that might now be stale**

Run: `grep -n "steps 2 and 3\|step 2 above\|step 3 above" HOW-IT-WORKS.md`
If anything matches outside the block just replaced, update it to match the new step numbers (2, 3, 4) — do not leave a stale cross-reference.

- [ ] **Step 4: Commit**

```bash
git add README.md HOW-IT-WORKS.md
git commit -m "docs: describe architecture-mode diagram generation and grilling posture"
```

---

### Task 4: Manual verification run-throughs

No files change in this task — it's the verification the spec's own Testing section calls for, since skill files aren't unit-testable code. Do this by actually invoking `/project-planner` twice (or as close to that as the environment allows — a dry read-through of the skill file simulating both paths is the fallback if a live invocation isn't practical here).

- [ ] **Step 1: Default-mode run**

Invoke `project-planner` on a small, made-up PRD without requesting architecture mode. Confirm:
- No diagram phase is mentioned or run.
- `grill-me`'s posture is unchanged from before this feature (no pushback directive).
- `diagrams_dir` is never read.

- [ ] **Step 2: Architecture-mode run against a small worked scenario**

Invoke `project-planner` with "use architecture mode" against a scenario with at least one debatable architectural decision (e.g. "should this be one service or two"). Confirm:
- `grill-me` pushes back at least once with a stated concern or trade-off, not silent agreement.
- The proposed diagram list includes the two C4 diagrams plus only non-mandatory types that have a stated grounding tied to something the grilling actually surfaced — not a generic list.
- After selecting a subset, the files actually get written to `diagrams_dir` with the expected kebab-case names.

- [ ] **Step 3: Induced-failure check for the self-check step**

During the same or a fresh architecture-mode run, after Phase 3 selects diagrams but before it finishes, delete one of the generated files out from under it (or otherwise simulate one missing). Confirm the skill's self-check step actually catches this and refuses to silently proceed to Phase 4 — it must report the missing file and retry, not continue as if generation fully succeeded.

- [ ] **Step 4: Confirm spec references**

Confirm the resulting `spec.md`'s architecture overview section references every diagram actually generated, by its real path — no dangling reference to a file that was proposed but not selected, and no missing reference to one that was generated.

- [ ] **Step 5: Record the verification outcome**

If all four checks pass, note that in the PR description when this branch is ready (no file to commit for this step). If any check fails, fix the relevant part of Task 2's `SKILL.md` content and re-run the affected checks before moving on — do not proceed to Task 5 with a known-failing check.

---

### Task 5: CHANGELOG

**Files:**
- Modify: `CHANGELOG.md`
- `VERSION` is NOT modified — this feature ships as part of the already-committed `9.0.0`, not a new bump. Do not touch `VERSION` in this task.

**Interfaces:**
- Consumes: final, verified behavior from Tasks 2-4 — write the changelog entry from what was actually built and verified, not from the spec's original proposal, in case anything shifted during Task 4's verification.

- [ ] **Step 1: Add a second `**Added**` section to the existing `9.0.0` entry**

`CHANGELOG.md` currently starts with:

```markdown
# Changelog

## 9.0.0 — project-scoper renamed to project-planner; implementation-planner renamed to plan-writer

**Changed (breaking)**
- `skills/project-scoper/` renamed to `skills/project-planner/` (`name: project-scoper` frontmatter also updated), and `skills/implementation-planner/` renamed to `skills/plan-writer/`. Invoke them as `/project-planner` and `/plan-writer` from now on - the old names no longer resolve to anything. Internal body text in both skills shifted from "scope"/"scoping" language describing the skill's own identity (e.g. "Program-level scoping" heading, "scope-defining" grill-me posture) to "plan"/"planning" wording; genuine domain terminology unrelated to either skill's own name (e.g. "what's in scope, what's explicitly out of scope" as a requirements-engineering concept, `spec-writer`'s "out-of-scope items" section) was deliberately left untouched - it describes a concept, not either skill's identity.
- Every cross-reference across the repo updated to match: `README.md`, `HOW-IT-WORKS.md`, `CLAUDE.md`, `docs/DESIGN-PRINCIPLES.md`, `docs/OPEN-DISCUSSIONS.md` (the one still-relevant historical mention there is annotated "then named `implementation-planner`" rather than silently rewritten), `project-template/.claude/config/orchestration.yaml`, `project-template/.claude/state/README.md`, `project-template/.claude/state/stories/README.md`, `skills/decision-recorder/SKILL.md`, `skills/feature-orchestrator/SKILL.md`, `agents/story-converter.md`, `agents/implementer.md`, `schemas/story-backlog.schema.json`, `schemas/decision-log.schema.json`, `schemas/task-graph.schema.json`, `scripts/rotate-decision-log.ps1`. Verified clean with a repo-wide grep for both old names after editing - the only remaining hits are frozen historical documents (this file's own past entries, and two already-shipped feature spec/plan docs) that are deliberately never rewritten, plus the one intentional annotation above.

**Why**: `project-scoper` read oddly as a name (an uncommon word choice, even though it followed this repo's existing agent-noun convention - `risk-classifier`, `story-converter`, `validator`, `implementer`, `bug-fixer`). `project-planner` was considered first but collides with `implementation-planner` doing a materially different job (one plans the whole project's backlog, once; the other plans one story's task graph, per-story) - renaming `implementation-planner` to `plan-writer` at the same time resolves that collision and, as a side effect, mirrors `spec-writer` cleanly: `spec-writer` writes `spec.md`, `plan-writer` writes `plan.json`.
```

Insert a new `**Added**` block between the heading and `**Changed (breaking)**`, so the entry reads:

```markdown
## 9.0.0 — project-scoper renamed to project-planner; implementation-planner renamed to plan-writer

**Added**
- In architecture mode, `project-planner`'s Phase 2 `/grill-me` session is now directed to actively challenge stated architectural decisions — state a concern, risk, or trade-off before accepting one, or propose an alternative — rather than simply recording what's said. A directive on posture with no mechanical enforcement; see Limitations in the design spec for why this can't be a hard guarantee the way the diagram self-check below is.
- New Phase 3 (architecture mode only): proposes a diagram list grounded in what the grilling actually surfaced — C4 Context and Container diagrams always, data flow/sequence/activity/deployment/integration diagrams only where something specific warrants one — as an explicit selection gate, then generates the selected diagrams as Mermaid files under a new `diagrams_dir` config key (`docs/architecture/diagrams` by default, parallel to the existing `stories_dir` pattern). A mechanical self-check confirms every selected file actually exists before the run proceeds - the one part of this feature that's verified rather than merely instructed.
- Phase 4 (the program spec) references any diagrams generated in Phase 3 by path in its architecture overview section, when architecture mode produced any. Phase 5 (decision recording) also logs which diagrams were generated and why.

**Changed (breaking)**
- `skills/project-scoper/` renamed to `skills/project-planner/` (`name: project-scoper` frontmatter also updated), and `skills/implementation-planner/` renamed to `skills/plan-writer/`. Invoke them as `/project-planner` and `/plan-writer` from now on - the old names no longer resolve to anything. Internal body text in both skills shifted from "scope"/"scoping" language describing the skill's own identity (e.g. "Program-level scoping" heading, "scope-defining" grill-me posture) to "plan"/"planning" wording; genuine domain terminology unrelated to either skill's own name (e.g. "what's in scope, what's explicitly out of scope" as a requirements-engineering concept, `spec-writer`'s "out-of-scope items" section) was deliberately left untouched - it describes a concept, not either skill's identity.
- Every cross-reference across the repo updated to match: `README.md`, `HOW-IT-WORKS.md`, `CLAUDE.md`, `docs/DESIGN-PRINCIPLES.md`, `docs/OPEN-DISCUSSIONS.md` (the one still-relevant historical mention there is annotated "then named `implementation-planner`" rather than silently rewritten), `project-template/.claude/config/orchestration.yaml`, `project-template/.claude/state/README.md`, `project-template/.claude/state/stories/README.md`, `skills/decision-recorder/SKILL.md`, `skills/feature-orchestrator/SKILL.md`, `agents/story-converter.md`, `agents/implementer.md`, `schemas/story-backlog.schema.json`, `schemas/decision-log.schema.json`, `schemas/task-graph.schema.json`, `scripts/rotate-decision-log.ps1`. Verified clean with a repo-wide grep for both old names after editing - the only remaining hits are frozen historical documents (this file's own past entries, and two already-shipped feature spec/plan docs) that are deliberately never rewritten, plus the one intentional annotation above.

**Why**: `project-scoper` read oddly as a name (an uncommon word choice, even though it followed this repo's existing agent-noun convention - `risk-classifier`, `story-converter`, `validator`, `implementer`, `bug-fixer`). `project-planner` was considered first but collides with `implementation-planner` doing a materially different job (one plans the whole project's backlog, once; the other plans one story's task graph, per-story) - renaming `implementation-planner` to `plan-writer` at the same time resolves that collision and, as a side effect, mirrors `spec-writer` cleanly: `spec-writer` writes `spec.md`, `plan-writer` writes `plan.json`. Architecture mode was meant to stand in for a senior architect scoping a greenfield project, but its grilling session never actually challenged anything - it just went deeper on the same topics without pushing back - and it produced no visual artifacts at all, only denser prose in the spec. Both are real gaps for the target use case, folded into this same version rather than a separate release since neither has shipped yet. See `docs/features/specs/2026-09-12-architecture-mode-diagrams-design.md` for the full diagram-generation design, including why Mermaid was chosen over PlantUML and why the diagram-selection step is always an approval gate rather than autonomous.
```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: changelog entry for architecture-mode diagrams, folded into 9.0.0"
```

---

## Execution Handoff

Inline execution in this worktree, task by task, with a checkpoint after Task 2 (the core `SKILL.md` rewrite) and after Task 4 (verification) before moving to the changelog/version task — consistent with how the rename and turso-state work in this repo were executed.
