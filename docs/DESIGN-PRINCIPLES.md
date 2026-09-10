# Design principles

Not a spec — a record of judgment calls that came up more than once, so they don't need to be re-litigated from scratch every time something similar comes up. When a new decision conflicts with one of these, that's worth naming explicitly, not silently overriding.

## Never duplicate a source of truth

Every time this system has had two places claiming to know the same fact, one of them drifted or became redundant. `story-converter` creates exactly one ticket per story, at spec-mode time — plan mode only ever updates that same ticket, because a "create tickets per task" layer once existed and was removed for exactly this reason. ADR files are a generated projection of `decision-log.jsonl`, regenerated on every export run, never hand-edited — the log is the only source of truth. `depends_on`'s repo-list equivalent (raised in the MCP/multi-repo discussion) should read from wherever the real list already lives (a VS Code `.code-workspace` file, if that pattern is ever built) rather than re-listing it in `orchestration.yaml`.

## Computed-but-unused data is a bug, not a placeholder

`risk-classifier` originally ran and produced a tier that `feature-orchestrator` never branched on — L1 and L3 work went through the identical full pipeline. `depends_on` was schema-valid metadata `project-scoper` never actually checked before handing a story off. Both were real, shipped bugs, not intentional scaffolding for later. If something is computed, something must consume it before calling the work done.

## Narrow default + cheap escalation beats broad default + blocking

`context_mode` starts narrow (`independent`/`decision-log-only`) and escalates to `full-spec` mid-story if it turns out wrong — no approval gate, just a log entry explaining why. `depends_on` was briefly broadened to cover "might benefit from awareness," which meant sequencing stories for a reason that didn't actually require blocking; narrowed back to genuine contract dependencies only, with awareness handled by context escalation instead. The pattern generalizes: when unsure whether a story/task/agent needs more than the minimum, default to the minimum and make escalating cheap, rather than defaulting to more and eating the cost on every case to cover the rare one.

## Isolation is a tool, not a virtue — earn it per component

Five things ended up as isolated agents (`risk-classifier`, `story-converter`, `validator`, `implementer`, `bug-fixer`); one thing that looked like it should join them deliberately isn't (`decision-recorder`). The difference: `validator` benefits from fresh eyes — no memory of how the code was built is the point. `decision-recorder` is the opposite — its whole job is capturing reasoning that just happened in the calling session, so isolating it means re-explaining that reasoning explicitly on every call, at the highest invocation frequency in the system (3+ times per story plus every amendment), for a worse result, not a better one. `implementer` went through a conditional-isolation phase (forked only for `parallel_group` tasks, inline otherwise) and was reverted to always-isolated — the conditional version traded a real, immediate cost (inconsistent model quality on solo tasks) for a theoretical, never-measured savings. `bug-fixer` moved from skill to agent only after auditing its actual call sites for a hidden dependency on shared session context, rather than assuming its shape was enough on its own — one real dependency was found (a caller not explicitly passing along a prior diagnosis) and fixed before the move, not glossed over. Don't isolate by default; check whether the specific component's job benefits from a blank slate or is actively hurt by one.

## Explicit beats inferred, especially for model/effort

Subagent frontmatter (`model`, `effort`) is the honest place to declare a component's identity, but it's not fully trusted alone — `feature-orchestrator` also passes model/effort explicitly on the actual invocation, because an explicit call-time parameter is more reliably respected than a frontmatter default across Claude Code versions. Belt-and-suspenders here is deliberate, not redundant.

## Skills vs. agents is a real distinction, not a naming choice

A **skill** is a procedure injected into the calling session — it can be conditional, interactive, and it inherits whatever context already exists. An **agent** is a fixed identity — always isolated, always the same pinned model, no access to session history, returns once. `grill-me` can never be an agent: it's a live multi-turn dialogue with a human, and an agent's shape (one call in, one result out) has no room for that. `implementer` moved to `agents/` only once its isolation stopped being conditional — a persistent agent is isolated by definition, so anything that sometimes needs to run inline can't honestly be one.

## Don't build speculative infrastructure ahead of a proven need

A CI-driven auto-merge path for `.claude/state/` was designed in real detail and then not built — direct-to-trunk state commits were correctly rejected as dangerous, and the "fast PR with auto-merge" alternative was still more machinery than the actual problem (state visibility lag between concurrent stories) turned out to warrant once `depends_on` and context escalation existed. Cost telemetry, an eval harness, and MCP-backed tool access for `validator`/`bug-fixer` are all in this same bucket — named and reasoned about, deliberately not built until there's a concrete, proven need rather than a plausible-sounding one. See `OPEN-DISCUSSIONS.md`.

## Name a limitation plainly instead of routing around it

When asked whether this system is enterprise-ready, the honest answer was "strong SDLC orchestration layer, not a replacement for CI/CD, access control, or audit infrastructure" — stated that way, not softened. The same discipline applies to internal design write-ups: a limitation gets a line explaining what it actually costs, not a reframe that makes it sound intentional when it's genuinely just not built yet.
