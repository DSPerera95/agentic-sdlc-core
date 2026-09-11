# Open discussions

Things that got real design discussion in this project's history and were deliberately not built yet — not gaps that were missed. Check here before assuming an absence is an oversight. Move an item out of this file and into `CHANGELOG.md` once it's actually implemented.

## MCP tool integration for skills/agents

Discussed, not built. Claude Code subagents support an `mcpServers` field in their own frontmatter — the same place `model`/`effort` already live for the four existing agents — so this is additive to the current architecture, not a new layer.

Where it was prioritized:
- **`story-converter` — the clear first candidate.** "Creates one ticket per story in the configured ticket system" has been narrated prose since `story-converter` was first written, with no actual mechanism behind it. A Jira/Azure DevOps MCP server closes that gap directly.
- **`validator` + a security/dependency scanner — promising, held.** Would ground findings in real tool output instead of only the model's own judgment, but which scanner makes sense varies a lot by stack, so it's a poor fit for the shared core as a default. More likely a per-project addition layered on top, not something `agentic-sdlc-core` should standardize.
- **`bug-fixer` + an observability tool (Sentry-style) — speculative.** Plausible, but held until the `story-converter` pattern actually proves out in practice.

Design constraints agreed on, not yet implemented:
- The *concept* of a ticket-system tool belongs in the shared core (`story-converter`'s instructions should say "use whichever ticket-system MCP tool this project has configured"); the specific server and credentials belong in each project's own local Claude Code config, the same seam `orchestration.yaml`'s `ticket_system.provider` already establishes. `install.ps1` should never wire actual MCP servers or credentials.
- Per-agent MCP access should be scoped (Claude Code's `tools`/`disallowedTools` fields), the same way `implementer` is scoped to `files_touched` — `story-converter` needs create/update access to tickets, not blanket access to whatever else the MCP server exposes.
- Isolation and MCP tool access are orthogonal — an isolated agent with a scoped MCP tool is exactly as isolated as one with no tools; isolation is about what an agent remembers, not what it's allowed to call.

**Open question, unresolved:** does the org actually use one ticket system uniformly, or does it vary by team? If it varies, `story-converter` needs a defined fallback (narrate the ticket for a human to create manually) for projects with no MCP server configured, not an assumption that one always exists.

**Resolved for internal state, as of 7.5.0**: the concurrent-branch state-sharing question (a different one from the ticket-system MCP integration above, but using the same mechanism) is addressed for teams that opt in - see `docs/superpowers/specs/2026-09-11-turso-state-backend-design.md` and the `7.5.0` `CHANGELOG.md` entry. The ticket-system MCP integration itself, and its open question about whether an org uses one ticket system uniformly, remain unbuilt and unresolved.

## Multi-repo workspace pattern

Parked at the user's request — current system is single-repo only, deliberately.

The shape discussed: a VS Code multi-root workspace with an "orchestration plane" as its own repo/root folder (containing `.claude/`, decoupled from any single code repo's branch lifecycle), with the actual code repos as sibling folders Claude Code can see and act across.

What was identified as genuinely valuable: it resolves an ambiguity the current single-repo design doesn't have an answer for — which repo's branch does `.claude/state/` live on when a feature spans more than one repo? An orchestration-plane repo with its own independent PR lifecycle answers that cleanly instead of picking an arbitrary winner.

What would actually need to change, not just get configured:
- `files_touched` needs a repo-qualifier convention (e.g. `booking-service/src/...`) for the parallel-safety rule to keep working across repos.
- `repo-discovery` currently does one broad pass over one repo — multi-repo needs it to either sweep all of them or know from a manifest which are relevant to a given story.
- A single story could require multiple PRs (one per touched repo, plus the orchestration plane's own state PR) instead of one — real added coordination cost, not just a config change.

**Open question, unresolved:** should `orchestration.yaml` re-list the repos at all, or should `project-scoper`/`repo-discovery` read the `.code-workspace` file directly as the actual source of truth? Leaning toward the latter per the never-duplicate-a-source-of-truth principle, but not decided — `orchestration.yaml` might still be the right place for information the workspace file genuinely doesn't express (a "primary" repo designation, or a per-repo `context_mode` default).

## Cost telemetry

Flagged as a real gap (see the "is this enterprise-ready" discussion in the project's history). Partially resolved as of 5.5.0 — see below for what's still open.

- **Resolved in 5.5.0**: token usage visibility per skill/agent, via `scripts/token-usage-report.ps1` — see `CHANGELOG.md`. Claude Code hooks don't receive token usage/cost data directly in their payload, so a `Stop` hook parsing the transcript after the fact was the only mechanism previously considered here; reading the transcript on demand instead turned out to work better and was simpler to build, since it also works mid-session, which a `Stop` hook structurally cannot.
- Still open: converting token counts to a dollar figure — no pricing table exists anywhere in this repo, and this script deliberately stops at token counts.
- Still open: a budget/circuit-breaker for the Scope and Story amendment loops (cap the iteration count, escalate to a human on breach) was discussed as pure state-and-config with no new platform mechanism needed — agreed as sound, never actually implemented.
- Model-tier routing (Haiku for the mechanical agents, Sonnet for judgment-heavy ones) and risk-scaled `validator` effort are both live in the current version, but neither is backed by measured cost data — they're reasoned defaults, not validated ones. Worth remembering when asked to justify them with numbers.

## Eval harness / unproven-at-scale

Named explicitly as a limitation, not built. Nothing in this repo currently measures, across many real runs:
- Whether `implementer` actually respects `files_touched` at the rate the parallel-safety guarantee assumes, versus occasionally reaching outside it without reporting.
- Whether `risk-classifier` gives consistent L1/L2/L3 answers for materially the same change described two different ways.
- Whether `validator`'s blocking/non-blocking line holds steady across many diffs, or drifts.

The `skill-creator` example skill (available in Claude Code more broadly, not part of this repo) is a plausible tool for building this, mentioned but not acted on.

## Agent/skill classification left unrevisited

During the skills → agents migration, `spec-writer` and `implementation-planner` were explicitly flagged as "genuinely unsure, could go either way" and deliberately left as skills without a real decision either way. Neither is settled — they're just untouched, not confirmed-correct.

`bug-fixer` was in the same unrevisited bucket and has since moved to `agents/` (see `CHANGELOG.md`) - unlike `spec-writer`/`implementation-planner`, its call sites were actually audited first: all of them already passed explicit input rather than leaning on session history, and one real gap (`build-feature`'s call site wasn't explicitly passing validator's findings) was fixed before the move, not glossed over.
