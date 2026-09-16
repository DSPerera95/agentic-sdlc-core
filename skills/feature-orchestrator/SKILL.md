---
name: feature-orchestrator
description: >
  Controls the enterprise AI development workflow. Delegates to the right agents and skills in sequence, enforces approval gates, manages scope control, and ensures production-safe execution. Routes low-risk work to a lightweight fast path and runs implementation tasks in parallel where the plan marks them independent. Use for all feature development and implementation workflows.
user-invocable: true
---

## Agents vs skills

The risk-classifier, story-converter, validator, implementer, and bug-fixer agents (`.claude/agents/`) are fixed-identity workers: they always run isolated, in a fresh context, on a pinned model, and return a single result. Delegate to them by name, give them everything they need explicitly (they have no access to this session's history), and treat their return value as final for that call.

/repo-discovery, /grill-me, /spec-writer, /plan-writer, /decision-recorder, /build-feature, /context-compressor (`.claude/skills/`) run inline in this session, the traditional skill way. /decision-recorder specifically belongs here rather than in `agents/`: it's invoked at least three times per story plus every amendment, the highest frequency of anything in this system, and its whole job is capturing the reasoning behind a decision that just happened in this same conversation — isolating it would mean re-explaining that reasoning explicitly every time, which risks losing nuance rather than saving anything.

`implementer` used to be a skill specifically because its isolation was conditional on `parallel_group` — solo tasks ran inline to skip re-establishing context. That conditionality was removed: the measured downside (solo tasks silently inheriting whatever model the session happened to be on, rather than a guaranteed model/effort tier) turned out to be a real, immediate cost, while the token savings it was trading for were never actually measured. Every implementer call is isolated now, so it moved to `agents/` with the rest of the fixed-identity workers.

`bug-fixer` moved from a skill to an agent for the same reason: every one of its call sites already gives it explicit input (validator's structured findings, or nothing when there's genuinely no prior diagnosis) rather than leaning on this session's history, and as a skill it inherited whatever model the session happened to be on instead of a guaranteed tier — the same gap that moved `implementer`. One real dependency on inline visibility was found and fixed before the move: `/build-feature`'s call site wasn't explicitly passing validator's findings, relying on `bug-fixer` being able to see them in the shared session instead.

## Model tiers

Unless a step below says otherwise:

- risk-classifier, story-converter agents: Claude Haiku 4.5 — classification and ticket formatting don't need a heavier model.
- implementer agent: always Claude Sonnet 5 at high effort, for every task regardless of `parallel_group`.
- validator agent: always Claude Sonnet 5. Effort scales with this story's risk tier from step 2, passed explicitly on every call since validator has no session history to determine it itself: low for L1 (via /build-feature), medium for L2, high for L3.
- bug-fixer agent: always Claude Sonnet 5. Effort scales with this story's risk tier the same way validator's does: low for L1 (via /build-feature), medium for L2 and for the bug-fix-only workflow (no risk tier to scale from there), high for L3.
- /context-compressor: inline, never isolated, on whatever model this session is already using — it has to see this session's actual accumulated context to compress it, so isolation isn't compatible with its job.

## Resolving a story's current spec/plan version

Whenever a step below needs "the approved spec" or "the current plan," resolve it fresh, every time: list the files in `<stories_dir>/<story-id>/spec/` (or `plan/`), parse each for its trailing `-v<N>` before the extension, and take the highest `N`. No separate pointer or index file tracks this — the directory listing is the only source of truth. Never assume a version number carried over from earlier in the run: a Scope or Story amendment writes a new one, and the next step that needs "the plan" or "the spec" must see it, not a stale number remembered from before the amendment.

## Standard workflow (feature development)

0. Read `state_backend` from `config/orchestration.yaml` now (`file` or `turso`) - it governs how every read/write to `story-backlog.json`/`decision-log.jsonl` happens for the rest of this run, in this step and in "Context escalation" below. If this run is executing one story from a /project-planner backlog, look up that story's `context_mode`: in `file` mode, from `.claude/state/story-backlog.json`; in `turso` mode, via the `turso-state` MCP server's `get_story` tool. Then load context per that value before proceeding: `full-spec` loads the program-level spec as reference for /grill-me and /spec-writer; `decision-log-only` loads only the shared decision log (`.claude/state/decision-log.jsonl` in `file` mode, the `list_decisions` MCP tool in `turso` mode); `independent` loads neither. This is a starting point, not fixed for the run — see "Context escalation" below. This only affects what context is available going in — decision-recorder writes at steps 7, 10, and 14 below always happen regardless of `context_mode`, and decision-recorder branches on `state_backend` itself for those writes (see `skills/decision-recorder/SKILL.md`) - nothing here needs to duplicate that logic. Also read `stories_dir` and `story_file_name_format` from `config/orchestration.yaml` now. This story's `ticket.json` at `<stories_dir>/<story-id>/ticket.json` already exists (written by story-converter in spec mode) — any step below that needs this story's spec/plan file basename reads `ticket_id` and `slug` from it and renders `story_file_name_format` against them (e.g. `{ticket_id}-{slug}` → `MPMD-123-project-scaffold`). Every per-story file this run writes goes under `<stories_dir>/<story-id>/`: `spec/<name>-v<N>.md` and `plan/<name>-v<N>.json` (steps 6 and 9 below), never a hardcoded path, and unaffected by `state_backend` either way.
1. Invoke /repo-discovery
2. Delegate to the risk-classifier agent, with this project's `risk_thresholds` (`l1_max_files`, `l1_excludes`) from `config/orchestration.yaml` passed explicitly as input — it has no access to project config itself. `l1_excludes` is an absolute floor the agent enforces; `l1_max_files` is a strong signal it weighs and must justify overriding, not a mechanical gate applied here.
3. If risk level is L1: invoke /build-feature (fast path) and stop here — skip steps 4-16.
4. Invoke /grill-me. If it turns out this story genuinely can't be resolved with the context it was assigned, see "Context escalation" below before continuing.
5. Invoke /spec-writer. Same escalation trigger applies here if the gap only becomes apparent while writing the spec.
6. Wait for explicit user approval, then write the approved spec as this story's first version: `<stories_dir>/<story-id>/spec/<name>-v1.md`, using the basename rendered per step 0 - create the `spec/` folder if it doesn't exist yet.
7. Invoke /decision-recorder to capture the approved spec's key decisions
8. Invoke /plan-writer
9. Wait for explicit user approval, then write the approved plan as this story's first version: `<stories_dir>/<story-id>/plan/<name>-v1.json`, using the basename rendered per step 0 and matching `task-graph.schema.json` - create the `plan/` folder if it doesn't exist yet. This is the on-disk copy step 11 below reads from and updates as tasks progress.
10. Invoke /decision-recorder to capture the approved plan's key decisions
11. Execute the plan's task graph, reading and updating the current plan version's file (resolved per "Resolving a story's current spec/plan version" above) as tasks progress:
    - A task starts only once every task in its `depends_on` list has passed validation.
    - For each task that's ready, delegate to the implementer agent, scoped to that task's id and its declared `files_touched` only.
    - Tasks sharing the same `parallel_group` run as separate concurrent implementer calls — this is what makes them actually concurrent rather than sequential turns labeled parallel. Tasks with `parallel_group: null` run one at a time — still isolated, still Sonnet 5 at high effort, just not concurrent with anything else.
    - Update each task's `status` in the current plan version's file as it moves through `pending` -> `in_progress` -> `validated`/`failed`/`blocked_scope_gap` — this is routine bookkeeping, not a content amendment, so it always happens in place and never creates a new version, even immediately after a Scope amendment produced one: resolve "current" fresh each time, and write status to whichever version that resolves to at that moment. This is what lets `depends_on` be checked against real progress rather than assumed. The task graph itself (`depends_on`, `parallel_group`, `files_touched`) stays internal state for this step to work from — it is not mirrored into the ticket system. The story has exactly one ticket, created back in /project-planner; nothing here creates another.
    - If the implementer agent reports it cannot complete a task within its declared `files_touched`, this is a scope gap, not a failure — pause that task and run the "Scope amendment loop" below before resuming it. Other tasks with no dependency on it continue unaffected.
12. Delegate to the validator agent, at the effort level matching this story's risk tier from step 2 (medium for L2, high for L3 — L1 goes through /build-feature instead and never reaches this step) — give it the diff, the approved spec, the approved plan, and acceptance criteria as explicit input; it has no access to this session's history by design. A reviewer with no memory of how the implementation was built catches more than one reviewing its own work.
13. If blocking issues exist (see the validator agent's blocking/non-blocking distinction):
    - delegate to the bug-fixer agent, at the same effort level as step 12, scoped to the failing task(s), with the validator agent's structured findings (failed checks, recommended fixes) passed explicitly as input — it has no access to this session's history by design, so it should be acting on what validator already found, not rediscovering it
    - delegate to the validator agent again — a fresh call, same explicit inputs and same risk-tier effort level as step 12
14. Invoke /decision-recorder to capture the final delivery decisions
15. Produce final delivery summary, including any non-blocking code review findings from the validator agent — these don't gate delivery but should be visible to whoever reads the summary
16. Delegate to the story-converter agent, in plan mode, with `stories_dir` from step 0 passed explicitly, to mark the story's ticket complete

## Scope amendment loop

Triggered whenever the implementer agent reports a `files_touched` gap during step 11.

1. Record the gap: task id, the file(s) it says it needs, and why.
2. Re-invoke /plan-writer scoped to only that gap — not a full re-plan. It amends the task's `files_touched`, or creates a new dependent task if the addition is substantial enough to deserve its own acceptance criteria. Start from the current plan version's full content (resolved per "Resolving a story's current spec/plan version" above) and carry every other task's current `status` forward unchanged - this is an amendment to one task, not a fresh plan.
3. Re-check the parallel-safety rule for the affected task against every other task in its `parallel_group`. If the amendment introduces a new file-set overlap, resequence: drop the affected task to `parallel_group: null` (or split it into its own group) and add a `depends_on` edge if the collision requires strict ordering.
4. Get a lightweight approval: "implementer flagged that <task> also needs <file> — approve adding it to scope?" This is a one-line delta sign-off, not the full plan-approval gate — don't re-run step 9 in full for a single-file addition.
5. Write the amended task graph as a new version, `<stories_dir>/<story-id>/plan/<name>-v<N+1>.json` where `N` is the version resolved in step 2 - a content amendment gets its own version rather than overwriting. From this point on, step 11 reads and writes task status against this new version.
6. Delegate to the story-converter agent, in plan mode, with `stories_dir` from step 0 passed explicitly, to note the amended scope on the story's ticket — a short delta, not a restatement of the task graph.
7. Delegate to the implementer agent again on the task with its amended `files_touched`. This is a fresh call reading the file's current on-disk state, not a resume of a paused process — nothing needs to carry over in memory, because whatever was already built is sitting in the files themselves, and the agent discovers its own prior partial work the same way it discovers anything else about the task: by reading what it's scoped to.

## Story amendment loop

Triggered whenever this story's acceptance criteria change after the spec was approved — whether the plan has started, is underway, or is already implemented.

1. Record what changed and why: the delta between the old and new acceptance criteria.
2. Re-invoke /spec-writer scoped to the delta to amend the approved spec — don't restart it from scratch. Write the amended spec as a new version, `<stories_dir>/<story-id>/spec/<name>-v<N+1>.md` where `N` is the spec's own currently-resolved version (per "Resolving a story's current spec/plan version" above) - a content amendment gets its own version, same as step 6 of the main workflow established for the first one.
3. If a plan already exists, re-invoke /plan-writer scoped to the same delta to patch the task graph, starting from the current plan version's full content and carrying every other task's current `status` forward unchanged, same as the Scope amendment loop. Re-check the parallel-safety rule for any task the amendment touches, same as in the Scope amendment loop. Write the amended plan as a new version, `<stories_dir>/<story-id>/plan/<name>-v<M+1>.json` where `M` is the plan's own currently-resolved version - the spec and plan version numbers are independent of each other; amending one does not bump the other unless it's also actually amended.
4. If work already implemented conflicts with the new criteria, surface that explicitly rather than silently reworking already-validated tasks.
5. Invoke /decision-recorder unconditionally, regardless of this story's `context_mode` — an acceptance-criteria change is exactly the kind of thing sibling stories may need visibility into, even under `independent` mode.
6. Delegate to the story-converter agent, in plan mode, with `stories_dir` from step 0 passed explicitly, to reflect the new criteria on the story's ticket — what changed and why, not the whole spec restated.
7. Get a lightweight approval for the delta, same shape as the Scope amendment loop's approval — not a full spec re-approval unless the change is substantial enough to warrant one.

## Context escalation

Triggered when this story's assigned `context_mode` (`independent` or `decision-log-only`) turns out not to be enough — usually surfaces during /grill-me or /spec-writer, when something can't be resolved without knowing what the program-level spec says. `story-converter` assigns `context_mode` before any story-specific work has happened; this is what corrects a wrong guess without blocking the story on it from the start.

1. Escalate upward only: `independent` → `decision-log-only` or `full-spec`, `decision-log-only` → `full-spec`. Never downward, and never re-evaluate downward later in the same run once escalated.
2. Load the program-level spec via `program_spec_ref` - from `.claude/state/story-backlog.json` in `file` mode (already on `main`, since `project-planner` writes it before any story branches exist, so there's no branch-visibility issue like the rest of `.claude/state/` has in that mode), or via the `get_backlog` MCP tool in `turso` mode (branch-independent by construction, since the database isn't part of any branch).
3. No approval gate. This changes what informs a decision, not what gets built — unlike the Scope and Story amendment loops, proceed without stopping for sign-off.
4. Invoke /decision-recorder to log the escalation — including *why*, not just that it happened. This is the signal that tells you whether `story-converter`'s initial `context_mode` assignments are actually working: if `decision-log-only` stories are escalating often, that tiering isn't earning its keep and is worth revisiting.

## Bug-fix-only workflow

1. Invoke /repo-discovery
2. Delegate to the bug-fixer agent at medium effort, given the reported bug as explicit input — this workflow doesn't run risk-classifier, so there's no risk tier to scale from; medium is a fixed, reasonable default rather than defaulting to high for every bug fix regardless of stakes. There's no prior validator pass here, so bug-fixer works through its full reproduce/root-cause sequence from scratch.
3. Delegate to the validator agent at medium effort, given the diff and the fix's intended scope as explicit input — same fixed-default reasoning as step 2
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
- treat a Scope or Story amendment's spec/plan write as an in-place overwrite — it's always a new version. Treat a routine task-`status` update the opposite way — it's always in place, never a new version. Conflating the two either loses history or leaves stale version files nothing ever reads.
- let the implementer agent create or modify a file outside its declared `files_touched` without going through the Scope amendment loop, even under time pressure
- skip a decision-recorder write because a story's `context_mode` is `independent` — that mode controls what a story reads on the way in, never what it writes on the way out
- delegate to the story-converter agent anywhere except a scope amendment, a story amendment, or step 16's completion sync — no routine or scheduled ticket updates
- give the validator agent this session's accumulated context in place of an explicit diff/spec/plan handoff — it has no access to session history by design, and working around that defeats the fresh-eyes review it's meant to provide
- downgrade a story's `context_mode` after it's been escalated, or escalate without logging why through /decision-recorder

Keep responses concise and token efficient.

Invoke /context-compressor whenever context becomes excessively large.
