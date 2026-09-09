# Changelog

## 5.4.1 — Fixed a Windows PowerShell parsing crash in all three scripts

**Fixed**
- `install.ps1`, `scripts/rotate-decision-log.ps1`, `scripts/export-adrs.ps1` all contained em-dash characters in string literals and comments. Windows PowerShell 5.1 (the default on many Windows machines, distinct from PowerShell 7/pwsh Core) often reads a UTF-8 file without a BOM using the system ANSI codepage instead, which mangles multi-byte characters like an em-dash into garbage bytes - one of which can resemble a stray quote to the parser. The actual corruption and the reported error location aren't the same line; the parser doesn't fail until several lines later, when it runs out of file looking for a string terminator that was never actually missing at that point. Replaced every non-ASCII character across all three scripts with plain ASCII equivalents so this can't recur regardless of file encoding or PowerShell version on the machine running them.

## 5.4.0 — Architecture mode; ADR export

**Added**
- `project-scoper` — optional architecture mode, on only when explicitly requested at invocation (never inferred). Changes Phase 2 (`grill-me` goes deep on service boundaries/data ownership/integration patterns instead of staying scope-defining) and Phase 3 (`spec-writer` writes that detail down now instead of deferring it per-story). `grill-me` and `spec-writer` themselves are unchanged — the constraint that normally limits their depth lives entirely in how `project-scoper` instructs them each run, not in either skill's own file.
- `story-backlog.schema.json` — new `architecture_mode` boolean, set once by `project-scoper`/`story-converter` and persisted on the backlog so it outlives the single scoping run. `story-converter` weighs it toward more stories defaulting to `full-spec` context_mode.
- `decision-log.schema.json` — new `significance` field (`architectural` | `routine`, default `routine`). Set by whichever skill calls `decision-recorder`, not inferred by `decision-recorder` itself — the caller has the context to judge this, the narrow recorder doesn't.
- `scripts/export-adrs.ps1` — renders `significance: architectural` entries as individual ADR files (`docs/adr/DEC-####-slug.md`), sibling to `rotate-decision-log.ps1`. The log stays the source of truth; ADR files are a regenerated projection, never hand-edited.

**Why**: the architecturally-significant decisions this system needs to capture were already going through `decision-recorder` in the same shape an ADR needs (context/decision/reasoning/alternatives/consequences/tradeoffs) — the actual gaps were narrower than a new component: no way to mark an entry as ADR-worthy, and no rendering into the per-file format teams and tooling expect. Considered a dedicated architect skill/agent and rejected it — real architectural tradeoffs need the same interactive back-and-forth `grill-me` already does, and a pre-classifier deciding whether to engage architecture mode would have to guess with less information than `grill-me` has once it's actually a few questions in.

## 5.3.0 — Decision log rotation

**Added**
- `scripts/rotate-decision-log.ps1` — a plain PowerShell script, not a skill or agent, since rotation is deterministic data transformation with no judgment call in it. Keeps the most recent entries in the hot log (bounded by age and count, whichever an entry crosses first), archives the rest into `state/decision-log-archive/<date>.jsonl` with `reasoning`/`alternatives_considered`/`tradeoffs` stripped, and appends a rotation breadcrumb continuing the same `DEC-####` id sequence. Not run automatically by anything — a manual, periodic maintenance step.
- `config/orchestration.yaml` — `decision_log_rotation` block (`max_age_months`, `max_entries`). Documentation of policy, not read by the script itself; keep the two in sync manually.
- `project-template/.claude/state/README.md` and `state/decision-log-archive/` — new template files documenting the format and rotation.

**Breaking**
- `decision-log.md` (prose) replaced by `decision-log.jsonl` (JSON Lines, one compact object per line, matching `decision-log.schema.json`) — a prerequisite for the rotation script to safely parse and strip fields without risking mangling free-form prose. `decision-recorder` now appends structured lines instead of writing prose, and generates sequential `DEC-####` ids by reading the current highest id in the hot log.
- `install.ps1` now also installs `scripts/` -> `.claude/scripts/`, always synced to the pinned ref like `skills/`, `agents/`, and `schemas/`.

**Why**: nothing previously bounded the decision log's growth over a project's lifetime, and every `decision-log-only`/`full-spec` story pays to load its entire history regardless of relevance. Considered topic-splitting (one log file per component) and retrieval-based lookup as further steps — held both in reserve rather than building them now, since rotation alone likely defers the problem for a long time and building either speculatively risks solving a problem that hasn't actually shown up yet.

## 5.2.0 — Context escalation; depends_on narrowed to contract-only

**Added**
- `feature-orchestrator` — new "Context escalation" mechanism, alongside the Scope and Story amendment loops. When a story's assigned `context_mode` turns out insufficient (usually surfacing during `grill-me` or `spec-writer`), it escalates upward (`independent`/`decision-log-only` → `full-spec`), loads the program spec via the backlog's `program_spec_ref`, and logs the escalation and why via `decision-recorder` — no approval gate, since this changes what informs a decision, not what gets built.

**Changed — reverses part of 5.1.0**
- `depends_on` narrowed back to genuine contract dependencies only (this story consumes an API/schema/interface another story builds). 5.1.0 broadened it to also cover "might benefit from awareness of a decision," which in practice meant sequencing stories for a reason context escalation now handles without blocking. Applied consistently across `story-backlog.schema.json`, the `story-converter` agent, and `project-scoper`'s handoff guardrail.
- `story-converter` now explicitly treats `depends_on` as a real cost to running a backlog in parallel, and is instructed to look for opportunities to split a shared contract into its own small story before accepting a blocking dependency between two larger ones.

**Why**: with 5 of 10 stories carrying `depends_on` under the broadened 5.1.0 definition, meaningful parallel development across a backlog wasn't practical — most of what triggered it was "would help to know," not "cannot be built without." Context escalation handles that case per-story, without blocking anything at scoping time, which is what `depends_on` should never have been asked to do in the first place.

## 5.1.0 — Clarified state is branch/PR-scoped, not synced

Considered and rejected a CI-driven auto-merge fast path for `.claude/state/` (schema-validated, path-scoped PRs, auto-merging without human review) to get state visible to sibling stories faster than a normal PR cycle. Decided against it: it meant a second, less-reviewed path into `main` alongside the normal one, for a problem that has a much cheaper existing answer.

**Changed**
- `HOW-IT-WORKS.md` — corrected the state-commit guidance, which previously implied near-real-time sync. State merges via each story's own PR, same as its code — visible to other stories on merge, not before. Documented the actual consequence: two genuinely concurrent stories (both open, neither merged) won't see each other's decisions until one lands.
- `story-backlog.schema.json` / `story-converter` agent — broadened `depends_on`'s purpose to explicitly cover this: sequence two stories when one needs to see a decision the other's likely to make, not just when there's a code/contract dependency.
- `project-scoper` — added the guardrail that was missing: a story with `depends_on` shouldn't be handed to `feature-orchestrator` until what it depends on has actually merged. `depends_on` was schema-valid metadata with nothing enforcing it.

**Why**: the real fix for cross-story state visibility isn't faster infrastructure, it's recognizing which stories can't safely run fully concurrently and sequencing those specific ones — the same logic already governing task-level `parallel_group` safety, one level up.

## 5.0.0 — decision-recorder moved back to skills/

**Breaking**
- `decision-recorder` moved from `agents/decision-recorder.md` back to `skills/decision-recorder/SKILL.md`. Runs inline now, on whatever model the calling session is on — no more Haiku 4.5 pin.
- `feature-orchestrator` and `project-scoper` updated at every call site (steps 7, 10, 14, the Story amendment loop, and Phase 4) from "delegate to the decision-recorder agent" back to "invoke /decision-recorder".
- `agents/` is down to 4: `risk-classifier`, `story-converter`, `validator`, `implementer`.

**Why**: unlike the other three agents, `decision-recorder` doesn't benefit from isolation on any axis. It isn't judgment work that benefits from fresh eyes (that's `validator`'s case), it isn't enforcing a structural safety boundary (that's `implementer`'s), and it's invoked far more often than either — at least three times per story plus every amendment. Its entire job is capturing reasoning that just happened in the calling session; isolating it means re-explaining that reasoning explicitly on every call, which costs more tokens for a plainly worse result, since the caller can omit nuance it didn't think to restate. `risk-classifier` and `story-converter` weren't reconsidered here — both run far less frequently, so the isolation overhead argument doesn't carry the same way.

## 4.1.0 — Scaled validator's effort to risk tier

**Changed**
- `validator` agent's frontmatter default effort dropped from `high` to `medium` — that's now just the standalone fallback for direct invocation, not what most calls actually use.
- `feature-orchestrator` step 12/13 now pass effort explicitly per this story's risk tier: medium for L2, high for L3. `build-feature`'s validator calls (Phase 2/3) pass low effort explicitly, since that path only ever runs for L1.
- The bug-fix-only workflow, which never runs `risk-classifier`, pins its validator call to a fixed medium effort rather than defaulting to high for every bug fix regardless of actual stakes.

**Why**: high effort on every validator call regardless of risk was the same mistake already caught once this session with `risk-classifier`'s output being computed but not acted on — the data was sitting right there. Sonnet 4.6 or a cheaper model were considered and rejected (Sonnet 4.6 is pricier per token than Sonnet 5 and less capable; a cheaper model risks missing exactly the security/performance issues validator exists to catch) — effort was the correct, already-available lever.

## 4.0.0 — implementer always isolated; moved to agents/

**Breaking**
- `implementer` moved from `skills/implementer/` to `agents/implementer.md`. The conditional isolation from 2.4.0/3.0.0 (forked + Sonnet 5 high effort for `parallel_group` tasks, inline on the session's model otherwise) is gone — every task now runs as an isolated implementer agent call, always Sonnet 5 at high effort, regardless of `parallel_group`.
- `feature-orchestrator` step 11 simplified accordingly: no more per-task branching on whether to isolate. `parallel_group` still controls concurrency (same group = concurrent calls), just not isolation or model tier anymore, since those are now constant.
- `build-feature` and `context-compressor` updated to reference the implementer agent correctly; `context-compressor`'s note comparing itself to implementer's old inline path no longer applies and was corrected.

**Why**: the case for conditional inline execution was a plausible hypothesis about cost savings that was never actually measured, traded against a real, immediate cost — solo tasks silently inheriting whatever model the session happened to be on instead of a guaranteed tier, plus a weaker `files_touched` boundary (everything in session context stays technically reachable when running inline) and a second code path to maintain correctly. Reverted to the simpler always-isolated design until real telemetry (see 2.x's cost-model discussion) justifies reintroducing the conditional path.

**Also investigated, not changed**: whether `validator`'s model tier could drop to Sonnet 4.6 or a cheaper model to reduce token usage. Checked current pricing — Sonnet 4.6 is $3/$15 per million tokens versus Sonnet 5's $2/$10, so it would cost more per equivalent unit of work while reviewing worse. The actual lever for token usage is `effort`, not model — a candidate for a future change is scaling `validator`'s effort level with `risk-classifier`'s output (e.g. medium for L1/L2, high for L3) rather than the current flat high effort for every story.

## 3.0.0 — Split into skills/ and agents/

**Breaking**
- New top-level `agents/` directory. `risk-classifier`, `story-converter`, `decision-recorder`, and `validator` moved out of `skills/` and are now persistent `.claude/agents/*.md` subagent definitions — fixed identity, always isolated, model set once in frontmatter rather than needing `context: fork` plus a belt-and-suspenders call-time override. Projects on 2.x need to run `install.ps1` again after upgrading; the four old `skills/<name>/` directories are gone, and anything referencing them by their old skill path needs updating.
- `implementer` stays a skill, deliberately. A persistent agent is always isolated by definition — that would silently remove the conditional inline path for solo tasks introduced in 2.4.0. It's still sometimes run inline and sometimes delegated to as an ad-hoc isolated call, decided per task by `feature-orchestrator`, exactly as before — just described accurately now instead of borrowing "forked subagent" language that implied a persistent identity it doesn't have.
- `install.ps1` now installs `agents/*` -> `.claude/agents/`, always overwritten, same as `skills/` and `schemas/`.
- Fixed the Scope amendment loop's "resume implementer" wording, which read like a paused process picking back up. It's actually a fresh call reading the task's current on-disk state — nothing needs to carry over in memory, because whatever `implementer` already built is sitting in the files themselves.

**Why**: a skill's frontmatter `model:` field is temporary, resetting after the turn; a subagent's is permanent, defining who that worker is every time it runs. Four of these five had a fixed identity and no interactive/inline requirement — real subagents describe them more honestly than a skill made to always fork.

## 2.5.0 — Pinned the mechanical skills to Haiku 4.5

**Changed**
- `risk-classifier`, `story-converter`, `decision-recorder` — added `context: fork` and `model: claude-haiku-4-5-20251001` to frontmatter. Classification, ticket formatting, and log-writing don't need a heavier model, and forking makes the pin reliable the same way it does for `validator`.
- `context-compressor` — added the Haiku model preference, but deliberately *not* `context: fork`. It has to see the session's live accumulated context to compress it; forking would hand it nothing to work with. Its pin is best-effort, same caveat as `implementer`'s inline path from 2.4.0 — documented explicitly in its own file rather than left implicit.
- `feature-orchestrator` and `project-scoper` — added a consolidated "Model tiers" section instead of annotating every individual invocation, since four of the fourteen skills now have a non-default tier.

## 2.4.0 — Made implementer's isolation conditional on parallel_group

**Changed**
- `implementer` no longer has a blanket `context: fork` — isolation only happens for tasks with a `parallel_group` set, decided per task by `feature-orchestrator`, not as a static property of the skill.
- Solo tasks (`parallel_group: null`) now run inline in the orchestrator's session, skipping the cost of re-establishing context — but as a direct consequence, they no longer get a guaranteed model pin. Only forked (parallel) tasks are explicitly pinned to Sonnet 5, high effort; inline tasks inherit whatever model the session is already on. This coupling isn't a bug — a model/effort choice only exists at the point something is spun up as its own call, so it can't be pinned independently within a shared session.

## 2.3.0 — Pinned implementer/validator to Sonnet 5, high effort

**Changed**
- `implementer` and `validator` frontmatter now declare `context: fork`, `model: claude-sonnet-5`, and `effort: high` — this is what makes their isolation and model tier structural properties of the skill rather than something the orchestrator has to achieve purely through instruction.
- `feature-orchestrator` steps 11/12 now also pass the model and effort explicitly on the invocation itself, as a deliberate belt-and-suspenders measure against the reported unreliability of frontmatter `model:` fields on some Claude Code versions (see 2.2.0's note).

**Not yet configured**: `risk-classifier`, `story-converter`, `decision-recorder`, and `context-compressor` don't have a `model` tier set — they're candidates for a cheaper/faster model given their more mechanical nature, but that hasn't been confirmed yet.

## 2.2.0 — Made validator/bug-fixer execution mode explicit

Previously undefined in the skill text — only implementer's parallel_group tasks were explicitly specified as running in separate subagent sessions.

**Changed**
- `feature-orchestrator` steps 12/13 — `validator` now explicitly runs as an isolated subagent, given the diff, approved spec, approved plan, and acceptance criteria as explicit input rather than the accumulated session context, for the fresh-eyes review benefit. `bug-fixer` explicitly receives `validator`'s structured findings (failed checks, recommended fixes) as input rather than relying on shared session history.
- Applied the same `validator`-as-isolated-subagent rule to the bug-fix-only workflow.
- Added a `Never` guardrail against reviewing from accumulated session context instead of an explicit handoff.

## 2.1.0 — Validator performs a code review

**Added**
- `validator` now explicitly reviews the actual diff for security (input validation, injection, auth/authz, secrets, unsafe deserialization, dependency vulnerabilities), performance (inefficiencies, N+1 queries, unnecessary allocations, blocking calls, unbounded loops), and code quality (naming, duplication, complexity, maintainability) — not just the existing correctness/convention/regression checklist.
- Findings are tagged `blocking` or `non-blocking`. A naming nit doesn't hold up delivery; an injection risk does.

**Changed**
- `feature-orchestrator` step 13 now triggers `bug-fixer` only on blocking findings. Non-blocking findings are carried into the delivery summary (step 15) instead of triggering an automatic fix cycle.

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
