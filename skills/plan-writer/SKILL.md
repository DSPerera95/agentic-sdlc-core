---
name: implementation-planner
description: >
  Converts an approved feature specification into a deterministic implementation plan: a task graph with explicit dependencies, file ownership, and parallel-safe groupings, plus testing strategy and rollout guidance.
user-invocable: false
---

Convert the approved spec into a production-ready implementation plan, structured as a task graph.

For each task, generate:
- id
- description
- depends_on (ids of tasks that must be validated before this one can start)
- parallel_group (an id shared by tasks that may run concurrently; null if this task must run alone)
- files_touched (every file the task creates or modifies)
- acceptance criteria

Also generate:
- testing strategy
- rollout strategy
- rollback considerations
- risks
- definition of done

## Parallel-safety rule

Two tasks may share a `parallel_group` only if their `files_touched` sets are fully disjoint. If two tasks are logically independent but touch the same file (or the same class, migration, or shared interface), keep them sequential — same `depends_on` chain, different `parallel_group` values (or `null`) — rather than marking them parallel. File-level collisions matter more than logical independence: a planner that only reasons about logical dependency will hand the orchestrator a task graph that causes implementers to collide.

Prefer:
- incremental implementation
- minimal-risk sequencing
- small scoped changes
- deterministic execution
- maximizing safe parallelism without violating the parallel-safety rule above

Avoid:
- speculative tasks
- unrelated improvements
- broad refactors
- premature abstractions
- marking tasks parallel when their file sets overlap

Every task should be actionable, implementation-oriented, and independently reviewable — a human approving the plan should be able to see `files_touched` per task and catch an unsafe overlap before implementation starts.
