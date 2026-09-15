# Architecture-mode diagram generation and senior-architect grilling posture

## Context / problem

`project-planner`'s architecture mode currently only changes two things: it tells `/grill-me` to "go deep" on service boundaries, data ownership, and integration patterns, and it tells `/spec-writer` to fill in API/database/integration detail immediately instead of deferring it. Nothing about the grilling session's *posture* is different from default mode — there's no instruction that it should push back rather than simply agree — and architecture mode produces no visual artifacts at all, only more detailed prose in `spec.md`. For a session meant to stand in for a senior architect scoping a greenfield project, both are gaps: a tech lead running this expects to be challenged on debatable decisions, and expects the kind of diagrams (C4, sequence, deployment, etc.) that would normally come out of that kind of session.

## Goals

- In architecture mode, `/grill-me` adopts an explicitly challenging posture: it must not simply agree with a stated architectural decision, and must surface a concern or trade-off before accepting one.
- After grilling, propose which diagrams are warranted (C4 Context and Container always; others conditionally) and generate the selected ones as Mermaid, saved under a configurable directory.
- The program-level spec (`spec.md`) references the generated diagrams in its architecture overview section.
- Diagram generation is mechanically self-checked (files actually exist) before the run proceeds past it — the one part of this feature that can be verified rather than merely instructed.

## Non-goals

- Keeping diagrams in sync with architecture decisions made after this run — no auto-regeneration, same staleness limitation `spec.md` and ADRs already have.
- Component or Code-level C4 diagrams — too deep before any story-level implementation exists; may be revisited per-story later if ever, not part of this feature.
- Rendering/exporting diagrams to an image format (PNG/SVG) — Mermaid source is the artifact; rendering is left to whatever views the `.mmd` file (GitHub, VS Code extensions, etc.).
- Any change to default (non-architecture) mode — everything here is gated behind architecture mode, same as the existing behavior it extends.
- A mechanical check for the grilling session's *tone* — see Limitations below; this genuinely cannot be verified the way file existence can.

## Design

### Phase 2 (grilling) — challenging posture, architecture mode only

No change to `grill-me.md` itself — consistent with the existing pattern where architecture mode's differences live entirely in how `project-planner` instructs `/grill-me`, not in `grill-me`'s own file. `project-planner`'s Phase 2 architecture-mode text gets a directive addition: `/grill-me` must not accept a stated architectural decision at face value — for each one, it must state a specific concern, risk, or trade-off before accepting it or propose an alternative, the way a senior architect reviewing a peer's design would. `grill-me`'s own one-question-at-a-time mechanic is unchanged.

This is a behavioral instruction with no mechanical enforcement — see Limitations.

### New Phase 2.5 — Architecture diagrams (architecture mode only)

Inserted between the current Phase 2 (grilling) and Phase 3 (spec); existing Phase 3/4/5 renumber to 4/5/6.

1. Based on what Phase 2's grilling surfaced, propose a diagram list:
   - **Always proposed, effectively mandatory**: C4 Context diagram, C4 Container diagram.
   - **Proposed only where warranted**: data flow, sequence, activity, deployment, integration/network architecture diagrams — each with a one-line reason tying it to something specific the grilling surfaced (e.g. "sequence diagram for the checkout flow — Phase 2 surfaced a multi-service transaction boundary here"). Never propose one with no such grounding.
2. STOP. Present the proposed list. User selects which to generate (can deselect a "mandatory" C4 one too — proposed strongly, not force-locked; the user is the actual architect here).
3. Generate each selected diagram as Mermaid (`.mmd`), one file per diagram, into `diagrams_dir` (new config key, see below). Filenames are descriptive and kebab-case: `c4-context.mmd`, `c4-container.mmd`, `sequence-checkout.mmd`, `deployment-overview.mmd`.
4. **Self-check (mechanical, not just instructed):** after writing, confirm every selected diagram's file actually exists at the expected path. If any is missing, do not proceed to Phase 4 — report which one(s) and retry, the same "don't silently continue past an incomplete step" discipline the rest of this skill already uses at its approval gates.

### Phase 4 (spec, renumbered from 3) — reference the diagrams

No change to `spec-writer.md`'s own required section list. `project-planner`'s existing architecture-mode instruction to `/spec-writer` gets one addition: when writing the architecture overview section, reference each diagram generated in Phase 2.5 by its path. If Phase 2.5 was skipped (default mode, or architecture mode with nothing selected), this instruction is simply absent — no dangling reference to diagrams that don't exist.

### Phase 5 (decisions, renumbered from 4)

`/decision-recorder` also records which diagrams were generated (or explicitly, that none were selected) and why, alongside the existing scope decisions it already captures for this run.

### Config

New key in `orchestration.yaml`, parallel to the existing `stories_dir` pattern:

```yaml
# Where architecture-mode diagrams (Mermaid) are saved. Only used when
# architecture mode is on and at least one diagram is generated. Independently
# configurable, not assumed to sit inside state_dir - point it wherever suits
# this project's documentation layout.
diagrams_dir: docs/architecture/diagrams
```

## Limitations (name plainly, don't oversell)

Every instruction in this feature is a markdown instruction read by an LLM, not code — nothing here is a hard guarantee. Two different cases:

- **Mechanically checkable**: whether the selected diagram files actually exist. This is a fact, not a judgment call, so Phase 2.5 includes an explicit self-check step rather than trusting generation silently succeeded — the same belt-and-suspenders reasoning `docs/DESIGN-PRINCIPLES.md` already documents for why `feature-orchestrator` passes model/effort explicitly at call time instead of trusting subagent frontmatter alone.
- **Not mechanically checkable**: whether the grilling session's *tone* actually challenged decisions rather than agreeing with everything. No schema or file check can verify this. The instruction is written as directively as possible to raise compliance odds, but this is not, and cannot be, a guarantee — stated here explicitly rather than implied to be stronger than it is.

## Testing

Skill files aren't unit-testable code. Verification here means a manual run-through, not an automated test suite:
- One default-mode run confirming nothing changed (no diagram phase, no posture change, no `diagrams_dir` read).
- One architecture-mode run against a small worked scenario, confirming: grilling pushes back at least once with a stated concern; the diagram proposal only includes non-mandatory types tied to something the grilling actually surfaced; the self-check step catches a deliberately-induced missing file (delete one mid-run) and refuses to proceed; the resulting `spec.md` references every generated diagram's actual path.

## Rollout

Additive, backward-compatible, entirely behind the existing architecture-mode gate (itself opt-in, explicit-at-invocation-only). Minor version bump.
