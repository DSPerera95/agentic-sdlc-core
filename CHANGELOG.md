# Changelog

## 7.6.0 — generic MCP server setup script; fixed turso-state dist packaging

**Added**
- New `scripts/setup-mcp-server.ps1`, generic across any MCP server this repo ships (parameterized by `-Name`). Fetches `mcp-servers/<Name>/dist/` from the pinned agentic-sdlc-core ref, syncs it into `.claude/mcp-servers/<Name>/`, runs `npm install` there, and registers the server in `.mcp.json` with a caller-supplied `-EnvVars` block. Reads the source repo/ref from `.claude/agentic-sdlc-core.version` if `-RepoUrl`/`-Ref` aren't passed explicitly, so it can also be run standalone later - e.g. after flipping `state_backend: turso` on post-install, without re-running `install.ps1` at all.
- `mcp-servers/turso-state/dist/` now ships a trimmed, runtime-only `package.json` (only `@libsql/client`, `@modelcontextprotocol/sdk`, `zod` - none of the package's own `devDependencies` used for building/testing it). `npm install` against this file on the consumer side pulls in only what the compiled server actually imports at runtime, same as any other Node package - `tsc` transpiles syntax, it does not bundle `node_modules` dependencies into the output, and `@libsql/client`'s native SQLite bindings can't be bundled away regardless (they're resolved per-platform at install time), so some form of `npm install` on the consumer side was never avoidable - this just scopes it to the minimum.
- New `npm run test:dist` in `mcp-servers/turso-state/` (`dist-smoke-test.mjs`) - runs `applySchema()` against the *compiled* `dist/` output, not `src/` via `tsx` like the rest of the suite. Exists specifically to catch build-packaging bugs the regular unit tests structurally can't see.

**Fixed**
- `dist/schema.sql` was never produced by `npm run build` - `tsc` only compiles `.ts` files, it doesn't copy other assets into `outDir`. `db.ts`'s `applySchema()` resolves the schema path relative to its own compiled location, so this broke at runtime with `ENOENT` the moment the server ran from `dist/` instead of via `tsx` against `src/` - which every test in the existing suite does, so nothing caught it before now. Fixed with a small `copy-dist-assets.mjs` step appended to `build`, and `mcp-servers/turso-state/dist/` is now committed to this repo instead of gitignored, so a prebuilt, working `dist/` is what actually ships.
- `install.ps1` previously copied all of `mcp-servers/` (source, tests, `tsconfig.json`, full dev `package.json`) into every project unconditionally, regardless of whether that project used any of it - and never ran `npm install` or a build step against it, so even a project that opted into `state_backend: turso` ended up with a `.mcp.json` entry pointing at a `dist/index.js` that didn't exist and dependencies that were never installed. `install.ps1` no longer touches `mcp-servers/`, `orchestration.yaml`'s `state_backend`, or `.mcp.json` at all - installing the orchestrator and setting up an MCP server are two separate, deliberate actions now. Run `.claude/scripts/setup-mcp-server.ps1 -Name turso-state` yourself once `state_backend: turso` is set, whether that's during initial setup or added later - one path either way, instead of an automatic one during install and a manual one for everything after.

**Why**: found while double-checking the "ship a prebuilt `dist/`" decision from the `turso-state` work in 7.5.0 - actually running the compiled output surfaced that it never worked end-to-end (missing `schema.sql`, and no install step ever wired up on the consumer side). Fixing that for `turso-state` specifically also exposed that the copy-and-register logic living inline in `install.ps1` had no way to be reused for any MCP server this repo adds later without duplicating the same ~50 lines again - pulled it out into its own script now, while the fix was already in motion, rather than duplicating it a second time on the next MCP server and only then noticing the pattern. `install.ps1` auto-detecting `state_backend: turso` and silently invoking another script was also more implicit than this repo's taste generally allows for ("explicit beats inferred") - keeping install and MCP setup as two things you deliberately run removes that, and matches the already-documented path for turning `state_backend` on after the fact instead of having two different mechanisms for the same outcome.

## 7.5.0 — opt-in Turso-backed state store for story-backlog and decision-log

**Added**
- New `state_backend` setting in `orchestration.yaml` (`file` | `turso`, defaults to `file`). When set to `turso`, `story-backlog.json` and `decision-log.jsonl` reads/writes route through a new local MCP server (`.claude/mcp-servers/turso-state/`, Node/TypeScript) backed by a hosted Turso (libSQL) database, instead of plain files - opt into this once multiple engineers are running `feature-orchestrator` concurrently on separate branches against the same backlog/decision log. Everything under `stories_dir` (`spec.md`, `plan.json`, `ticket.json`) is unaffected either way - those files were never the source of the concurrency problem this solves.
- The `turso` mode's `append_decision` MCP tool assigns each decision's sequential id atomically at the database (SQLite/libSQL `AUTOINCREMENT`), which directly removes a real race condition in `decision-recorder`'s file-mode id assignment (`read the file, find the highest DEC-####, use the next number`) that existed under concurrent writers before this change.
- `decision-recorder`, `story-converter` (spec mode), and `feature-orchestrator` (step 0 and the context escalation section) now branch on `state_backend` - `file` mode is byte-for-byte the same behavior as before this release; `turso` mode calls the new MCP tools instead of reading/writing files directly.
- New `mcp-servers/turso-state/export.ts` script regenerates `story-backlog.json`/`decision-log.jsonl` from the live Turso tables onto a dedicated `claude-state-export` git branch, on demand - keeps `scripts/rotate-decision-log.ps1` and `scripts/export-adrs.ps1` working completely unmodified against a `turso`-backed project. Rotation in this mode is now purely a file-readability convenience, not a retention operation - Turso retains every row indefinitely.
- `install.ps1` now always installs `mcp-servers/turso-state/` (mirrored via the existing `Remove-StaleEntries` mechanism, same as `skills`/`agents`/`schemas`/`scripts`), and additionally registers it in the project's `.mcp.json` when `state_backend: turso` is already set at install time. `install.ps1` never writes or generates Turso credentials - `TURSO_AUTH_TOKEN` is set locally by each engineer from a scoped token, per the same constraint already agreed for the ticket-system MCP integration.

**Why**: real design discussion (see `docs/features/specs/2026-09-11-turso-state-backend-design.md`) about a genuine target environment for this tool - a monorepo with several engineers, each running `feature-orchestrator` on their own feature branch off a backlog a tech lead produced once. `story-backlog.json` and `decision-log.jsonl` living inside whatever branch a session happens to be on doesn't hold up under that concurrency: `decision-log`'s id assignment has a real read-then-increment race today, and `story-backlog.json` (write-once, no status field - the ticket system is the system of record for anything that changes after creation) gives every engineer's branch a possibly-stale local copy. Considered a custom-hosted REST API and a git-native dedicated-branch-only approach first; rejected both - the former means operating your own database and auth from scratch, the latter still doesn't remove the id-race condition, since "highest id in the file" is read-then-increment even on a branch nobody's feature work touches. A hosted libSQL database gives atomic sequential ids and real transactional writes for free, and a local/stdio MCP server means no one has to host anything beyond the database itself. Kept strictly opt-in, matching this repo's "narrow default, cheap escalation" pattern already used for `context_mode` and `depends_on` - a solo engineer or small team never has to know this exists.

## 7.4.0 — install.ps1 creates .claude/analytics/ up front

**Added**
- `install.ps1` now creates `.claude/analytics/` during install (idempotent - safe to re-run, no error if it already exists) instead of leaving it to be created lazily the first time `token-usage-report.ps1 -Html` runs. The `.gitignore` entry from 5.5.0 already assumed this folder would exist; now the installer actually brings it into existence up front rather than only wiring the ignore rule for a folder that might not be there yet.

## 7.3.0 — install.ps1 additively merges orchestration.yaml

**Added**
- `install.ps1` now compares an already-installed project's `config/orchestration.yaml` against the version being installed and appends any top-level properties present in the new version but missing from the project's file - each with its original comment intact, and every existing property left completely untouched, even if its value differs from the new template's default. Previously, once a project had its own `orchestration.yaml`, it was skipped entirely on every future install - meaning new fields (`stories_dir` in 7.2.0, `risk_thresholds` before it) would never reach an existing installation without a manual copy-paste.
- Deliberately line-based rather than a real YAML parse-and-reserialize: round-tripping through a generic YAML parser would strip the inline comments that make this file usable. Only whole top-level properties are detected as missing - a future property nested inside an existing one (e.g. a new field added under `risk_thresholds` itself) won't be caught by this and would need the same treatment revisited.
- `-Force` does not affect this file. A full overwrite would defeat the purpose - it stays additive-only regardless.

**Fixed**
- Found and fixed while testing this against a real merge: PowerShell 5.1's `Get-Content -Encoding UTF8` doesn't reliably honor that flag for a BOM-less UTF8 file - the same class of encoding gotcha this repo's own `CLAUDE.md` already documents, just hitting a different cmdlet than the ones already fixed for it. Switched to `[System.IO.File]::ReadAllLines`/`WriteAllLines` with an explicit encoding object instead, which doesn't have this quirk. Caught by literally testing against a real customized config containing an em-dash, not assumed safe.

**Why**: this repo's own `orchestration.yaml` picked up two new top-level properties in the last two versions alone (`risk_thresholds`, `stories_dir`) - "never overwrite an existing project's config" was the right instinct for protecting customization, but it had the side effect of also silently freezing a project out of every future config addition. An additive-only merge gets both: existing values stay exactly as a project set them, and new capability still reaches an existing install without a manual step.

## 7.2.0 — context_mode_default wired up; stories_dir made configurable

**Added**
- `project-scoper` now explicitly reads `context_mode_default` from `config/orchestration.yaml` and passes it to `story-converter` alongside `architecture_mode`, instead of `story-converter.md` just asserting "default to the project's configured default" with no instruction anywhere on how that value actually reaches it.
- New `stories_dir` field in `orchestration.yaml`, independently configurable rather than assumed to live under `state_dir` - defaults to `.claude/state/stories`, matching the existing layout, but a project can point it anywhere.
- `feature-orchestrator` now explicitly writes `spec.md` and `plan.json` to `<stories_dir>/<story-id>-<slug>/` after each approval gate (steps 6 and 9), reads `plan.json` back and updates task `status` as execution progresses (step 11), and rewrites it on every Scope/Story amendment - none of this was previously stated anywhere, not even against the old hardcoded path.
- `story-converter` now explicitly creates each story's directory and writes `ticket.json` there in spec mode, and appends to its sync log there in plan mode - both were previously undocumented in `story-converter.md` itself, only implied by `project-template/.claude/state/stories/README.md`'s passive description of the convention.

**Why**: same audit habit as `risk_thresholds` in 7.1.0, applied to two more places. `context_mode_default` turned out to be a milder version of the same gap - referenced conceptually in `project-scoper`/`story-converter`, but never with an explicit "read this, pass it" instruction, unlike `architecture_mode` one sentence away in the same paragraph, which already had one. `stories_dir` surfaced a deeper issue while making it configurable: nothing in `feature-orchestrator`, `spec-writer`, `implementation-planner`, or `story-converter` ever explicitly wrote `spec.md`, `plan.json`, or `ticket.json` to disk at all - the entire per-story file layout existed only as passive documentation in `stories/README.md`, never as an instruction any skill or agent actually followed. Making the path configurable without fixing that would have just added a config value nothing reads, the exact failure mode this repo has now caught three times (`risk-classifier`'s own output in 1.0.0, `risk_thresholds` in 7.1.0, and this).

## 7.1.0 — risk_thresholds actually wired into risk-classifier

**Added**
- `feature-orchestrator` step 2 now passes `orchestration.yaml`'s `risk_thresholds` (`l1_max_files`, `l1_excludes`) to the `risk-classifier` agent as explicit input on every call - it has no access to project config itself, so this was always going to have to be passed, not read.
- `risk-classifier` treats the two fields differently rather than as a single kind of constraint: `l1_excludes` is an absolute floor (any listed area rules out L1, full stop, regardless of file count or apparent simplicity); `l1_max_files` is a strong signal, not a mechanical gate - exceeding it should usually rule out L1, but the agent can still return L1 if it explicitly justifies why in `reasons`. Config comments in `project-template/.claude/config/orchestration.yaml` updated to state this distinction plainly rather than reading as a single flat rule.

**Why**: `risk_thresholds` had existed in `orchestration.yaml` since early in this project's history, with an inline comment describing intent ("above this, risk-classifier should not return L1"), but nothing ever actually read or passed it - `risk-classifier.md`'s L1/L2/L3 criteria were purely categorical, with no file-count threshold or project-specific excludes wired in anywhere. Same failure mode this repo has already shipped once before (`risk-classifier`'s own output not being branched on, in the original 1.0.0-era history) - computed-or-configured-but-unused data, caught the same way: by actually checking whether something documented as working was actually connected to anything. Considered making `l1_max_files` a hard mechanical gate applied by `feature-orchestrator` before classification even happens, matching `l1_excludes`'s strictness - rejected, since a rigid file-count ceiling risks becoming exactly the "broad default that blocks" this repo already avoids elsewhere (`context_mode`, `depends_on`): a trivial multi-file rename shouldn't lose the fast path just because it crossed an arbitrary count. `l1_excludes` earns the stricter treatment specifically because it's the one thing a shared core structurally can't provide on its own - a project's own sensitive domains beyond whatever's generically hardcoded as L3.

## 7.0.0 — install.ps1 removes stale skills/agents/schemas/scripts on re-sync

**Breaking**
- `install.ps1` now removes anything in `.claude/skills`, `.claude/agents`, `.claude/schemas`, or `.claude/scripts` that doesn't exist in the source repo at the ref being installed - not just overwrite-by-name, but a full mirror. Each removal is reported individually (`Removing stale skill no longer in the core: <name>`) as it happens, never silent. Previously the installer only ever added or overwrote; anything left behind from an older version, or hand-added by a project into one of these four folders, would linger forever across re-installs. It no longer does - it will now be deleted on the next re-run. Documented plainly in `install.ps1`'s own header: don't hand-add files inside these four folders, they're fully core-owned.

**Why**: the `bug-fixer` migration in 6.0.0 made this a concrete problem, not a hypothetical one - a project that installed an older version (with `skills/bug-fixer/`) and re-runs `install.ps1` to pick up 6.0.0 would end up with *both* the stale `skills/bug-fixer/` and the new `agents/bug-fixer.md`, silently, forever, since nothing ever cleaned up the old one. This will keep happening every time something moves or gets removed unless the installer actually mirrors the source instead of only ever adding to the destination. Verified against a simulated upgrade (an old install with a stale `skills/bug-fixer/` alongside a still-valid `skills/grill-me/`, re-synced against the current core): the stale entry was detected, reported, and removed; the valid one was left untouched.

## 6.0.0 — bug-fixer moved to agents/

**Breaking**
- `bug-fixer` moved from `skills/bug-fixer/` to `agents/bug-fixer.md`. It now always runs isolated, on Sonnet 5, with effort passed explicitly by the caller (matching validator's pattern: low for L1, medium for L2, medium as the bug-fix-only workflow's fixed default, high for L3). Projects on 5.x need to run `install.ps1` again after upgrading; `skills/bug-fixer/` is gone, and anything referencing the old `/bug-fixer` skill path needs to delegate to the agent instead.
- `feature-orchestrator` and `build-feature` updated at every call site: `invoke /bug-fixer` became `delegate to the bug-fixer agent`, each now passing an explicit effort level the same way they already do for `validator`.

**Why**: `bug-fixer` had sat in `docs/OPEN-DISCUSSIONS.md`'s "unrevisited" bucket alongside `spec-writer`/`implementation-planner` since the original 3.0.0 migration — structurally similar to `validator`/`implementer`, but never actually checked. Unlike leaving `spec-writer`/`implementation-planner` untouched (still genuinely unsure either way), this one got audited first: every call site was checked for whether it actually relies on shared session context that isolation would lose, following the same litmus test that put `validator`/`implementer` in `agents/` and kept `decision-recorder` out. `bug-fixer`'s own instructions turned out to have zero session-context assumptions built in - already reading like an agent definition in all but location. One real gap was found and fixed in 5.6.1 first: `build-feature`'s call site wasn't explicitly passing `validator`'s findings, relying on `bug-fixer` seeing them inline instead - exactly the kind of dependency that would have silently regressed on migration day if it had gone unnoticed. As a skill, `bug-fixer` also inherited whatever model the calling session happened to be on rather than a guaranteed tier - the same gap `implementer` had before 4.0.0.

## 5.6.1 — bug-fixer now explicitly consumes validator's findings

**Fixed**
- `skills/build-feature/SKILL.md` (Phase 3) — the L1 fast path's `/bug-fixer` invocation now explicitly passes the validator agent's structured findings as input, matching the wording `feature-orchestrator`'s main workflow (step 13) already used. It previously just said "invoke /bug-fixer" with nothing passed, relying on `bug-fixer` being able to see `validator`'s just-produced output in the same inline session - implicit context, not explicit input.
- `skills/bug-fixer/SKILL.md` - now explicitly branches on whether it was handed findings already: if so, start from them (skip straight to designing the fix); only run the full reproduce/root-cause sequence from scratch when nothing was attached (e.g. the bug-fix-only workflow, which has no prior validator pass to draw on). Previously the file never acknowledged receiving prior input at all, regardless of caller.

**Why**: prep work for evaluating whether `bug-fixer` could move to `agents/` (see `docs/OPEN-DISCUSSIONS.md` - flagged as unrevisited, not decided either way). Auditing all three call sites found `bug-fixer`'s own file has no session-context assumptions baked in - a good sign - but one call site (`build-feature`) was quietly depending on inline visibility into `validator`'s output rather than explicit input, which an isolated agent call would silently lose, causing `bug-fixer` to re-diagnose from scratch instead of using what `validator` already found. Fixing this now, independent of whether the actual skill-to-agent migration happens, since it's a real gap either way - an isolated agent call just would have made it fail loudly instead of quietly.

## 5.6.0 — story-backlog.json

**Added**
- `story-converter` (spec mode) now writes the whole backlog to `.claude/state/story-backlog.json`, matching `story-backlog.schema.json` exactly - a single JSON object (`project`/`program_spec_ref`/`architecture_mode`/`stories`), not JSON Lines. It's written once per project (or once per re-run against an already-scoped project) and never appended to incrementally, so there's no per-line benefit the way there is for `decision-log.jsonl` - one whole-document write is the right shape, and it now has the extension to match. A re-run reads the existing file first, so it never reassigns an in-use story id or recreates a ticket that already exists.
- Documented as a point-in-time snapshot, explicitly: plan mode's ticket syncs (scope amendment, story amendment, completion) never rewrite this file, only the ticket system reflects what changed after spec-mode creation. Named plainly in `story-converter.md` and `project-template/.claude/state/README.md` to head off exactly the drift risk a second, quietly-stale source of truth would create.

**Why**: an actual project running this workflow was already writing this file locally - just named `story-backlog.jsonl` despite the content being a single pretty-printed JSON object, not line-delimited. Formalizing it into the core means fixing the name to match the content (`.json`, not `.jsonl`) and giving `risk-classifier`, `feature-orchestrator`, and a later `project-scoper` re-run a documented, schema-validated local read path instead of an undocumented, ad hoc one. Considered JSON Lines for consistency with `decision-log.jsonl`, and markdown for consistency with human-facing docs - rejected both: the backlog is written once, not appended to, so JSONL's per-line append/rotation benefit doesn't apply; and every field here (`context_mode`'s enum, `depends_on`'s cross-references, `ticket_id`'s lookup into the tracker, `acceptance_criteria` as a list) is read programmatically by name across multiple consumers, which is exactly the class of problem that already pushed `decision-log` off markdown in 5.3.0 - only more so here, since nothing about this data is meant to be read as prose.

## 5.5.0 — Token usage report

**Added**
- `scripts/token-usage-report.ps1` — reads the Claude Code session transcript for this project (`<home>\.claude\projects\<slug>\<session-id>.jsonl`) and renders a terminal bar chart of token usage per agent and per skill. On-demand, not a hook: the transcript is written incrementally while a session is open, so this can be run from a second terminal against a session that's still running, not only after it ends. Agent-level totals are exact - each agent invocation completes with a `task-notification` carrying a pre-aggregated `subagent_tokens` figure, linked back to the invoking `subagent_type` via the originating tool call's id. Skill-level totals are a best-effort heuristic, labelled as such in the output - skills run inline with no isolation boundary, so a `Skill` tool call only marks where attribution starts, not where it ends; usage before any skill call, or between it and the next one, prints as `orchestrator (unattributed)` rather than being silently dropped.
- `-Html` switch on the same script — writes a self-contained HTML report alongside the terminal chart: colored stacked bar charts (Input Tokens / Output Tokens / Cache Read Input Tokens / Cache Creation Input Tokens as four legend-backed series, using the `dataviz` skill's validated categorical palette, checked with its colorblindness/contrast validator before use), a light/dark theme toggle, hover/keyboard tooltips, and a table-view toggle as the accessibility twin of the charts. Defaults to writing `<ProjectDir>\.claude\analytics\token-usage-report-<session-id>-<timestamp>.html`, creating the folder if needed; `-HtmlPath` overrides it. No external assets or build step - one file, inline CSS/JS.
- `install.ps1` — adds `.claude/analytics/` to the installing repo's `.gitignore`, but only if that repo already has a `.gitignore` and doesn't already cover the path; never creates one. Idempotent on re-run.

**Why**: this resolves the "token usage visibility per skill/agent" slice of the Cost telemetry item in `docs/OPEN-DISCUSSIONS.md` - dollar-cost conversion, a budget/circuit-breaker, and validating the existing model-tier-routing assumptions all remain open, unbuilt. A `Stop` hook parsing the transcript after the fact was the only mechanism previously discussed there; reading the transcript on demand instead covers the same ground and also works mid-session, which a `Stop` hook structurally cannot. Several things surfaced only by actually running this against real transcripts, not knowable in advance: PowerShell 5.1's `ConvertFrom-Json` has no `-Depth` parameter (added in PS 6+); a single assistant turn logs one JSONL line per content block (thinking/text/tool_use), each repeating that turn's full cumulative `usage` object, so summing every line rather than deduping by `requestId` overcounts by 2-4x; and the same Claude Code build was observed delivering a `task-notification` in two different shapes within one session - an `attachment` entry (also used, confusingly, for unrelated background *shell command* completions with no `subagent_tokens`) and a plain-string `user` message - so the script checks both and keeps only the latest `subagent_tokens` value per invocation rather than summing repeats, since a task-id can notify more than once with a running total each time. Caught by running an early version against a real multi-agent session and noticing `implementer` - which had unambiguously run - was entirely missing from the report; a version that hadn't been checked against a session with real agent activity would have shipped silently wrong. The `.claude\projects\<slug>` folder-naming scheme itself is reverse-engineered from observed behavior, not documented Claude Code behavior, and is named as a fragile dependency in the script's own header rather than assumed stable. The HTML mode exists because a terminal chart isn't shareable with a non-technical audience; `.claude/analytics/` is timestamped, disposable, regenerate-anytime output, not a source of truth, so `install.ps1` offers it a `.gitignore` line automatically where one already fits - but stops short of creating a `.gitignore` a project never chose to have, the same restraint `install.ps1` already applies everywhere else (never wiring a mechanism, like an MCP server or a ticket-system credential, that a project hasn't opted into).

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
