# Configurable, versioned spec/plan file naming for stories Implementation Plan

**Goal:** Drop the slug from the per-story directory name (`<stories_dir>/<story-id>/`), move `spec.md`/`plan.json` into their own `spec/`/`plan/` subfolders, make their basename configurable via a placeholder template, and version every approved content change instead of overwriting.

**Architecture:** `story-converter` (creates the story directory + `ticket.json`) and `feature-orchestrator` (writes/reads spec and plan files) are the only two files whose behavior actually changes. `ticket.json` gains a persisted `slug` field so `feature-orchestrator` — which has no other way to know a story's slug now that it's not in the directory name — can render filenames without recomputing anything. "Current version" is always resolved by scanning the directory for the highest `-v<N>`, never cached or tracked by a separate pointer file.

**Tech Stack:** Prose/markdown skill and agent files only — no code, no automated test suite. Verification is a manual run-through, same approach as the architecture-mode diagrams feature.

## Global Constraints

- Directory: `<stories_dir>/<story-id>/` — story id only, no slug. This is the one line that changes in how `story-converter` names the directory.
- `ticket.json` stays flat at `<stories_dir>/<story-id>/ticket.json` — not moved into a subfolder. It gains one new field, `slug`.
- File basename template: `story_file_name_format` in `orchestration.yaml`, default `{ticket_id}-{slug}`, placeholders `{ticket_id}` and `{slug}` only. Rendered by reading `ticket.json` — deterministic and safe to re-render at any step, never needs caching, since `ticket_id`/`slug` never change after `story-converter` creates them.
- Version suffix `-v<N>` is always auto-appended after the rendered name, before the extension (`.md` for spec, `.json` for plan) — never part of the configured template itself.
- "Current version" resolution: list files in `spec/` (or `plan/`), parse the trailing `-v<N>`, take the highest. No pointer/index file, ever — this repo's own "never duplicate a source of truth" principle applies directly here.
- Version bump discipline: an approved content change (initial approval, or a Scope/Story amendment) writes a **new** version. Routine `plan` task-`status` bookkeeping during execution mutates the **current** version's file **in place** and never creates a new one. Spec and plan version numbers are independent of each other.
- Version: major bump — breaking change to an established on-disk layout and to `ticket.json`'s shape, per this repo's own versioning discipline in `CLAUDE.md`.

---

### Task 1: Add `story_file_name_format` to the project template config

**Files:**
- Modify: `project-template/.claude/config/orchestration.yaml`

**Interfaces:**
- Produces: `story_file_name_format`, read by `feature-orchestrator` (Task 3) whenever it needs a story's spec/plan basename.

- [ ] **Step 1: Add the key**

Find the `stories_dir` block:

```yaml
# Where per-story state (spec.md, plan.json, ticket.json) is written, one
# folder per story. Independently configurable, not assumed to sit inside
# state_dir above - point it wherever suits this project's layout.
stories_dir: .claude/state/stories
```

Replace it with (the comment's file list changes to match the new layout, and the new key is added immediately after):

```yaml
# Where per-story state is written, one folder per story (<story-id>/, no
# slug - see story_file_name_format below for where the slug shows up
# instead). Independently configurable, not assumed to sit inside state_dir
# above - point it wherever suits this project's layout.
stories_dir: .claude/state/stories

# Template for the spec/plan file basename, before the automatic "-v<N>"
# version suffix and extension are appended. Available placeholders:
# {ticket_id}, {slug}. Rendered once per story and reused for both spec/
# and plan/ - only the extension (.md vs .json) and version number differ
# between them.
story_file_name_format: "{ticket_id}-{slug}"
```

- [ ] **Step 2: Visually verify formatting**

No PyYAML available in this environment (confirmed in the architecture-mode-diagrams work) — visually confirm 2-space indentation, no tabs, and that the new block matches every other entry's style exactly.

- [ ] **Step 3: Commit**

```bash
git add project-template/.claude/config/orchestration.yaml
git commit -m "feat(feature-orchestrator): add story_file_name_format config key"
```

---

### Task 2: Update `agents/story-converter.md`

**Files:**
- Modify: `agents/story-converter.md`

**Interfaces:**
- Produces: `ticket.json` now containing `slug` alongside `ticket_id` and `sync_log` — consumed by `feature-orchestrator` (Task 3) to render spec/plan filenames.
- Consumes: nothing new — `stories_dir` is already passed in explicitly, same as today.

- [ ] **Step 1: Update the directory-creation paragraph**

Find:

```
For each story, create its directory at `<stories_dir>/<story-id>-<slug>/` (you choose the slug, from the story's title) and write `ticket.json` there: the story's `ticket_id` plus an empty sync log. `stories_dir` is given to you explicitly by whoever invoked you - you have no project config access of your own. This step is unaffected by `state_backend` — `ticket.json` always lives under `stories_dir` as a plain file, in both modes.
```

Replace with:

```
For each story, create its directory at `<stories_dir>/<story-id>/` (story id only - the slug you compute for it lives inside `ticket.json`, not the directory name) and write `ticket.json` there:

```json
{
  "ticket_id": "MPMD-123",
  "slug": "project-scaffold",
  "sync_log": []
}
```

`ticket_id` is the id returned by the ticket system on creation. `slug` is yours to choose, from the story's title, same as it always has been — it's now persisted here instead of only ever appearing in a directory name, since `feature-orchestrator` needs it later to render spec/plan filenames and has no other way to recover it. `stories_dir` is given to you explicitly by whoever invoked you - you have no project config access of your own. This step is unaffected by `state_backend` — `ticket.json` always lives under `stories_dir` as a plain file, in both modes. Do not create `spec/` or `plan/` subfolders here - neither exists yet at this point in the flow (spec mode runs once per project, before any story's `feature-orchestrator` run); `feature-orchestrator` creates them itself on first write.
```

- [ ] **Step 2: Update the plan-mode sync-log path**

Find:

```
Append one line to that story's `ticket.json` sync log at `<stories_dir>/<story-id>-<slug>/ticket.json` (the directory already exists from spec mode - find it by its `<story-id>-` prefix under `stories_dir`) noting what synced and why. The ticket id itself never changes here; you're only ever adding to the log.
```

Replace with:

```
Append one line to that story's `ticket.json` sync log at `<stories_dir>/<story-id>/ticket.json` (the directory already exists from spec mode) noting what synced and why. The ticket id itself never changes here; you're only ever adding to the log.
```

- [ ] **Step 3: Verify no stale `-<slug>` directory references remain**

Run: `command grep -n "story-id.*slug\|<story-id>-" agents/story-converter.md`
Expected: no matches. (`command grep` bypasses this environment's broken `grep` shell-function wrapper — confirmed necessary in this session; plain `grep` fails with an unrelated "claude native binary not installed" error here.)

- [ ] **Step 4: Commit**

```bash
git add agents/story-converter.md
git commit -m "feat(story-converter): drop slug from story directory name, persist it in ticket.json instead"
```

---

### Task 3: Update `skills/feature-orchestrator/SKILL.md`

**Files:**
- Modify: `skills/feature-orchestrator/SKILL.md`

**Interfaces:**
- Consumes: `ticket.json`'s `slug` field (Task 2) and `story_file_name_format` (Task 1).
- Produces: the new "Resolving a story's current spec/plan version" section, referenced by name from step 11 and both amendment loops.

- [ ] **Step 1: Add a new section after "Model tiers", before "Standard workflow"**

Find:

```
- /context-compressor: inline, never isolated, on whatever model this session is already using — it has to see this session's actual accumulated context to compress it, so isolation isn't compatible with its job.

## Standard workflow (feature development)
```

Replace with:

```
- /context-compressor: inline, never isolated, on whatever model this session is already using — it has to see this session's actual accumulated context to compress it, so isolation isn't compatible with its job.

## Resolving a story's current spec/plan version

Whenever a step below needs "the approved spec" or "the current plan," resolve it fresh, every time: list the files in `<stories_dir>/<story-id>/spec/` (or `plan/`), parse each for its trailing `-v<N>` before the extension, and take the highest `N`. No separate pointer or index file tracks this — the directory listing is the only source of truth. Never assume a version number carried over from earlier in the run: a Scope or Story amendment writes a new one, and the next step that needs "the plan" or "the spec" must see it, not a stale number remembered from before the amendment.

## Standard workflow (feature development)
```

- [ ] **Step 2: Update step 0**

Find:

```
0. Read `state_backend` from `config/orchestration.yaml` now (`file` or `turso`) - it governs how every read/write to `story-backlog.json`/`decision-log.jsonl` happens for the rest of this run, in this step and in "Context escalation" below. If this run is executing one story from a /project-planner backlog, look up that story's `context_mode`: in `file` mode, from `.claude/state/story-backlog.json`; in `turso` mode, via the `turso-state` MCP server's `get_story` tool. Then load context per that value before proceeding: `full-spec` loads the program-level spec as reference for /grill-me and /spec-writer; `decision-log-only` loads only the shared decision log (`.claude/state/decision-log.jsonl` in `file` mode, the `list_decisions` MCP tool in `turso` mode); `independent` loads neither. This is a starting point, not fixed for the run — see "Context escalation" below. This only affects what context is available going in — decision-recorder writes at steps 7, 10, and 14 below always happen regardless of `context_mode`, and decision-recorder branches on `state_backend` itself for those writes (see `skills/decision-recorder/SKILL.md`) - nothing here needs to duplicate that logic. Also read `stories_dir` from `config/orchestration.yaml` now — every per-story file this run writes (steps 6 and 9 below) goes under `<stories_dir>/<story-id>-<slug>/`, this project's configured location, never a hardcoded path, and unaffected by `state_backend` either way.
```

Replace with:

```
0. Read `state_backend` from `config/orchestration.yaml` now (`file` or `turso`) - it governs how every read/write to `story-backlog.json`/`decision-log.jsonl` happens for the rest of this run, in this step and in "Context escalation" below. If this run is executing one story from a /project-planner backlog, look up that story's `context_mode`: in `file` mode, from `.claude/state/story-backlog.json`; in `turso` mode, via the `turso-state` MCP server's `get_story` tool. Then load context per that value before proceeding: `full-spec` loads the program-level spec as reference for /grill-me and /spec-writer; `decision-log-only` loads only the shared decision log (`.claude/state/decision-log.jsonl` in `file` mode, the `list_decisions` MCP tool in `turso` mode); `independent` loads neither. This is a starting point, not fixed for the run — see "Context escalation" below. This only affects what context is available going in — decision-recorder writes at steps 7, 10, and 14 below always happen regardless of `context_mode`, and decision-recorder branches on `state_backend` itself for those writes (see `skills/decision-recorder/SKILL.md`) - nothing here needs to duplicate that logic. Also read `stories_dir` and `story_file_name_format` from `config/orchestration.yaml` now. This story's `ticket.json` at `<stories_dir>/<story-id>/ticket.json` already exists (written by story-converter in spec mode) — any step below that needs this story's spec/plan file basename reads `ticket_id` and `slug` from it and renders `story_file_name_format` against them (e.g. `{ticket_id}-{slug}` → `MPMD-123-project-scaffold`). Every per-story file this run writes goes under `<stories_dir>/<story-id>/`: `spec/<name>-v<N>.md` and `plan/<name>-v<N>.json` (steps 6 and 9 below), never a hardcoded path, and unaffected by `state_backend` either way.
```

- [ ] **Step 3: Update step 6**

Find:

```
6. Wait for explicit user approval, then write the approved spec to `<stories_dir>/<story-id>-<slug>/spec.md`.
```

Replace with:

```
6. Wait for explicit user approval, then write the approved spec as this story's first version: `<stories_dir>/<story-id>/spec/<name>-v1.md`, using the basename rendered per step 0 - create the `spec/` folder if it doesn't exist yet.
```

- [ ] **Step 4: Update step 9**

Find:

```
9. Wait for explicit user approval, then write the approved plan to `<stories_dir>/<story-id>-<slug>/plan.json`, matching `task-graph.schema.json` — this is the on-disk copy step 11 below reads from and updates as tasks progress.
```

Replace with:

```
9. Wait for explicit user approval, then write the approved plan as this story's first version: `<stories_dir>/<story-id>/plan/<name>-v1.json`, using the basename rendered per step 0 and matching `task-graph.schema.json` - create the `plan/` folder if it doesn't exist yet. This is the on-disk copy step 11 below reads from and updates as tasks progress.
```

- [ ] **Step 5: Update step 11**

Find:

```
11. Execute the plan's task graph, reading and updating `plan.json` from step 9 as tasks progress:
    - A task starts only once every task in its `depends_on` list has passed validation.
    - For each task that's ready, delegate to the implementer agent, scoped to that task's id and its declared `files_touched` only.
    - Tasks sharing the same `parallel_group` run as separate concurrent implementer calls — this is what makes them actually concurrent rather than sequential turns labeled parallel. Tasks with `parallel_group: null` run one at a time — still isolated, still Sonnet 5 at high effort, just not concurrent with anything else.
    - Update each task's `status` in `plan.json` as it moves through `pending` -> `in_progress` -> `validated`/`failed`/`blocked_scope_gap` — this is what lets `depends_on` be checked against real progress rather than assumed. The task graph itself (`depends_on`, `parallel_group`, `files_touched`) stays internal state for this step to work from — it is not mirrored into the ticket system. The story has exactly one ticket, created back in /project-planner; nothing here creates another.
    - If the implementer agent reports it cannot complete a task within its declared `files_touched`, this is a scope gap, not a failure — pause that task and run the "Scope amendment loop" below before resuming it. Other tasks with no dependency on it continue unaffected.
```

Replace with:

```
11. Execute the plan's task graph, reading and updating the current plan version's file (resolved per "Resolving a story's current spec/plan version" above) as tasks progress:
    - A task starts only once every task in its `depends_on` list has passed validation.
    - For each task that's ready, delegate to the implementer agent, scoped to that task's id and its declared `files_touched` only.
    - Tasks sharing the same `parallel_group` run as separate concurrent implementer calls — this is what makes them actually concurrent rather than sequential turns labeled parallel. Tasks with `parallel_group: null` run one at a time — still isolated, still Sonnet 5 at high effort, just not concurrent with anything else.
    - Update each task's `status` in the current plan version's file as it moves through `pending` -> `in_progress` -> `validated`/`failed`/`blocked_scope_gap` — this is routine bookkeeping, not a content amendment, so it always happens in place and never creates a new version, even immediately after a Scope amendment produced one: resolve "current" fresh each time, and write status to whichever version that resolves to at that moment. This is what lets `depends_on` be checked against real progress rather than assumed. The task graph itself (`depends_on`, `parallel_group`, `files_touched`) stays internal state for this step to work from — it is not mirrored into the ticket system. The story has exactly one ticket, created back in /project-planner; nothing here creates another.
    - If the implementer agent reports it cannot complete a task within its declared `files_touched`, this is a scope gap, not a failure — pause that task and run the "Scope amendment loop" below before resuming it. Other tasks with no dependency on it continue unaffected.
```

- [ ] **Step 6: Update the Scope amendment loop**

Find:

```
## Scope amendment loop

Triggered whenever the implementer agent reports a `files_touched` gap during step 11.

1. Record the gap: task id, the file(s) it says it needs, and why.
2. Re-invoke /plan-writer scoped to only that gap — not a full re-plan. It amends the task's `files_touched`, or creates a new dependent task if the addition is substantial enough to deserve its own acceptance criteria.
3. Re-check the parallel-safety rule for the affected task against every other task in its `parallel_group`. If the amendment introduces a new file-set overlap, resequence: drop the affected task to `parallel_group: null` (or split it into its own group) and add a `depends_on` edge if the collision requires strict ordering.
4. Get a lightweight approval: "implementer flagged that <task> also needs <file> — approve adding it to scope?" This is a one-line delta sign-off, not the full plan-approval gate — don't re-run step 9 in full for a single-file addition.
5. Write the amended task graph back to `<stories_dir>/<story-id>-<slug>/plan.json` — the on-disk copy from step 9 must reflect the amendment before implementer resumes, not just this session's memory of it.
6. Delegate to the story-converter agent, in plan mode, with `stories_dir` from step 0 passed explicitly, to note the amended scope on the story's ticket — a short delta, not a restatement of the task graph.
7. Delegate to the implementer agent again on the task with its amended `files_touched`. This is a fresh call reading the file's current on-disk state, not a resume of a paused process — nothing needs to carry over in memory, because whatever was already built is sitting in the files themselves, and the agent discovers its own prior partial work the same way it discovers anything else about the task: by reading what it's scoped to.
```

Replace with:

```
## Scope amendment loop

Triggered whenever the implementer agent reports a `files_touched` gap during step 11.

1. Record the gap: task id, the file(s) it says it needs, and why.
2. Re-invoke /plan-writer scoped to only that gap — not a full re-plan. It amends the task's `files_touched`, or creates a new dependent task if the addition is substantial enough to deserve its own acceptance criteria. Start from the current plan version's full content (resolved per "Resolving a story's current spec/plan version" above) and carry every other task's current `status` forward unchanged - this is an amendment to one task, not a fresh plan.
3. Re-check the parallel-safety rule for the affected task against every other task in its `parallel_group`. If the amendment introduces a new file-set overlap, resequence: drop the affected task to `parallel_group: null` (or split it into its own group) and add a `depends_on` edge if the collision requires strict ordering.
4. Get a lightweight approval: "implementer flagged that <task> also needs <file> — approve adding it to scope?" This is a one-line delta sign-off, not the full plan-approval gate — don't re-run step 9 in full for a single-file addition.
5. Write the amended task graph as a new version, `<stories_dir>/<story-id>/plan/<name>-v<N+1>.json` where `N` is the version resolved in step 2 - a content amendment gets its own version rather than overwriting. From this point on, step 11 reads and writes task status against this new version.
6. Delegate to the story-converter agent, in plan mode, with `stories_dir` from step 0 passed explicitly, to note the amended scope on the story's ticket — a short delta, not a restatement of the task graph.
7. Delegate to the implementer agent again on the task with its amended `files_touched`. This is a fresh call reading the file's current on-disk state, not a resume of a paused process — nothing needs to carry over in memory, because whatever was already built is sitting in the files themselves, and the agent discovers its own prior partial work the same way it discovers anything else about the task: by reading what it's scoped to.
```

- [ ] **Step 7: Update the Story amendment loop**

Find:

```
## Story amendment loop

Triggered whenever this story's acceptance criteria change after the spec was approved — whether the plan has started, is underway, or is already implemented.

1. Record what changed and why: the delta between the old and new acceptance criteria.
2. Re-invoke /spec-writer scoped to the delta to amend the approved spec — don't restart it from scratch. Write the amended spec back to `<stories_dir>/<story-id>-<slug>/spec.md` from step 6 of the main workflow.
3. If a plan already exists, re-invoke /plan-writer scoped to the same delta to patch the task graph. Re-check the parallel-safety rule for any task the amendment touches, same as in the Scope amendment loop. Write the amended plan back to `<stories_dir>/<story-id>-<slug>/plan.json` from step 9.
4. If work already implemented conflicts with the new criteria, surface that explicitly rather than silently reworking already-validated tasks.
5. Invoke /decision-recorder unconditionally, regardless of this story's `context_mode` — an acceptance-criteria change is exactly the kind of thing sibling stories may need visibility into, even under `independent` mode.
6. Delegate to the story-converter agent, in plan mode, with `stories_dir` from step 0 passed explicitly, to reflect the new criteria on the story's ticket — what changed and why, not the whole spec restated.
7. Get a lightweight approval for the delta, same shape as the Scope amendment loop's approval — not a full spec re-approval unless the change is substantial enough to warrant one.
```

Replace with:

```
## Story amendment loop

Triggered whenever this story's acceptance criteria change after the spec was approved — whether the plan has started, is underway, or is already implemented.

1. Record what changed and why: the delta between the old and new acceptance criteria.
2. Re-invoke /spec-writer scoped to the delta to amend the approved spec — don't restart it from scratch. Write the amended spec as a new version, `<stories_dir>/<story-id>/spec/<name>-v<N+1>.md` where `N` is the spec's own currently-resolved version (per "Resolving a story's current spec/plan version" above) - a content amendment gets its own version, same as step 6 of the main workflow established for the first one.
3. If a plan already exists, re-invoke /plan-writer scoped to the same delta to patch the task graph, starting from the current plan version's full content and carrying every other task's current `status` forward unchanged, same as the Scope amendment loop. Re-check the parallel-safety rule for any task the amendment touches, same as in the Scope amendment loop. Write the amended plan as a new version, `<stories_dir>/<story-id>/plan/<name>-v<M+1>.json` where `M` is the plan's own currently-resolved version - the spec and plan version numbers are independent of each other; amending one does not bump the other unless it's also actually amended.
4. If work already implemented conflicts with the new criteria, surface that explicitly rather than silently reworking already-validated tasks.
5. Invoke /decision-recorder unconditionally, regardless of this story's `context_mode` — an acceptance-criteria change is exactly the kind of thing sibling stories may need visibility into, even under `independent` mode.
6. Delegate to the story-converter agent, in plan mode, with `stories_dir` from step 0 passed explicitly, to reflect the new criteria on the story's ticket — what changed and why, not the whole spec restated.
7. Get a lightweight approval for the delta, same shape as the Scope amendment loop's approval — not a full spec re-approval unless the change is substantial enough to warrant one.
```

- [ ] **Step 8: Add a guardrail to the "Never:" list**

Find:

```
- run two implementer tasks concurrently if their `files_touched` sets overlap, even if the plan marked them as the same `parallel_group` — treat that as a planning error and fall back to sequential execution for those tasks
```

Add immediately after it:

```
- treat a Scope or Story amendment's spec/plan write as an in-place overwrite — it's always a new version. Treat a routine task-`status` update the opposite way — it's always in place, never a new version. Conflating the two either loses history or leaves stale version files nothing ever reads.
```

- [ ] **Step 9: Verify no stale `-<slug>` path references remain**

Run: `command grep -n "story-id.*slug\|<story-id>-\|spec\.md\|plan\.json" skills/feature-orchestrator/SKILL.md`
Expected: no matches. (Use `command grep`, not plain `grep` — see Task 2 Step 3's note on this environment's broken `grep` wrapper.)

- [ ] **Step 10: Commit**

```bash
git add skills/feature-orchestrator/SKILL.md
git commit -m "feat(feature-orchestrator): read story_file_name_format, write versioned spec/plan files under spec/ and plan/"
```

---

### Task 4: Update `project-template/.claude/state/stories/README.md` and `HOW-IT-WORKS.md`

**Files:**
- Modify: `project-template/.claude/state/stories/README.md`
- Modify: `HOW-IT-WORKS.md`

**Interfaces:**
- Consumes: the final behavior from Tasks 1-3 — this task's prose must match it exactly.

- [ ] **Step 1: Replace `project-template/.claude/state/stories/README.md` in full**

Replace the entire file's contents with:

```markdown
# Story state

This is the default location - the actual path is `stories_dir` in
`config/orchestration.yaml`, independently configurable and not assumed to
sit under `state/` at all. If you've pointed `stories_dir` elsewhere, this
folder (and this file) won't exist; the same layout below applies wherever
it's configured to.

One directory per story, named `<story-id>/` (story id only - no slug in
the directory name), created when project-planner approves the backlog.
Each contains:

- `ticket.json` — the story's one ticket id (created by story-converter in
  spec mode), the `slug` story-converter derived from the story's title,
  plus a short log of the amendment/completion syncs applied to it by
  story-converter in plan mode. There is exactly one ticket per story; this
  file is never a task-level mapping.
- `spec/` — this story's approved spec (from spec-writer), one file per
  version: `<name>-v1.md`, `<name>-v2.md` if a Story amendment produced a
  new approved version, and so on. `<name>` comes from rendering
  `story_file_name_format` (in `config/orchestration.yaml`) against this
  story's `ticket_id`/`slug` - e.g. `{ticket_id}-{slug}` produces
  `MPMD-123-project-scaffold-v1.md`. The current version is whichever has
  the highest `-v<N>` - there's no separate pointer file, it's always
  resolved from what's actually on disk.
- `plan/` — this story's task graph (from plan-writer; see
  schemas/task-graph.schema.json in agentic-sdlc-core), versioned the same
  way as `spec/` and independently of it - amending the plan doesn't bump
  the spec's version or vice versa. Drives how feature-orchestrator
  sequences and parallelizes implementer — it is internal execution state,
  not mirrored into the ticket system. Routine per-task `status` updates
  during execution happen in place on the current version and do not
  create a new one; only an actual content amendment (a Scope or Story
  amendment) does.

These need to be committed as work progresses, not just produced in a chat
session — a different engineer's feature-orchestrator run for a sibling story
may depend on being able to read this story's committed state.
```

- [ ] **Step 2: Fix the stale `plan.json` reference in `HOW-IT-WORKS.md`**

Find:

```
**One ticket per story, created once.** The `story-converter` agent only ever creates a ticket in spec mode, at `project-planner` time — there's no per-task ticket layer, and no routine ticket step inside `feature-orchestrator`. Plan mode exists solely to update that one ticket, and only fires from three places: a scope amendment, a story amendment, or the completion sync above. The task graph that drives execution stays internal to `plan.json` — it's not mirrored into the tracker.
```

Replace with:

```
**One ticket per story, created once.** The `story-converter` agent only ever creates a ticket in spec mode, at `project-planner` time — there's no per-task ticket layer, and no routine ticket step inside `feature-orchestrator`. Plan mode exists solely to update that one ticket, and only fires from three places: a scope amendment, a story amendment, or the completion sync above. The task graph that drives execution stays internal to the story's current plan file (under `plan/`, versioned - see Reference below) — it's not mirrored into the tracker.
```

- [ ] **Step 3: Verify no other stale path references remain**

Run: `command grep -n "story-id.*slug\|<story-id>-\|spec\.md\|plan\.json" HOW-IT-WORKS.md README.md project-template/.claude/state/stories/README.md`
Expected: no matches.

- [ ] **Step 4: Commit**

```bash
git add project-template/.claude/state/stories/README.md HOW-IT-WORKS.md
git commit -m "docs: describe the versioned spec/plan directory layout"
```

---

### Task 5: Manual verification run-throughs

No files change in this task. Same constraint as the architecture-mode diagrams feature: this repo's own skills/agents aren't registered in this dev session's `.claude/skills`/`.claude/agents`, so this is a careful dry trace through the final `story-converter.md` and `feature-orchestrator/SKILL.md` text, not a live invocation. Note that honestly if reporting this task's outcome.

- [ ] **Step 1: Trace spec-mode story creation**

Confirm `story-converter` (spec mode) creates `<stories_dir>/<story-id>/` (no slug in the name) and writes `ticket.json` with `ticket_id`, `slug`, and an empty `sync_log` — and does not create `spec/`/`plan/`.

- [ ] **Step 2: Trace a story's first spec/plan approval**

Confirm `feature-orchestrator` step 0 reads `ticket.json` and `story_file_name_format`, step 6 writes `spec/<name>-v1.md` (creating `spec/`), and step 9 writes `plan/<name>-v1.json` (creating `plan/`) — using the same rendered `<name>` for both.

- [ ] **Step 3: Trace a Scope amendment mid-execution**

Confirm the Scope amendment loop writes a new plan version (`v2`) carrying forward other tasks' `status` values, and that step 11's subsequent status updates target `v2`, not `v1` — `v1` stays on disk untouched.

- [ ] **Step 4: Trace a Story amendment touching both spec and plan**

Confirm the spec gets its own new version and the plan gets its own new version, independently numbered (e.g. spec goes to `v2` while plan goes to `v3` if the plan had already been bumped once by a prior Scope amendment) - not forced to match each other.

- [ ] **Step 5: Trace a routine status-only update**

Confirm a task moving from `pending` to `in_progress` with no amendment involved does not produce a new plan version - same file, in place.

- [ ] **Step 6: Record the verification outcome**

If all five traces confirm the intended behavior, proceed to Task 6. If any doesn't, fix the relevant part of Task 2 or Task 3's content and re-trace before proceeding — do not carry a known-failing trace forward.

---

### Task 6: CHANGELOG and VERSION

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `VERSION`

**Interfaces:**
- Consumes: final, verified behavior from Tasks 1-5.

- [ ] **Step 1: Bump VERSION**

Read the current value (should be `9.0.0`). Bump the major component: `9.0.0` -> `10.0.0` — breaking change to an established on-disk layout and to `ticket.json`'s shape, per this repo's own versioning discipline.

- [ ] **Step 2: Add a CHANGELOG entry**

Add a new section at the top of `CHANGELOG.md`, above the `9.0.0` entry:

```markdown
## 10.0.0 — configurable, versioned spec/plan file naming for stories

**Changed (breaking)**
- Per-story directories drop the slug: `<stories_dir>/<story-id>-<slug>/` becomes `<stories_dir>/<story-id>/`, story id only. `ticket.json` (still flat at `<stories_dir>/<story-id>/ticket.json`) gains a persisted `slug` field, computed once by `story-converter` the same way it always has been - just no longer thrown away after naming the directory.
- `spec.md` and `plan.json` move into their own `spec/`/`plan/` subfolders, and their basename becomes configurable via a new `story_file_name_format` key in `orchestration.yaml` (default `{ticket_id}-{slug}`, e.g. `MPMD-123-project-scaffold`), with an automatic `-v<N>` version suffix always appended: `spec/MPMD-123-project-scaffold-v1.md`.
- Every approved content change - the initial spec/plan approval, and every Scope or Story amendment - writes a new version rather than overwriting the previous one. Old versions stay on disk as history. "Current version" is resolved by scanning for the highest `-v<N>` on disk - no separate pointer file. Routine `plan` task-`status` bookkeeping during execution is explicitly not a content change and continues to mutate the current version's file in place.
- Existing projects with stories already created under the old `<story-id>-<slug>/spec.md` layout are not migrated automatically - a project mid-flight needs to either finish in-progress stories under the old paths or move them by hand after upgrading.

**Why**: the old fixed `spec.md`/`plan.json` naming carried no information a team's own ticket-tracking conventions might expect, and every amendment silently overwrote the prior approved version with no history. See `docs/features/specs/2026-09-16-configurable-story-file-naming-design.md` for the full design, including why "current version" is resolved by directory scan rather than a tracked pointer, and the precise distinction between a content amendment (new version) and routine status bookkeeping (in place).
```

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md VERSION
git commit -m "chore: version bump and changelog for configurable story file naming (10.0.0)"
```

---

## Execution Handoff

Inline execution in this worktree, task by task, with a checkpoint after Task 3 (the core `feature-orchestrator/SKILL.md` rewrite — the highest-risk task, since it touches five separate places that all have to agree with each other) and after Task 5 (verification) before moving to the changelog/version task.
