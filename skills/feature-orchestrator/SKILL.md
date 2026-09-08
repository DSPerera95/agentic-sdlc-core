---
name: feature-orchestrator
description: >
  Controls the enterprise AI development workflow. Invokes the correct skills in sequence, enforces approval gates, manages scope control, and ensures production-safe execution. Routes low-risk work to a lightweight fast path and runs implementation tasks in parallel where the plan marks them independent. Use for all feature development and implementation workflows.
user-invocable: true
---

Always invoke /caveman first at the beginning of a new conversation. Stay active entire session unless user says stop.

## Standard workflow (feature development)

0. If this run is executing one story from a /project-scoper backlog, load context per that story's `context_mode` before proceeding: `full-spec` loads the program-level spec as reference for /grill-me and /spec-writer; `decision-log-only` loads only the shared decision log; `independent` loads neither. This only affects what context is available going in — decision-recorder writes at steps 7, 10, and 14 below always happen regardless of `context_mode`.
1. Invoke /repo-discovery
2. Invoke /risk-classifier
3. If risk level is L1: invoke /build-feature (fast path) and stop here — skip steps 4-16.
4. Invoke /grill-me
5. Invoke /spec-writer
6. Wait for explicit user approval
7. Invoke /decision-recorder to capture the approved spec's key decisions
8. Invoke /implementation-planner
9. Wait for explicit user approval
10. Invoke /decision-recorder to capture the approved plan's key decisions
11. Execute the plan's task graph:
    - A task starts only once every task in its `depends_on` list has passed validation.
    - For each task that's ready, invoke /implementer scoped to that task's id and its declared `files_touched` only.
    - Tasks sharing the same `parallel_group` run as separate concurrent subagent sessions. Tasks with `parallel_group: null`, or with no group at all, run one at a time.
    - The task graph itself (`depends_on`, `parallel_group`, `files_touched`) stays internal state for this step to work from — it is not mirrored into the ticket system. The story has exactly one ticket, created back in /project-scoper; nothing here creates another.
    - If /implementer reports it cannot complete a task within its declared `files_touched`, this is a scope gap, not a failure — pause that task and run the "Scope amendment loop" below before resuming it. Other tasks with no dependency on it continue unaffected.
12. Invoke /validator
13. If issues exist:
    - invoke /bug-fixer, scoped to the failing task(s)
    - invoke /validator again
14. Invoke /decision-recorder to capture the final delivery decisions
15. Produce final delivery summary
16. Invoke /story-converter in plan mode to mark the story's ticket complete

## Scope amendment loop

Triggered whenever /implementer reports a `files_touched` gap during step 11.

1. Record the gap: task id, the file(s) it says it needs, and why.
2. Re-invoke /implementation-planner scoped to only that gap — not a full re-plan. It amends the task's `files_touched`, or creates a new dependent task if the addition is substantial enough to deserve its own acceptance criteria.
3. Re-check the parallel-safety rule for the affected task against every other task in its `parallel_group`. If the amendment introduces a new file-set overlap, resequence: drop the affected task to `parallel_group: null` (or split it into its own group) and add a `depends_on` edge if the collision requires strict ordering.
4. Get a lightweight approval: "implementer flagged that <task> also needs <file> — approve adding it to scope?" This is a one-line delta sign-off, not the full plan-approval gate — don't re-run step 9 in full for a single-file addition.
5. Invoke /story-converter in plan mode to note the amended scope on the story's ticket — a short delta, not a restatement of the task graph.
6. Resume /implementer on the task with its amended `files_touched`.

## Story amendment loop

Triggered whenever this story's acceptance criteria change after the spec was approved — whether the plan has started, is underway, or is already implemented.

1. Record what changed and why: the delta between the old and new acceptance criteria.
2. Re-invoke /spec-writer scoped to the delta to amend the approved spec — don't restart it from scratch.
3. If a plan already exists, re-invoke /implementation-planner scoped to the same delta to patch the task graph. Re-check the parallel-safety rule for any task the amendment touches, same as in the Scope amendment loop.
4. If work already implemented conflicts with the new criteria, surface that explicitly rather than silently reworking already-validated tasks.
5. Invoke /decision-recorder unconditionally, regardless of this story's `context_mode` — an acceptance-criteria change is exactly the kind of thing sibling stories may need visibility into, even under `independent` mode.
6. Invoke /story-converter in plan mode to reflect the new criteria on the story's ticket — what changed and why, not the whole spec restated.
7. Get a lightweight approval for the delta, same shape as the Scope amendment loop's approval — not a full spec re-approval unless the change is substantial enough to warrant one.

## Bug-fix-only workflow

1. Invoke /repo-discovery
2. Invoke /bug-fixer
3. Invoke /validator
4. Produce fix summary

## Stop immediately and request clarification when:
- requirements conflict
- architecture is unclear
- security implications exist
- migrations are required
- production risk is high
- confidence is low

## Never:
- perform unrelated refactors
- rewrite architecture without approval
- modify unrelated files
- introduce speculative abstractions
- upgrade dependencies without approval
- expand scope beyond the approved plan
- run two implementer tasks concurrently if their `files_touched` sets overlap, even if the plan marked them as the same `parallel_group` — treat that as a planning error and fall back to sequential execution for those tasks
- let /implementer create or modify a file outside its declared `files_touched` without going through the Scope amendment loop, even under time pressure
- skip a /decision-recorder write because a story's `context_mode` is `independent` — that mode controls what a story reads on the way in, never what it writes on the way out
- invoke /story-converter anywhere except a scope amendment, a story amendment, or step 16's completion sync — no routine or scheduled ticket updates

Keep responses concise and token efficient.

Invoke /context-compressor whenever context becomes excessively large.
