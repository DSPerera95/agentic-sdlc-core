# Changelog

## 2.0.0 — Consolidated to one ticket per story

**Breaking**
- `story-converter` now creates a ticket in exactly one place: spec mode, once per story, at `project-scoper` time. Removed the automatic per-task ticket creation that previously ran as step 10a of `feature-orchestrator`, right after plan approval.
- Plan mode no longer converts a task graph into per-task tickets/subtasks. It now only updates the story's single existing ticket, and only when invoked from one of three places: the Scope amendment loop, the Story amendment loop, or the story-completion step. There is no routine or scheduled call to `story-converter` inside `feature-orchestrator` anymore — see the new `Never` guardrail against exactly that.
- `story-backlog.schema.json` — added required `ticket_id` per story, set when `story-converter` creates that story's ticket in spec mode.
- Project state shape changed: `.claude/state/stories/<id>/tickets.json` (task id → ticket id map) is replaced by `ticket.json` (the story's single ticket id plus a short sync log). Projects on 1.0.0 should reconcile any existing per-task tickets manually before adopting 2.0.0 — this version doesn't migrate them.

**Why**: the task-level ticket layer mainly served one case — different *engineers* splitting a single story's parallel tasks between themselves. The common case is AI subagents handling that parallelism, where per-task tickets added tracker noise and permanent create/sync complexity for little benefit. The task graph (`depends_on`/`parallel_group`/`files_touched`) still drives how `feature-orchestrator` sequences and parallelizes `implementer` — it's just no longer mirrored into the ticket system.

## 1.0.0 — Initial versioned release

Generalized from a single-project skill set into a reusable, two-tier orchestration layer.

**Added**
- `project-scoper` — new program-level entry point: repo-discovery/PRD ingestion → scope-defining grill-me → program spec → decision-recorder → story-converter (spec mode) → approved story backlog.
- `story-backlog.schema.json`, `task-graph.schema.json`, `decision-log.schema.json` — explicit data contracts between skills.
- `context_mode` (`full-spec` / `decision-log-only` / `independent`) as per-story metadata, assigned by `story-converter` in spec mode, read by `feature-orchestrator` at story start.
- Scope amendment loop in `feature-orchestrator` — handles `implementer` reporting a `files_touched` gap without silently expanding scope.
- Story amendment loop in `feature-orchestrator` — handles acceptance criteria changing after spec approval; writes to the decision log unconditionally regardless of `context_mode`.

**Changed**
- `implementation-planner` — task output now includes `depends_on`, `parallel_group`, and `files_touched` per task, with an explicit parallel-safety rule (disjoint file sets required to share a `parallel_group`). Previously produced a purely linear, ordered task list.
- `implementer` — scoped to a single task id and its declared `files_touched`; stops and reports rather than silently touching files outside that set. Previously implemented an entire plan in one pass with no per-task file boundary, which was unsafe once tasks could run as concurrent subagents.
- `build-feature` — repurposed as the explicit L1 fast path invoked by `feature-orchestrator` when `risk-classifier` returns L1, instead of a second, competing orchestrator with overlapping trigger language. Removed a hardcoded reference to a `/ubiquitous-language` skill that didn't exist in the set, and removed hardcoded project paths (spec/plan template locations, `AGENT.md`) in favor of project config.
- `story-converter` — split into two modes: spec mode (program spec → initial backlog, no technical tasks yet, assigns `context_mode`) and plan mode (task graph → tracked tickets). Plan mode is now invoked repeatedly across a story (ticket creation right after plan approval, sync on amendment, sync at completion) rather than once at the end.
- `feature-orchestrator` — added step 0 to load context per a story's `context_mode`; risk-classifier's output now actually branches the workflow (previously computed but unused); decision-recorder wired in explicitly after each approval gate and at delivery (previously not invoked automatically); task execution step now walks the task graph's dependencies and parallel groups instead of invoking `implementer` once for the whole plan; ticket creation moved from end-of-workflow to right after plan approval.

**Unchanged**
- `grill-me`, `spec-writer`, `validator`, `bug-fixer`, `repo-discovery`, `risk-classifier`, `decision-recorder`, `context-compressor` — reviewed and kept as-is; already project-agnostic with no hardcoded paths or single-project assumptions.
