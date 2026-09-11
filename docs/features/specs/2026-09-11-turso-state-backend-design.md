# Turso-backed state store for story-backlog and decision-log (opt-in)

Status: proposed, not yet built. Design doc from a brainstorming session on 2026-09-11.

## Context / problem

Target scenario: a monorepo with 5-6 engineers, each running their own `feature-orchestrator` session on their own feature branch, implementing a story assigned from a backlog a tech lead produced once via `project-scoper`. Today, `.claude/state/story-backlog.json` and `.claude/state/decision-log.jsonl` are plain files that live inside whatever branch a session happens to be on. That's fine for a single engineer; it breaks down once multiple engineers' branches each carry their own copy of the same files and those copies need to reconcile.

The two files don't share the same risk, and the design should say so honestly rather than treat them as symmetric:

- **`decision-log.jsonl` has a real, currently-existing concurrency bug.** `decision-recorder` (a skill, not an agent — see `docs/DESIGN-PRINCIPLES.md`) is invoked "at least three times per story plus every amendment" per its own frontmatter — across 5-6 concurrently active stories, that's genuine concurrent-append pressure. Its id-assignment procedure is "read the file, find the highest `DEC-####`, use the next number" (`skills/decision-recorder/SKILL.md`) — a classic read-then-increment race under concurrency.
- **`story-backlog.json` has no status field and is write-once.** Per `schemas/story-backlog.schema.json` and `agents/story-converter.md`, it's written once at spec-mode time (plus the rare case of `project-scoper` re-running against an already-scoped project to add new stories); the ticket system, not this file, is the system of record for anything that changes afterward. Its actual risk is that each engineer's branch has a possibly-stale local copy, not write contention.

Both still belong in scope — for different reasons, stated separately in this doc rather than implied to be the same problem.

## Goals

- Eliminate the `decision-log` id-race condition with a mechanism that makes concurrent-safe sequential ids a property of the storage layer, not of caller discipline.
- Give every engineer's session a consistent, non-branch-local view of `story-backlog.json` and `decision-log.jsonl`.
- Do this as an **opt-in** addition, not a replacement — projects that don't have this concurrency problem (solo engineer, small team) keep the current zero-infrastructure, file-based default untouched.
- Preserve compatibility with `scripts/rotate-decision-log.ps1` and `scripts/export-adrs.ps1` without modifying either.

## Non-goals (explicitly out of scope for this spec)

- Migrating `stories_dir` contents (`spec.md`, `plan.json`, `ticket.json`) — these aren't cross-engineer-shared the way the two files above are; each story folder has exactly one writer.
- The ticket-system MCP integration (Jira/Azure DevOps) — a separate, already-discussed item in `docs/OPEN-DISCUSSIONS.md`, unrelated to this one beyond sharing the general MCP mechanism.
- The multi-repo workspace pattern — separately parked in `docs/OPEN-DISCUSSIONS.md`, orthogonal to this single-repo design.
- An embedded local replica of the Turso database (faster reads, offline read capability) — direct remote connection is the starting default; revisit only if read latency is measured to be a real problem.
- Offline queueing / retry-on-failure for writes — hard-fail-and-surface is the starting default; revisit only if flaky connectivity turns out to be a real recurring problem in practice.

## Approaches considered

1. **Custom-hosted REST API + a database you stand up yourself.** Rejected: you'd own hosting, schema migrations, backups, and auth from scratch — a much bigger commitment than the problem warrants.
2. **Git-native dedicated branch + worktree, no external database.** Rejected as the primary mechanism: still requires a commit/push/rebase-retry loop for every write, and does not remove the `decision-log` id-race condition, since "highest id in the file" is still read-then-increment even on a branch nobody else's feature work touches.
3. **Local MCP server + Turso (hosted libSQL) — chosen.** A hosted database gives real transactional writes and atomic autoincrement for free, which is exactly the concurrency-safety property neither alternative provides without building it by hand. A local/stdio MCP server means nobody has to host or operate anything themselves — Turso is the only new hosted dependency, and it's a managed one.

## Architecture

```
decision-recorder (skill)   ─┐
story-converter (agent)     ─┼─► local MCP server (stdio, per engineer) ─► Turso (hosted primary)
feature-orchestrator (skill)─┘
```

Activated per project via `orchestration.yaml`'s `state_backend: turso` (default remains `file`, fully unmodified). Each engineer runs their own local MCP server instance (Node/TypeScript, spawned as a stdio process by Claude Code — the standard local MCP server mechanism, nothing hosted by the project or its engineers). The server connects **directly to the remote Turso primary per call**, via `@libsql/client` — no embedded replica. It is stateless itself: an MCP tool call in, parameterized SQL out, typed result back.

A fourth, occasional actor — an export script — reads the live Turso tables and regenerates the file-based view on a dedicated branch, described below.

## Data model

Three tables in the Turso database:

```sql
CREATE TABLE backlog_meta (
  id INTEGER PRIMARY KEY CHECK (id = 1),   -- enforces exactly one row
  project TEXT NOT NULL,
  program_spec_ref TEXT,
  architecture_mode INTEGER NOT NULL DEFAULT 0   -- boolean
);

CREATE TABLE stories (
  id TEXT PRIMARY KEY,                -- e.g. "STORY-014", assigned by story-converter same as today
  title TEXT NOT NULL,
  ticket_id TEXT NOT NULL,
  acceptance_criteria TEXT NOT NULL,  -- JSON array, stored as text
  context_mode TEXT NOT NULL,         -- 'full-spec' | 'decision-log-only' | 'independent'
  depends_on TEXT,                    -- JSON array, stored as text; NULL/empty if none
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE decisions (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,   -- the real id source; solves the id-race directly
  date TEXT NOT NULL,
  story_id TEXT NOT NULL,
  significance TEXT NOT NULL DEFAULT 'routine',
  context TEXT,
  decision TEXT NOT NULL,
  reasoning TEXT,
  alternatives_considered TEXT,   -- JSON array, stored as text
  consequences TEXT,
  tradeoffs TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
```

`seq` is the real autoincrement primary key; libSQL serializes it atomically at the primary. The external-facing `DEC-0042`-style id is a display format (`'DEC-' || printf('%04d', seq)`) computed on read/export, never stored redundantly — this is what eliminates the read-then-increment race entirely, not just narrows it.

## MCP tool surface

One tool per real caller need, each scoped to what that caller actually does (per the scoping constraint already agreed for MCP access in `docs/OPEN-DISCUSSIONS.md`):

| Tool | Used by | Does |
|---|---|---|
| `get_backlog()` | story-converter (re-run check), feature-orchestrator, risk-classifier | Returns `backlog_meta` + all `stories` rows |
| `get_story(story_id)` | feature-orchestrator | One story's row |
| `set_backlog_meta(project, program_spec_ref, architecture_mode)` | story-converter (spec mode, first run only) | Upserts the single meta row |
| `add_story(story)` | story-converter (spec mode) | Inserts one story row; errors on duplicate `id` (a caller bug, not a race — ids are caller-chosen, not generated) |
| `append_decision(entry)` | decision-recorder | Inserts one row, returns the formatted `DEC-####` id |
| `list_decisions(story_id?, since?, limit?)` | feature-orchestrator (`decision-log-only` context loading), export script | Matching rows, ordered by `seq` |

No tool beyond what these three existing callers need today.

## Client integration changes

Each of the three existing files gets a conditional branch on `state_backend`; file-mode behavior is preserved verbatim as the `file` branch — this is additive, not a rewrite.

- **`skills/decision-recorder/SKILL.md`** — the "read file, find highest id, construct object, append line" procedure becomes: if `state_backend: turso`, call `append_decision(entry)` with the same fields (minus `id`, returned by the tool) and use the returned id.
- **`agents/story-converter.md`** — spec mode's "read `story-backlog.json` first, check existing ids" becomes `get_backlog()`; "write the whole backlog" becomes `set_backlog_meta(...)` once plus `add_story(...)` per story. Plan mode is untouched (it never touched `story-backlog.json` in file mode either).
- **`skills/feature-orchestrator/SKILL.md`** — reads of `story-backlog.json` for a story's `context_mode`/`depends_on`/`acceptance_criteria`, or of the decision log for a `decision-log-only` story, become `get_story(id)` / `list_decisions(...)` calls instead of `Read`.

## Error handling

Any MCP tool call failure (network, auth, Turso outage) surfaces as a normal tool error to the invoking skill/agent, which treats it the same way it already treats any other unrecoverable failure it can't route around — stop and surface to the human. No retry loop, no local queue, no silent fallback to file mode mid-session. `decision-recorder`'s "never skip a write when invoked" guarantee is restated for this mode as: a failed write is a hard stop, not a skip — nothing was written to be lost, but the calling skill/agent cannot proceed past that point until it's resolved.

## Export / compat / rotation

A Node script (reuses the same `@libsql/client` the MCP server uses, rather than reimplementing a libSQL client in PowerShell) regenerates the file-based view from the live Turso tables, run on-demand rather than on a schedule:

1. Connect to Turso, pull `backlog_meta` + all `stories` rows, all `decisions` rows (ordered by `seq`).
2. Regenerate `story-backlog.json` and `decision-log.jsonl` from scratch, matching `schemas/story-backlog.schema.json` and `schemas/decision-log.schema.json` exactly (`DEC-####` ids formatted from `seq`) — a full deterministic rewrite each run, not an incremental diff. Rows are immutable once written, so full regeneration is always correct and simpler than diffing.
3. Commit both files to a dedicated branch, `claude-state-export` — never an engineer's feature branch, never `main` — and push.

`scripts/rotate-decision-log.ps1` and `scripts/export-adrs.ps1` run unmodified against the exported `decision-log.jsonl` on `claude-state-export`. One behavior change worth stating plainly: since Turso retains every row indefinitely (no deletion is part of this design), rotation no longer represents real data loss from the source of truth — it becomes a readability/file-size convenience for the generated view only, not a retention decision.

## Config, credentials, repo layout

`orchestration.yaml` additions:

```yaml
state_backend: file   # file | turso

# Only read when state_backend is turso. The database URL is an identifier,
# not a secret - safe to commit. The auth token is NEVER stored here; it
# comes from the TURSO_AUTH_TOKEN environment variable, set locally by each
# engineer from their own scoped Turso token. install.ps1 never touches
# credentials, consistent with the ticket-system MCP integration constraint
# already agreed in docs/OPEN-DISCUSSIONS.md.
turso:
  database_url: libsql://<db-name>-<org>.turso.io
```

Provisioning is manual and one-time, documented rather than scripted: the tech lead creates the Turso database and runs the schema (`schema.sql`, shipped with the server) once, then generates a scoped auth token per engineer via Turso's own tooling and distributes it out of band. Each engineer sets `TURSO_AUTH_TOKEN` locally.

New top-level repo directory, alongside `skills/`, `agents/`, `schemas/`, `scripts/`:

```
mcp-servers/
  turso-state/
    package.json
    src/index.ts        # MCP server entrypoint, tool definitions
    src/schema.sql       # the three-table schema, run once at provisioning
    src/export.ts        # the export script
```

`install.ps1` always copies `mcp-servers/turso-state/` into a project's `.claude/` (mirrored via the existing `Remove-StaleEntries` mechanism, same as `skills`/`agents`/`schemas`/`scripts`), but only registers it in the project's Claude Code MCP config if `state_backend: turso` is already set at install time. Switching a project from `file` to `turso` later is a documented manual config edit, not something a re-run of `install.ps1` does retroactively.

## Testing

**MCP server (real code):** libSQL supports a local file-backed or in-memory database, so tests run the actual server and schema locally — no live Turso account needed for CI. Contract tests per tool (valid input → expected row(s); invalid input, e.g. duplicate `add_story` id → expected error, not a silent overwrite). A concurrency test directly targeting the problem this design exists to solve: fire concurrent `append_decision` calls against the same local test database, assert all returned ids are unique and strictly sequential. An export round-trip test: seed the local test database, run the export script, validate the output against the existing `schemas/story-backlog.schema.json` and `schemas/decision-log.schema.json`.

**Skill/agent changes (prompt instructions, not code):** not unit-testable the same way — validated by running `project-scoper`/`feature-orchestrator` end-to-end against a local test Turso database, not by an automated suite. Stated here explicitly so test coverage isn't assumed to be equivalent across both halves of the work.

## Rollout

Fully additive and backward-compatible — `file` remains the default, existing single-engineer projects are unaffected. Per this repo's own versioning discipline (`CLAUDE.md`), this is a **minor** version bump. Standard trailing work once built: `CHANGELOG.md` entry, `HOW-IT-WORKS.md`/`README.md` updates (user-visible new capability), and a note in `docs/OPEN-DISCUSSIONS.md` marking the "shared state under concurrent branches" ambiguity resolved for teams that opt in — while the multi-repo workspace pattern stays separately parked and unrelated.
