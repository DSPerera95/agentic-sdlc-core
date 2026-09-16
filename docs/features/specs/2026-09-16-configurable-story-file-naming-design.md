# Configurable, versioned spec/plan file naming for stories

## Context / problem

Today, every story's on-disk state lives at a fixed layout: `<stories_dir>/<story-id>-<slug>/` containing exactly `spec.md`, `plan.json`, and `ticket.json`, all literal, unconfigurable names. Each `feature-orchestrator` amendment loop overwrites `spec.md`/`plan.json` in place — there is no history of prior approved versions, and the filenames carry no information a team's own ticket-tracking conventions might expect (e.g. the ticket id, a human-readable title, a version number).

## Goals

- Drop the slug from the per-story *directory* name — it becomes `<stories_dir>/<story-id>/`, story id only.
- Move `spec.md` and `plan.json` into their own `spec/` and `plan/` subfolders under that directory.
- Make the spec/plan file basename configurable via `orchestration.yaml`, built from placeholders (`{ticket_id}`, `{slug}`) rather than a fixed literal — e.g. `{ticket_id}-{slug}` producing `MPMD-123-Project-scaffold`.
- Automatically append a version number to that configured name on every file written — `-v<N>` before the extension (`MPMD-123-Project-scaffold-v1.md`).
- Every *approved content change* to a spec or plan writes a new version (`v2`, `v3`, ...) rather than overwriting the previous one; prior versions stay on disk as history. Routine `plan` task-`status` bookkeeping during execution is not a content change and does not bump the version.

## Non-goals

- No change to `ticket.json`'s location or role — it stays flat at `<stories_dir>/<story-id>/ticket.json`, not moved into a subfolder. Only `spec.md`/`plan.json` are affected by this feature.
- No pruning or rotation of old spec/plan versions — same "no auto-regeneration/cleanup" stance already taken for architecture-mode diagrams and the decision log's own rotation being a separate, manual, opt-in script. If old versions need pruning later, that's its own feature.
- No change to `task-graph.schema.json`, `story-backlog.schema.json`, or `decision-log.schema.json` — none of them describe a file *path*, only content shape, and content shape is unaffected.
- No change to how `slug` itself is generated — same logic `story-converter` already uses today (derived from the story's title), just persisted for reuse instead of only ever appearing in a directory name.

## Design

### Directory layout

```
<stories_dir>/<story-id>/
  ticket.json
  spec/
    <name>-v1.md
    <name>-v2.md   (only if a Story amendment re-approved the spec)
  plan/
    <name>-v1.json
    <name>-v2.json (only if a Scope or Story amendment re-approved the plan)
```

where `<name>` is `story_file_name_format` from `orchestration.yaml` (see Config), rendered once per story from that story's own `ticket_id` and `slug` — the same rendered name is reused for both `spec/` and `plan/`, only the extension (`.md` vs `.json`) and version number differ between them.

### Where `ticket_id`/`slug` come from, and where they're persisted

`story-converter` (spec mode) already computes a `slug` from the story's title when it currently names the per-story directory — that computation doesn't change, only what happens to the result. `ticket.json` gains a `slug` field alongside the existing `ticket_id`:

```json
{
  "ticket_id": "MPMD-123",
  "slug": "project-scaffold",
  "sync_log": []
}
```

`slug` is written once, at creation, and never recomputed — same "compute once, persist, don't re-derive" precedent `context_mode` already set. `feature-orchestrator` reads `ticket.json` (it doesn't currently; this is a new read) whenever it needs to render `story_file_name_format` into an actual filename.

### `story-converter`'s responsibility (spec mode)

Creates `<stories_dir>/<story-id>/` (story id only, no slug — this is the one line that changes from today's `<story-id>-<slug>/`) and writes `ticket.json` there with `ticket_id` and `slug`. Does **not** create `spec/` or `plan/` — those don't exist yet at this point in the flow (spec mode runs once per project, before any story's `feature-orchestrator` run), and `feature-orchestrator` creates them itself on first write.

### `feature-orchestrator`'s responsibility

- **Step 0** (already reads `stories_dir`): also reads `ticket.json` for the current story (`ticket_id`, `slug`) and `story_file_name_format`, and renders the story's file basename once, reusing it for every spec/plan write this run.
- **Step 6** (spec approval): writes the *first* version, `<stories_dir>/<story-id>/spec/<name>-v1.md` — creating the `spec/` folder if it doesn't exist yet.
- **Step 9** (plan approval): writes the *first* version, `<stories_dir>/<story-id>/plan/<name>-v1.json` — creating the `plan/` folder if it doesn't exist yet.
- **Step 11** (execution): reads and updates task `status` fields on the **current** plan version's file, in place — this is bookkeeping, not a content amendment, and never creates a new version.
- **Scope amendment loop**: `plan-writer` patches the affected task's `files_touched`. This *is* a content amendment — write the result to a **new** version (`v2`, `v3`, ...), not in place. From this point on, step 11 reads/writes task status against the new current version.
- **Story amendment loop**: `spec-writer` amends the spec, and (if a plan already exists) `plan-writer` patches it. Both are content amendments — each writes a new version of whichever file(s) it touched.

### Resolving "the current version"

No separate pointer/index file — that would duplicate a source of truth already fully derivable from what's on disk. "Current version" is defined as: list the files in `spec/` (or `plan/`), parse each for its trailing `-v<N>` before the extension, and take the highest `N`. Any step that needs "the approved spec" or "the current plan" resolves it this way, every time — never assumed or cached across steps within a run.

### Config

New key in `orchestration.yaml`, parallel to the existing `stories_dir`/`diagrams_dir` pattern:

```yaml
# Template for the spec/plan file basename, before the automatic "-v<N>"
# version suffix and extension are appended. Available placeholders:
# {ticket_id}, {slug}. Rendered once per story and reused for both spec/
# and plan/ - only the extension (.md vs .json) and version number differ
# between them.
story_file_name_format: "{ticket_id}-{slug}"
```

## Testing

Same situation as the architecture-mode diagrams feature: prose/markdown skill files, not unit-testable code. Manual run-through:
- A fresh story's initial spec/plan approval produces `.../spec/<name>-v1.md` and `.../plan/<name>-v1.json`, folders created as needed, `ticket.json` unchanged in location and gains `slug`.
- A Scope amendment during execution produces `.../plan/<name>-v2.json`, leaves `v1.json` on disk untouched, and confirms step 11 continues updating `v2` afterward, not `v1`.
- A Story amendment produces new versions of both `spec/` and `plan/` (when a plan already existed), each independently versioned (a spec bump doesn't force a plan bump and vice versa unless both are actually amended).
- Routine task-`status` updates during execution (no amendment involved) confirm the version number does *not* change.

## Rollout

Breaking change to an established on-disk layout and to `ticket.json`'s shape — existing installs with stories already created under the old `<story-id>-<slug>/spec.md` layout are not migrated automatically (no script to move existing files into the new structure is in scope here; a project mid-flight would need to move its own in-progress story folders by hand, or finish already-started stories under the old paths and only see the new layout on stories created after upgrading). Major version bump.
