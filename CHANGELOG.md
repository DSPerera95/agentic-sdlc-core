# Changelog

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
