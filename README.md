# agentic-sdlc-core

A reusable multi-agent orchestration layer for AI-assisted software development, built on Claude Code skills. One versioned core, vendored into each project that uses it.

## What's in here

- **`skills/`** — 9 skills that run inline in the calling session:
  - **Program scoping** (`project-scoper`) — turns a PRD or an existing repo into an approved story backlog, run once per project.
  - **Story execution** (`feature-orchestrator` and everything else it calls) — runs once per story, often by a different engineer, producing spec → plan → implementation → validation for that story alone.
- **`agents/`** — 5 fixed-identity subagents, always isolated, always on a pinned model, invoked by `feature-orchestrator`/`project-scoper` rather than run inline: `risk-classifier`, `story-converter`, `validator`, `implementer`, `bug-fixer`. `decision-recorder` deliberately isn't one of these — it's invoked at least three times per story plus every amendment, the highest frequency of anything here, and it's capturing reasoning that just happened in the calling session, so isolating it would mean re-explaining that reasoning rather than saving anything.
- **`schemas/`** — the data contracts that let these hand off to each other and to external tools (a ticketing system, a dashboard) without ambiguity:
  - `story-backlog.schema.json` — output of the `story-converter` agent (spec mode), written once per project to `.claude/state/story-backlog.json`
  - `task-graph.schema.json` — output of `implementation-planner`
  - `decision-log.schema.json` — one line of `decision-log.jsonl` per entry, written by `decision-recorder`
- **`scripts/`** — three maintenance scripts, run manually and on demand, none run automatically by anything else in this system:
  - `rotate-decision-log.ps1` — keeps `decision-log.jsonl` from growing unbounded over a project's lifetime; archives older entries with `reasoning`/`alternatives_considered`/`tradeoffs` stripped, keeps `id`/`date`/`story_id`/`decision`/`consequences`.
  - `export-adrs.ps1` — renders `significance: architectural` log entries as individual ADR files in `docs/adr/`. A projection of the log, never a second source of truth.
  - `token-usage-report.ps1` — reads the Claude Code session transcript and renders a terminal bar chart of token usage per agent (exact) and per skill (best-effort heuristic). Works against a still-running session, not just a finished one. `-Html` writes a presentable, colored version to `.claude/analytics/` for sharing with a non-technical audience.
- **`project-template/`** — the `.claude/` skeleton to copy into a new project that will use this core.

## How the pieces fit together

```
project-scoper                              (once per project)
  → repo-discovery, grill-me, spec-writer, decision-recorder
  → story-converter agent, spec mode (Haiku 4.5)     → story-backlog.schema.json

feature-orchestrator                        (once per story, per engineer)
  → repo-discovery
  → risk-classifier agent (Haiku 4.5)
  → L1 → build-feature (fast path)
  → L2/L3 → grill-me, spec-writer, implementation-planner → task-graph.schema.json
          → implementer agent × N (Sonnet 5, high effort) — sequential + concurrent per parallel_group
          → validator agent (Sonnet 5, effort scaled to risk tier: low/medium/high), bug-fixer agent as needed
          → decision-recorder               → decision-log.schema.json, one JSONL line (always written, regardless of context_mode)
          → story-converter agent, plan mode (Haiku 4.5)     → marks the story's one ticket complete
```

`story-converter` only ever creates a ticket in spec mode, once per story, at `project-scoper` time. Plan mode exists solely to update that same ticket — fired only by a scope amendment, a story amendment, or the completion step above, never on a routine schedule.

Two amendment loops are built into `feature-orchestrator` for the two things that reliably go wrong mid-story:
- **Scope amendment loop** — `implementer` needs a file outside its declared `files_touched`.
- **Story amendment loop** — acceptance criteria change after the spec was approved.

Both patch forward (spec/plan amendment, re-check parallel-safety, note the change on the story's ticket, lightweight approval) rather than restarting the story.

## Using this in a project

Run `install.ps1` from the root of the target project repo:

```powershell
.\install.ps1 -RepoUrl "https://github.com/<org>/agentic-sdlc-core.git" -Ref "v5.4.1"
```

This clones agentic-sdlc-core at the pinned ref (a tag, branch, or commit), installs all skills into `.claude/skills/`, all agents into `.claude/agents/`, the schemas into `.claude/schemas/`, and both maintenance scripts into `.claude/scripts/`, records what's installed in `.claude/agentic-sdlc-core.version`, and scaffolds `.claude/CLAUDE.md`, `.claude/config/orchestration.yaml`, and `.claude/state/` from `project-template/` — but only creates files that don't already exist, so re-running it is safe and never clobbers a project's own config or decision log.

Fill in `.claude/config/orchestration.yaml` for that project afterward — ticket system, `context_mode_default`, risk thresholds. See `project-template/.claude/config/orchestration.yaml` for the format.

**To update a project to a newer core version**, re-run with a new `-Ref`:

```powershell
.\install.ps1 -RepoUrl "https://github.com/<org>/agentic-sdlc-core.git" -Ref "v5.5.0"
```

Skills, agents, schemas, and scripts always sync to the newly pinned ref; project config and state are left alone unless you pass `-Force`. Commit the resulting changes under `.claude/` to your project's own version control — the script doesn't do that for you.

Requires `git` on `PATH`. Run `Get-Help .\install.ps1 -Full` for all parameters.

## Not included here

`zoom-out` and `caveman` (personal/communication-style tools) are intentionally left out — they're user-level preferences, not project infrastructure, so they belong in `~/.claude/skills/` on your own machine rather than versioned into every project.

## Versioning

See `VERSION` and `CHANGELOG.md`. This repo follows semver: breaking changes to a schema or to a skill's expected inputs/outputs bump the major version.
