# CLAUDE.md — agentic-sdlc-core

This file is read automatically at the start of every Claude Code session in this repo. It's the orientation layer — enough to pick up development on this project without re-deriving decisions already made. Deeper detail lives in the files linked throughout; don't duplicate their content here, extend or correct it there instead.

## What this is

A reusable multi-agent orchestration layer for AI-assisted software development, distributed as a versioned core that individual projects install via `install.ps1` and vendor into their own `.claude/`. Two tiers: `project-scoper` runs once per project turning a PRD/existing repo into a story backlog; `feature-orchestrator` runs once per story, producing spec → plan → implementation → validation for that story alone, often by a different engineer than the one who scoped the project.

Current version: see `VERSION` (currently `7.4.0`). Full history and the reasoning behind every change: `CHANGELOG.md` — read it before assuming why something is the way it is; it's usually already answered there.

## Repo structure

```
skills/      9 skills — run inline in the calling session
agents/      5 agents  — risk-classifier, story-converter, validator, implementer, bug-fixer
             (fixed-identity, always isolated, pinned model — see DESIGN-PRINCIPLES.md
             for why decision-recorder is deliberately NOT here despite looking similar)
schemas/     task-graph, story-backlog, decision-log — the data contracts between everything
scripts/     rotate-decision-log.ps1, export-adrs.ps1, token-usage-report.ps1 — manual/on-demand, never auto-run
project-template/  the .claude/ skeleton install.ps1 scaffolds into a new project
install.ps1  the installer — see the "Known gotcha" below before editing it
```

- `README.md` — what this is, for someone deciding whether to adopt it.
- `HOW-IT-WORKS.md` — full mechanics with diagrams and a worked example, for someone using it.
- `docs/DESIGN-PRINCIPLES.md` — the recurring judgment calls that should govern any new change. Read this before adding anything non-trivial.
- `docs/OPEN-DISCUSSIONS.md` — things discussed at length but deliberately not yet built. Check here before treating an absence as an oversight.

## Known gotcha — read before editing any `.ps1` file

**Never use non-ASCII characters** (em-dashes, curly quotes, arrows) in `install.ps1`, `rotate-decision-log.ps1`, or `export-adrs.ps1` — plain ASCII only, including in comments. Windows PowerShell 5.1 often reads a UTF-8 file without a BOM using the system ANSI codepage instead, which mangles multi-byte characters into garbage bytes that can look like a stray quote to the parser. The failure surfaces as a confusing "missing terminator" error several lines *after* the actual corruption, not at it. Fixed once already in 5.4.1 — don't reintroduce it by pasting prose with an em-dash into a script.

## How to work in this repo

This is the orchestration system itself, not a project built with it — there's no `.claude/skills` of its own installed here to invoke; the skills and agents in this repo *are* the product. Changes happen the way they always have: edit the relevant `SKILL.md`/`agent.md`/schema/script directly, keep every cross-reference between files consistent, bump `VERSION` and add a `CHANGELOG.md` entry for anything that isn't a typo fix, and update `HOW-IT-WORKS.md`/`README.md` if the change is user-visible.

Versioning discipline (already established, keep following it):
- **Major** — a file moves between `skills/`/`agents/`, a schema field's meaning changes, an existing behavior is removed or reversed.
- **Minor** — a genuinely new capability, additive and backward-compatible.
- **Patch** — a bug fix with no behavior change for anyone already using it correctly.

When a change affects how a skill or agent is invoked, grep the whole repo for the old invocation before considering it done — this codebase has a real history of a rename or migration missing one caller (`build-feature`'s stale `/risk-classifier` reference, `context-compressor`'s stale comparison to `implementer`'s old inline path) and only getting caught by a careful re-check, not automatically.

## Design taste to carry forward

A few defaults have been re-derived enough times in this project's history that they're worth stating once: don't duplicate a source of truth (ticket sync, ADR export, and `depends_on` were all corrected toward this at some point); don't leave computed data unused (`risk-classifier`'s output being ignored, and `depends_on` not being enforced, were both real bugs caught late); prefer a narrow default with an explicit, cheap escalation path over a broad default that blocks (`context_mode` + context escalation, `depends_on` narrowed to contract-only); and isolate an agent only where isolation earns its cost, not by default (`validator` yes, `decision-recorder` no — see `DESIGN-PRINCIPLES.md` for the full reasoning on both). If a proposed change conflicts with one of these, that's worth surfacing explicitly rather than quietly going along with it.
