# agentic-sdlc-core

A reusable multi-agent orchestration layer for AI-assisted software development, built on Claude Code skills. One versioned core, vendored into each project that uses it.

## What's in here

- **`skills/`** — 14 skills covering two tiers:
  - **Program scoping** (`project-scoper`) — turns a PRD or an existing repo into an approved story backlog, run once per project.
  - **Story execution** (`feature-orchestrator` and everything it calls) — runs once per story, often by a different engineer, producing spec → plan → implementation → validation for that story alone.
- **`schemas/`** — the data contracts that let these skills hand off to each other and to external tools (a ticketing system, a dashboard) without ambiguity:
  - `story-backlog.schema.json` — output of `story-converter` (spec mode)
  - `task-graph.schema.json` — output of `implementation-planner`
  - `decision-log.schema.json` — entries written by `decision-recorder`
- **`project-template/`** — the `.claude/` skeleton to copy into a new project that will use this core.

## How the pieces fit together

```
project-scoper                              (once per project)
  → repo-discovery, grill-me, spec-writer, decision-recorder
  → story-converter (spec mode)             → story-backlog.schema.json

feature-orchestrator                        (once per story, per engineer)
  → repo-discovery, risk-classifier
  → L1 → build-feature (fast path)
  → L2/L3 → grill-me, spec-writer, implementation-planner → task-graph.schema.json
          → story-converter (plan mode)     → tickets created before implementation starts
          → implementer × N (sequential + parallel, per parallel_group)
          → validator, bug-fixer as needed
          → decision-recorder               → decision-log.schema.json (always written, regardless of context_mode)
          → story-converter (plan mode)     → tickets synced to final status
```

Two amendment loops are built into `feature-orchestrator` for the two things that reliably go wrong mid-story:
- **Scope amendment loop** — `implementer` needs a file outside its declared `files_touched`.
- **Story amendment loop** — acceptance criteria change after the spec was approved.

Both patch forward (spec/plan amendment, re-check parallel-safety, sync tickets, lightweight approval) rather than restarting the story.

## Using this in a project

Run `install.ps1` from the root of the target project repo:

```powershell
.\install.ps1 -RepoUrl "https://github.com/<org>/agentic-sdlc-core.git" -Ref "v1.0.0"
```

This clones agentic-sdlc-core at the pinned ref (a tag, branch, or commit), installs all skills into `.claude/skills/` and the schemas into `.claude/schemas/`, records what's installed in `.claude/agentic-sdlc-core.version`, and scaffolds `.claude/CLAUDE.md`, `.claude/config/orchestration.yaml`, and `.claude/state/` from `project-template/` — but only creates files that don't already exist, so re-running it is safe and never clobbers a project's own config or decision log.

Fill in `.claude/config/orchestration.yaml` for that project afterward — ticket system, `context_mode_default`, risk thresholds. See `project-template/.claude/config/orchestration.yaml` for the format.

**To update a project to a newer core version**, re-run with a new `-Ref`:

```powershell
.\install.ps1 -RepoUrl "https://github.com/<org>/agentic-sdlc-core.git" -Ref "v1.1.0"
```

Skills and schemas always sync to the newly pinned ref; project config and state are left alone unless you pass `-Force`. Commit the resulting changes under `.claude/` to your project's own version control — the script doesn't do that for you.

Requires `git` on `PATH`. Run `Get-Help .\install.ps1 -Full` for all parameters.

## Not included here

`zoom-out` and `caveman` (personal/communication-style tools) are intentionally left out — they're user-level preferences, not project infrastructure, so they belong in `~/.claude/skills/` on your own machine rather than versioned into every project.

## Versioning

See `VERSION` and `CHANGELOG.md`. This repo follows semver: breaking changes to a schema or to a skill's expected inputs/outputs bump the major version.
