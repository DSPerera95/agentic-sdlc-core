# Turso State Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in `state_backend: turso` mode that routes `story-backlog.json`/`decision-log.jsonl` reads and writes through a local MCP server backed by a hosted Turso (libSQL) database, eliminating the decision-log id-race condition and branch-local staleness that affect multi-engineer, single-repo teams — while leaving the existing file-based default completely unmodified.

**Architecture:** A new `mcp-servers/turso-state/` Node/TypeScript package exposes six MCP tools (`get_backlog`, `get_story`, `set_backlog_meta`, `add_story`, `append_decision`, `list_decisions`) backed by three libSQL tables. `decision-recorder`, `story-converter`, and `feature-orchestrator` each get a conditional branch on `state_backend` in their existing instructions — file mode unchanged, turso mode calls the MCP tools instead of reading/writing files directly. An export script regenerates the file-based view from Turso on a dedicated `claude-state-export` branch so `rotate-decision-log.ps1`/`export-adrs.ps1` keep working unmodified.

**Tech Stack:** Node.js (>=20) + TypeScript, `@modelcontextprotocol/sdk`, `@libsql/client`, `zod`, Node's built-in `node:test` runner, `ajv` for schema validation in tests. PowerShell for `install.ps1` changes only.

**Reference spec:** `docs/features/specs/2026-09-11-turso-state-backend-design.md`

## Global Constraints

- `state_backend` defaults to `file`; `turso` mode is strictly opt-in and additive — no change in behavior for a project that never sets it.
- Direct remote connection to Turso only — no embedded/local-replica mode in this plan (explicitly deferred per the spec).
- Any MCP tool call failure (network, auth, outage) is a hard failure surfaced to the caller — no retry loop, no local queue, no silent fallback to file mode.
- `install.ps1` never writes, generates, or touches Turso credentials. `TURSO_AUTH_TOKEN` comes only from the environment, set manually per engineer, never committed.
- The MCP server and export script are Node/TypeScript — not PowerShell — to reuse one `@libsql/client` implementation instead of two.
- `scripts/rotate-decision-log.ps1` and `scripts/export-adrs.ps1` must keep working completely unmodified against the exported files.
- `install.ps1`, `rotate-decision-log.ps1`, and `export-adrs.ps1` stay plain ASCII, no exceptions — a repo-wide rule from `CLAUDE.md`; all PowerShell edits in this plan honor it.
- Story ids are caller-chosen (as today); only the decision log's `seq`/`DEC-####` id is database-generated.
- This ships as a **minor** version bump (`7.4.0` -> `7.5.0`) per this repo's own versioning discipline — additive, backward-compatible, no existing behavior changes.

---

### Task 1: MCP server scaffold, schema, and DB helper

**Files:**
- Create: `mcp-servers/turso-state/package.json`
- Create: `mcp-servers/turso-state/tsconfig.json`
- Create: `mcp-servers/turso-state/src/schema.sql`
- Create: `mcp-servers/turso-state/src/db.ts`
- Create: `mcp-servers/turso-state/src/test-helpers.ts`
- Test: `mcp-servers/turso-state/src/db.test.ts`

**Interfaces:**
- Produces: `createDbClient(url: string, authToken?: string): Client` (db.ts)
- Produces: `applySchema(client: Client): Promise<void>` (db.ts)
- Produces: `createTestDb(): Promise<{ client: Client; path: string }>` (test-helpers.ts) — used by every later task's tests

- [ ] **Step 1: Create the package scaffold**

`mcp-servers/turso-state/package.json`:

```json
{
  "name": "turso-state-mcp-server",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "main": "dist/index.js",
  "engines": {
    "node": ">=20"
  },
  "scripts": {
    "build": "tsc",
    "test": "node --import tsx --test src/db.test.ts src/tools.test.ts src/server.test.ts src/export.test.ts",
    "start": "node dist/index.js",
    "export": "node --import tsx src/export.ts"
  },
  "dependencies": {
    "@modelcontextprotocol/sdk": "^1.5.0",
    "@libsql/client": "^0.14.0",
    "zod": "^3.23.8"
  },
  "devDependencies": {
    "typescript": "^5.5.4",
    "tsx": "^4.16.2",
    "@types/node": "^20.14.10",
    "ajv": "^8.17.1"
  }
}
```

`mcp-servers/turso-state/tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "outDir": "dist",
    "rootDir": "src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "declaration": false
  },
  "include": ["src/**/*.ts"],
  "exclude": ["src/**/*.test.ts"]
}
```

Run: `cd mcp-servers/turso-state && npm install`
Expected: installs without error, creates `package-lock.json` and `node_modules/`.

- [ ] **Step 2: Write the failing test for schema application**

`mcp-servers/turso-state/src/db.test.ts`:

```ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { createTestDb } from "./test-helpers.js";

test("applySchema creates the three expected tables", async () => {
  const { client } = await createTestDb();
  const result = await client.execute(
    "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
  );
  const tableNames = result.rows.map((r) => String(r.name));
  assert.deepEqual(tableNames, ["backlog_meta", "decisions", "stories"]);
});
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd mcp-servers/turso-state && npm test`
Expected: FAIL — `./test-helpers.js` does not exist yet.

- [ ] **Step 4: Write the schema and DB helper implementation**

`mcp-servers/turso-state/src/schema.sql`:

```sql
CREATE TABLE backlog_meta (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  project TEXT NOT NULL,
  program_spec_ref TEXT,
  architecture_mode INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE stories (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  ticket_id TEXT NOT NULL,
  acceptance_criteria TEXT NOT NULL,
  context_mode TEXT NOT NULL,
  depends_on TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE decisions (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  date TEXT NOT NULL,
  story_id TEXT NOT NULL,
  significance TEXT NOT NULL DEFAULT 'routine',
  context TEXT,
  decision TEXT NOT NULL,
  reasoning TEXT,
  alternatives_considered TEXT,
  consequences TEXT,
  tradeoffs TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
```

`mcp-servers/turso-state/src/db.ts`:

```ts
import { createClient, type Client } from "@libsql/client";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

export function createDbClient(url: string, authToken?: string): Client {
  return createClient({ url, authToken });
}

export async function applySchema(client: Client): Promise<void> {
  const schemaPath = join(__dirname, "schema.sql");
  const sql = readFileSync(schemaPath, "utf-8");
  const statements = sql
    .split(";")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
  for (const statement of statements) {
    await client.execute(statement);
  }
}
```

`mcp-servers/turso-state/src/test-helpers.ts`:

```ts
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Client } from "@libsql/client";
import { createDbClient, applySchema } from "./db.js";

export async function createTestDb(): Promise<{ client: Client; path: string }> {
  const dir = mkdtempSync(join(tmpdir(), "turso-state-test-"));
  const path = join(dir, "test.db");
  const client = createDbClient(`file:${path}`);
  await applySchema(client);
  return { client, path };
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd mcp-servers/turso-state && npm test`
Expected: PASS — 1 test passed.

- [ ] **Step 6: Commit**

```bash
git add mcp-servers/turso-state/package.json mcp-servers/turso-state/tsconfig.json \
  mcp-servers/turso-state/src/schema.sql mcp-servers/turso-state/src/db.ts \
  mcp-servers/turso-state/src/test-helpers.ts mcp-servers/turso-state/src/db.test.ts \
  mcp-servers/turso-state/package-lock.json
git commit -m "feat(turso-state): add MCP server scaffold, schema, and DB test helper"
```

---

### Task 2: Story/backlog read and write tools

**Files:**
- Create: `mcp-servers/turso-state/src/tools.ts`
- Test: `mcp-servers/turso-state/src/tools.test.ts`

**Interfaces:**
- Consumes: `createTestDb()` from Task 1
- Produces: types `Story`, `BacklogMeta`, `Backlog` (tools.ts)
- Produces: `getBacklog(client: Client): Promise<Backlog>` (tools.ts)
- Produces: `getStory(client: Client, storyId: string): Promise<Story | null>` (tools.ts)
- Produces: `setBacklogMeta(client: Client, meta: BacklogMeta): Promise<void>` (tools.ts)
- Produces: `addStory(client: Client, story: Story): Promise<void>` (tools.ts)
- Produces: `class DuplicateStoryIdError extends Error` (tools.ts)

- [ ] **Step 1: Write the failing tests**

`mcp-servers/turso-state/src/tools.test.ts`:

```ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { createTestDb } from "./test-helpers.js";
import {
  getBacklog,
  getStory,
  setBacklogMeta,
  addStory,
  DuplicateStoryIdError,
} from "./tools.js";

test("getBacklog returns null meta and empty stories on a fresh database", async () => {
  const { client } = await createTestDb();
  const backlog = await getBacklog(client);
  assert.equal(backlog.meta, null);
  assert.deepEqual(backlog.stories, []);
});

test("setBacklogMeta then getBacklog round-trips the meta row", async () => {
  const { client } = await createTestDb();
  await setBacklogMeta(client, {
    project: "Insurance Comparison",
    program_spec_ref: "docs/spec.md",
    architecture_mode: true,
  });
  const backlog = await getBacklog(client);
  assert.deepEqual(backlog.meta, {
    project: "Insurance Comparison",
    program_spec_ref: "docs/spec.md",
    architecture_mode: true,
  });
});

test("setBacklogMeta called twice upserts rather than erroring", async () => {
  const { client } = await createTestDb();
  await setBacklogMeta(client, { project: "First", architecture_mode: false });
  await setBacklogMeta(client, { project: "Second", architecture_mode: true });
  const backlog = await getBacklog(client);
  assert.equal(backlog.meta?.project, "Second");
});

test("addStory then getStory round-trips a story, including JSON array fields", async () => {
  const { client } = await createTestDb();
  await addStory(client, {
    id: "STORY-001",
    title: "Comparison API",
    ticket_id: "JIRA-101",
    acceptance_criteria: ["returns quotes for two carriers", "handles missing carrier gracefully"],
    context_mode: "decision-log-only",
    depends_on: ["STORY-000"],
  });
  const story = await getStory(client, "STORY-001");
  assert.deepEqual(story, {
    id: "STORY-001",
    title: "Comparison API",
    ticket_id: "JIRA-101",
    acceptance_criteria: ["returns quotes for two carriers", "handles missing carrier gracefully"],
    context_mode: "decision-log-only",
    depends_on: ["STORY-000"],
  });
});

test("getStory returns null for an unknown id", async () => {
  const { client } = await createTestDb();
  const story = await getStory(client, "STORY-999");
  assert.equal(story, null);
});

test("addStory rejects a duplicate id", async () => {
  const { client } = await createTestDb();
  await addStory(client, {
    id: "STORY-001",
    title: "First",
    ticket_id: "JIRA-1",
    acceptance_criteria: ["a"],
    context_mode: "independent",
  });
  await assert.rejects(
    () =>
      addStory(client, {
        id: "STORY-001",
        title: "Duplicate",
        ticket_id: "JIRA-2",
        acceptance_criteria: ["b"],
        context_mode: "independent",
      }),
    DuplicateStoryIdError
  );
});

test("getBacklog returns multiple stories ordered by id", async () => {
  const { client } = await createTestDb();
  await addStory(client, {
    id: "STORY-002",
    title: "Second",
    ticket_id: "JIRA-2",
    acceptance_criteria: ["b"],
    context_mode: "independent",
  });
  await addStory(client, {
    id: "STORY-001",
    title: "First",
    ticket_id: "JIRA-1",
    acceptance_criteria: ["a"],
    context_mode: "independent",
  });
  const backlog = await getBacklog(client);
  assert.deepEqual(
    backlog.stories.map((s) => s.id),
    ["STORY-001", "STORY-002"]
  );
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mcp-servers/turso-state && npm test`
Expected: FAIL — `./tools.js` does not exist yet.

- [ ] **Step 3: Write the implementation**

`mcp-servers/turso-state/src/tools.ts`:

```ts
import type { Client } from "@libsql/client";

export interface Story {
  id: string;
  title: string;
  ticket_id: string;
  acceptance_criteria: string[];
  context_mode: "full-spec" | "decision-log-only" | "independent";
  depends_on?: string[];
}

export interface BacklogMeta {
  project: string;
  program_spec_ref?: string;
  architecture_mode: boolean;
}

export interface Backlog {
  meta: BacklogMeta | null;
  stories: Story[];
}

export class DuplicateStoryIdError extends Error {
  constructor(id: string) {
    super(`Story id already exists: ${id}`);
    this.name = "DuplicateStoryIdError";
  }
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function rowToStory(row: any): Story {
  return {
    id: String(row.id),
    title: String(row.title),
    ticket_id: String(row.ticket_id),
    acceptance_criteria: JSON.parse(String(row.acceptance_criteria)),
    context_mode: String(row.context_mode) as Story["context_mode"],
    depends_on: row.depends_on ? JSON.parse(String(row.depends_on)) : undefined,
  };
}

export async function getBacklog(client: Client): Promise<Backlog> {
  const metaResult = await client.execute(
    "SELECT project, program_spec_ref, architecture_mode FROM backlog_meta WHERE id = 1"
  );
  const storiesResult = await client.execute(
    "SELECT id, title, ticket_id, acceptance_criteria, context_mode, depends_on FROM stories ORDER BY id"
  );

  const metaRow = metaResult.rows[0];
  const meta: BacklogMeta | null = metaRow
    ? {
        project: String(metaRow.project),
        program_spec_ref: metaRow.program_spec_ref ? String(metaRow.program_spec_ref) : undefined,
        architecture_mode: Boolean(metaRow.architecture_mode),
      }
    : null;

  return { meta, stories: storiesResult.rows.map(rowToStory) };
}

export async function getStory(client: Client, storyId: string): Promise<Story | null> {
  const result = await client.execute({
    sql: "SELECT id, title, ticket_id, acceptance_criteria, context_mode, depends_on FROM stories WHERE id = ?",
    args: [storyId],
  });
  if (result.rows.length === 0) return null;
  return rowToStory(result.rows[0]);
}

export async function setBacklogMeta(client: Client, meta: BacklogMeta): Promise<void> {
  await client.execute({
    sql: `INSERT INTO backlog_meta (id, project, program_spec_ref, architecture_mode)
          VALUES (1, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET project = excluded.project,
            program_spec_ref = excluded.program_spec_ref,
            architecture_mode = excluded.architecture_mode`,
    args: [meta.project, meta.program_spec_ref ?? null, meta.architecture_mode ? 1 : 0],
  });
}

export async function addStory(client: Client, story: Story): Promise<void> {
  const existing = await getStory(client, story.id);
  if (existing) {
    throw new DuplicateStoryIdError(story.id);
  }
  await client.execute({
    sql: `INSERT INTO stories (id, title, ticket_id, acceptance_criteria, context_mode, depends_on)
          VALUES (?, ?, ?, ?, ?, ?)`,
    args: [
      story.id,
      story.title,
      story.ticket_id,
      JSON.stringify(story.acceptance_criteria),
      story.context_mode,
      story.depends_on ? JSON.stringify(story.depends_on) : null,
    ],
  });
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd mcp-servers/turso-state && npm test`
Expected: PASS — 7 tests passed.

- [ ] **Step 5: Commit**

```bash
git add mcp-servers/turso-state/src/tools.ts mcp-servers/turso-state/src/tools.test.ts
git commit -m "feat(turso-state): add backlog/story read and write tool functions"
```

---

### Task 3: `append_decision` — the concurrency-critical write path

**Files:**
- Modify: `mcp-servers/turso-state/src/tools.ts`
- Modify: `mcp-servers/turso-state/src/tools.test.ts`

**Interfaces:**
- Consumes: `Client` (from `@libsql/client`), `createTestDb()` from Task 1
- Produces: types `DecisionInput`, `Decision` (tools.ts)
- Produces: `appendDecision(client: Client, input: DecisionInput): Promise<Decision>` (tools.ts)

- [ ] **Step 1: Write the failing tests**

Append to `mcp-servers/turso-state/src/tools.test.ts`:

```ts
import { appendDecision } from "./tools.js";

test("appendDecision assigns DEC-0001 to the first entry and defaults significance to routine", async () => {
  const { client } = await createTestDb();
  const decision = await appendDecision(client, {
    date: "2026-09-11",
    story_id: "STORY-001",
    decision: "Use Turso for shared state",
  });
  assert.equal(decision.id, "DEC-0001");
  assert.equal(decision.seq, 1);
  assert.equal(decision.significance, "routine");
});

test("appendDecision assigns strictly increasing ids across sequential calls", async () => {
  const { client } = await createTestDb();
  const first = await appendDecision(client, {
    date: "2026-09-11",
    story_id: "STORY-001",
    decision: "First decision",
  });
  const second = await appendDecision(client, {
    date: "2026-09-11",
    story_id: "STORY-002",
    decision: "Second decision",
  });
  assert.equal(first.id, "DEC-0001");
  assert.equal(second.id, "DEC-0002");
});

test("appendDecision preserves an explicit architectural significance and optional fields", async () => {
  const { client } = await createTestDb();
  const decision = await appendDecision(client, {
    date: "2026-09-11",
    story_id: "program",
    significance: "architectural",
    context: "Multiple engineers need shared state",
    decision: "Adopt Turso-backed MCP server",
    reasoning: "Solves the id-race condition at the storage layer",
    alternatives_considered: ["custom REST API", "git-branch only"],
    consequences: "New hosted dependency for opted-in projects",
    tradeoffs: "Not zero-infrastructure anymore for those projects",
  });
  assert.equal(decision.significance, "architectural");
  assert.equal(decision.reasoning, "Solves the id-race condition at the storage layer");
  assert.deepEqual(decision.alternatives_considered, ["custom REST API", "git-branch only"]);
});

test("appendDecision assigns unique, sequential ids under concurrent calls", async () => {
  const { client } = await createTestDb();
  const inputs = Array.from({ length: 20 }, (_, i) => ({
    date: "2026-09-11",
    story_id: `STORY-${i}`,
    decision: `Concurrent decision ${i}`,
  }));

  const results = await Promise.all(inputs.map((input) => appendDecision(client, input)));
  const seqs = results.map((r) => r.seq).sort((a, b) => a - b);

  assert.deepEqual(seqs, Array.from({ length: 20 }, (_, i) => i + 1));
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mcp-servers/turso-state && npm test`
Expected: FAIL — `appendDecision` is not exported yet.

- [ ] **Step 3: Write the implementation**

Append to `mcp-servers/turso-state/src/tools.ts`:

```ts
export interface DecisionInput {
  date: string;
  story_id: string;
  significance?: "architectural" | "routine";
  context?: string;
  decision: string;
  reasoning?: string;
  alternatives_considered?: string[];
  consequences?: string;
  tradeoffs?: string;
}

export interface Decision extends DecisionInput {
  id: string;
  seq: number;
  significance: "architectural" | "routine";
  created_at: string;
}

function formatDecisionId(seq: number): string {
  return `DEC-${String(seq).padStart(4, "0")}`;
}

export async function appendDecision(client: Client, input: DecisionInput): Promise<Decision> {
  const significance = input.significance ?? "routine";
  const result = await client.execute({
    sql: `INSERT INTO decisions (date, story_id, significance, context, decision, reasoning, alternatives_considered, consequences, tradeoffs)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          RETURNING seq, created_at`,
    args: [
      input.date,
      input.story_id,
      significance,
      input.context ?? null,
      input.decision,
      input.reasoning ?? null,
      input.alternatives_considered ? JSON.stringify(input.alternatives_considered) : null,
      input.consequences ?? null,
      input.tradeoffs ?? null,
    ],
  });
  const row = result.rows[0];
  const seq = Number(row.seq);
  return {
    id: formatDecisionId(seq),
    seq,
    date: input.date,
    story_id: input.story_id,
    significance,
    context: input.context,
    decision: input.decision,
    reasoning: input.reasoning,
    alternatives_considered: input.alternatives_considered,
    consequences: input.consequences,
    tradeoffs: input.tradeoffs,
    created_at: String(row.created_at),
  };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd mcp-servers/turso-state && npm test`
Expected: PASS — 11 tests passed. The concurrent-calls test is the one directly validating the fix for today's file-based read-then-increment race.

- [ ] **Step 5: Commit**

```bash
git add mcp-servers/turso-state/src/tools.ts mcp-servers/turso-state/src/tools.test.ts
git commit -m "feat(turso-state): add append_decision with atomic sequential id assignment"
```

---

### Task 4: `list_decisions`

**Files:**
- Modify: `mcp-servers/turso-state/src/tools.ts`
- Modify: `mcp-servers/turso-state/src/tools.test.ts`

**Interfaces:**
- Consumes: `Decision`, `Client`
- Produces: `listDecisions(client: Client, opts?: { story_id?: string; since?: string; limit?: number }): Promise<Decision[]>` (tools.ts)

- [ ] **Step 1: Write the failing tests**

Append to `mcp-servers/turso-state/src/tools.test.ts`:

```ts
import { listDecisions } from "./tools.js";

test("listDecisions with no filters returns all entries ordered by seq", async () => {
  const { client } = await createTestDb();
  await appendDecision(client, { date: "2026-09-11", story_id: "STORY-001", decision: "First" });
  await appendDecision(client, { date: "2026-09-11", story_id: "STORY-002", decision: "Second" });

  const decisions = await listDecisions(client);
  assert.deepEqual(
    decisions.map((d) => d.decision),
    ["First", "Second"]
  );
});

test("listDecisions filters by story_id", async () => {
  const { client } = await createTestDb();
  await appendDecision(client, { date: "2026-09-11", story_id: "STORY-001", decision: "For story 1" });
  await appendDecision(client, { date: "2026-09-11", story_id: "STORY-002", decision: "For story 2" });

  const decisions = await listDecisions(client, { story_id: "STORY-001" });
  assert.equal(decisions.length, 1);
  assert.equal(decisions[0].decision, "For story 1");
});

test("listDecisions respects limit", async () => {
  const { client } = await createTestDb();
  await appendDecision(client, { date: "2026-09-11", story_id: "STORY-001", decision: "A" });
  await appendDecision(client, { date: "2026-09-11", story_id: "STORY-001", decision: "B" });
  await appendDecision(client, { date: "2026-09-11", story_id: "STORY-001", decision: "C" });

  const decisions = await listDecisions(client, { limit: 2 });
  assert.equal(decisions.length, 2);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mcp-servers/turso-state && npm test`
Expected: FAIL — `listDecisions` is not exported yet.

- [ ] **Step 3: Write the implementation**

Append to `mcp-servers/turso-state/src/tools.ts`:

```ts
function rowToDecision(row: any): Decision {
  const seq = Number(row.seq);
  return {
    id: formatDecisionId(seq),
    seq,
    date: String(row.date),
    story_id: String(row.story_id),
    significance: String(row.significance) as Decision["significance"],
    context: row.context ? String(row.context) : undefined,
    decision: String(row.decision),
    reasoning: row.reasoning ? String(row.reasoning) : undefined,
    alternatives_considered: row.alternatives_considered
      ? JSON.parse(String(row.alternatives_considered))
      : undefined,
    consequences: row.consequences ? String(row.consequences) : undefined,
    tradeoffs: row.tradeoffs ? String(row.tradeoffs) : undefined,
    created_at: String(row.created_at),
  };
}

export async function listDecisions(
  client: Client,
  opts: { story_id?: string; since?: string; limit?: number } = {}
): Promise<Decision[]> {
  const conditions: string[] = [];
  const args: unknown[] = [];
  if (opts.story_id) {
    conditions.push("story_id = ?");
    args.push(opts.story_id);
  }
  if (opts.since) {
    conditions.push("created_at >= ?");
    args.push(opts.since);
  }
  const where = conditions.length ? `WHERE ${conditions.join(" AND ")}` : "";
  const limitClause = opts.limit ? `LIMIT ${Number(opts.limit)}` : "";
  const result = await client.execute({
    sql: `SELECT seq, date, story_id, significance, context, decision, reasoning, alternatives_considered, consequences, tradeoffs, created_at
          FROM decisions ${where} ORDER BY seq ${limitClause}`,
    args,
  });
  return result.rows.map(rowToDecision);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd mcp-servers/turso-state && npm test`
Expected: PASS — 14 tests passed.

- [ ] **Step 5: Commit**

```bash
git add mcp-servers/turso-state/src/tools.ts mcp-servers/turso-state/src/tools.test.ts
git commit -m "feat(turso-state): add list_decisions with story_id/since/limit filters"
```

---

### Task 5: MCP server wiring (tool registration + entrypoint)

**Files:**
- Create: `mcp-servers/turso-state/src/server.ts`
- Create: `mcp-servers/turso-state/src/index.ts`
- Test: `mcp-servers/turso-state/src/server.test.ts`

**Interfaces:**
- Consumes: all of `tools.ts` (Tasks 2-4), `createDbClient`/`applySchema` (Task 1)
- Produces: `createServer(client: Client): McpServer` (server.ts) — the six tools named exactly `get_backlog`, `get_story`, `set_backlog_meta`, `add_story`, `append_decision`, `list_decisions`, matching the spec's tool surface table

- [ ] **Step 1: Write the failing integration test**

`mcp-servers/turso-state/src/server.test.ts`:

```ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { Client as McpClient } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { createTestDb } from "./test-helpers.js";
import { createServer } from "./server.js";

async function connectedClient(dbClient: Awaited<ReturnType<typeof createTestDb>>["client"]) {
  const server = createServer(dbClient);
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  const mcpClient = new McpClient({ name: "test-client", version: "1.0.0" });
  await Promise.all([mcpClient.connect(clientTransport), server.connect(serverTransport)]);
  return mcpClient;
}

function textOf(result: { content: Array<{ type: string; text?: string }> }): string {
  const block = result.content[0];
  if (!block || block.type !== "text" || block.text === undefined) {
    throw new Error("Expected a text content block");
  }
  return block.text;
}

test("add_story then get_story round-trips via the MCP tool interface", async () => {
  const { client: dbClient } = await createTestDb();
  const mcpClient = await connectedClient(dbClient);

  await mcpClient.callTool({
    name: "add_story",
    arguments: {
      id: "STORY-001",
      title: "Comparison API",
      ticket_id: "JIRA-101",
      acceptance_criteria: ["returns quotes"],
      context_mode: "independent",
    },
  });

  const result = await mcpClient.callTool({ name: "get_story", arguments: { story_id: "STORY-001" } });
  const story = JSON.parse(textOf(result as any));
  assert.equal(story.title, "Comparison API");
});

test("get_story returns an error result for an unknown id, not a thrown exception", async () => {
  const { client: dbClient } = await createTestDb();
  const mcpClient = await connectedClient(dbClient);

  const result: any = await mcpClient.callTool({ name: "get_story", arguments: { story_id: "STORY-999" } });
  assert.equal(result.isError, true);
});

test("append_decision via MCP returns the assigned DEC-#### id", async () => {
  const { client: dbClient } = await createTestDb();
  const mcpClient = await connectedClient(dbClient);

  const result = await mcpClient.callTool({
    name: "append_decision",
    arguments: { date: "2026-09-11", story_id: "STORY-001", decision: "Use Turso" },
  });
  const decision = JSON.parse(textOf(result as any));
  assert.equal(decision.id, "DEC-0001");
});

test("add_story via MCP surfaces a duplicate id as an error result", async () => {
  const { client: dbClient } = await createTestDb();
  const mcpClient = await connectedClient(dbClient);

  const args = {
    id: "STORY-001",
    title: "First",
    ticket_id: "JIRA-1",
    acceptance_criteria: ["a"],
    context_mode: "independent",
  };
  await mcpClient.callTool({ name: "add_story", arguments: args });
  const result: any = await mcpClient.callTool({ name: "add_story", arguments: args });
  assert.equal(result.isError, true);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp-servers/turso-state && npm test`
Expected: FAIL — `./server.js` does not exist yet.

- [ ] **Step 3: Write the server wiring**

`mcp-servers/turso-state/src/server.ts`:

```ts
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import type { Client } from "@libsql/client";
import {
  getBacklog,
  getStory,
  setBacklogMeta,
  addStory,
  appendDecision,
  listDecisions,
  DuplicateStoryIdError,
} from "./tools.js";

export function createServer(client: Client): McpServer {
  const server = new McpServer({ name: "turso-state", version: "1.0.0" });

  server.tool("get_backlog", "Returns backlog metadata and all stories", {}, async () => {
    const backlog = await getBacklog(client);
    return { content: [{ type: "text", text: JSON.stringify(backlog) }] };
  });

  server.tool(
    "get_story",
    "Returns a single story by id",
    { story_id: z.string() },
    async ({ story_id }) => {
      const story = await getStory(client, story_id);
      if (!story) {
        return {
          content: [{ type: "text", text: `No story found with id ${story_id}` }],
          isError: true,
        };
      }
      return { content: [{ type: "text", text: JSON.stringify(story) }] };
    }
  );

  server.tool(
    "set_backlog_meta",
    "Upserts the single backlog metadata row (project, program_spec_ref, architecture_mode)",
    {
      project: z.string(),
      program_spec_ref: z.string().optional(),
      architecture_mode: z.boolean(),
    },
    async ({ project, program_spec_ref, architecture_mode }) => {
      await setBacklogMeta(client, { project, program_spec_ref, architecture_mode });
      return { content: [{ type: "text", text: "ok" }] };
    }
  );

  server.tool(
    "add_story",
    "Inserts one story; errors if the id already exists",
    {
      id: z.string(),
      title: z.string(),
      ticket_id: z.string(),
      acceptance_criteria: z.array(z.string()),
      context_mode: z.enum(["full-spec", "decision-log-only", "independent"]),
      depends_on: z.array(z.string()).optional(),
    },
    async (story) => {
      try {
        await addStory(client, story);
        return { content: [{ type: "text", text: "ok" }] };
      } catch (err) {
        if (err instanceof DuplicateStoryIdError) {
          return { content: [{ type: "text", text: err.message }], isError: true };
        }
        throw err;
      }
    }
  );

  server.tool(
    "append_decision",
    "Inserts one decision log entry, returns its formatted DEC-#### id",
    {
      date: z.string(),
      story_id: z.string(),
      significance: z.enum(["architectural", "routine"]).optional(),
      context: z.string().optional(),
      decision: z.string(),
      reasoning: z.string().optional(),
      alternatives_considered: z.array(z.string()).optional(),
      consequences: z.string().optional(),
      tradeoffs: z.string().optional(),
    },
    async (input) => {
      const result = await appendDecision(client, input);
      return { content: [{ type: "text", text: JSON.stringify(result) }] };
    }
  );

  server.tool(
    "list_decisions",
    "Returns decision log entries, optionally filtered by story_id/since, ordered oldest first",
    {
      story_id: z.string().optional(),
      since: z.string().optional(),
      limit: z.number().optional(),
    },
    async (opts) => {
      const decisions = await listDecisions(client, opts);
      return { content: [{ type: "text", text: JSON.stringify(decisions) }] };
    }
  );

  return server;
}
```

`mcp-servers/turso-state/src/index.ts`:

```ts
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { createDbClient, applySchema } from "./db.js";
import { createServer } from "./server.js";

const databaseUrl = process.env.TURSO_DATABASE_URL;
const authToken = process.env.TURSO_AUTH_TOKEN;

if (!databaseUrl) {
  throw new Error("TURSO_DATABASE_URL environment variable is required");
}

const client = createDbClient(databaseUrl, authToken);
await applySchema(client);

const server = createServer(client);
const transport = new StdioServerTransport();
await server.connect(transport);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp-servers/turso-state && npm test`
Expected: PASS — 18 tests passed.

- [ ] **Step 5: Build check**

Run: `cd mcp-servers/turso-state && npm run build`
Expected: compiles cleanly, produces `dist/index.js` and `dist/server.js`.

- [ ] **Step 6: Commit**

```bash
git add mcp-servers/turso-state/src/server.ts mcp-servers/turso-state/src/index.ts \
  mcp-servers/turso-state/src/server.test.ts
git commit -m "feat(turso-state): wire MCP tool registration and stdio entrypoint"
```

---

### Task 6: Export script (Turso -> file-based view) with schema-conformance test

**Files:**
- Create: `mcp-servers/turso-state/src/export.ts`
- Test: `mcp-servers/turso-state/src/export.test.ts`
- Modify: `mcp-servers/turso-state/package.json` (add `ajv` — already listed in Task 1's devDependencies; no change needed here)

**Interfaces:**
- Consumes: `Backlog`, `Decision` types and `getBacklog`/`listDecisions` (tools.ts)
- Produces: `formatStoryBacklogJson(backlog: Backlog): StoryBacklogJson` (export.ts) — pure, testable without a DB
- Produces: `formatDecisionLogJsonl(decisions: Decision[]): string` (export.ts) — pure, testable without a DB
- Produces: a runnable CLI (`npm run export`) that pulls from Turso and pushes the regenerated files to the `claude-state-export` branch via a temporary worktree

- [ ] **Step 1: Write the failing schema-conformance tests**

`mcp-servers/turso-state/src/export.test.ts`:

```ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import Ajv from "ajv";
import { createTestDb } from "./test-helpers.js";
import { setBacklogMeta, addStory, appendDecision, getBacklog, listDecisions } from "./tools.js";
import { formatStoryBacklogJson, formatDecisionLogJsonl } from "./export.js";

test("formatStoryBacklogJson output validates against schemas/story-backlog.schema.json", async () => {
  const { client } = await createTestDb();
  await setBacklogMeta(client, { project: "Test Project", architecture_mode: false });
  await addStory(client, {
    id: "STORY-001",
    title: "Test story",
    ticket_id: "JIRA-1",
    acceptance_criteria: ["does the thing"],
    context_mode: "independent",
  });

  const backlog = await getBacklog(client);
  const json = formatStoryBacklogJson(backlog);

  const schema = JSON.parse(readFileSync("../../schemas/story-backlog.schema.json", "utf-8"));
  const ajv = new Ajv();
  const validate = ajv.compile(schema);
  const valid = validate(json);
  assert.equal(valid, true, JSON.stringify(validate.errors));
});

test("formatDecisionLogJsonl output: each line validates against schemas/decision-log.schema.json", async () => {
  const { client } = await createTestDb();
  await appendDecision(client, {
    date: "2026-09-11",
    story_id: "STORY-001",
    decision: "Use Turso for shared state",
  });
  await appendDecision(client, {
    date: "2026-09-11",
    story_id: "STORY-002",
    significance: "architectural",
    decision: "Second decision",
  });

  const decisions = await listDecisions(client);
  const jsonl = formatDecisionLogJsonl(decisions);
  const lines = jsonl.trim().split("\n");
  assert.equal(lines.length, 2);

  const schema = JSON.parse(readFileSync("../../schemas/decision-log.schema.json", "utf-8"));
  const ajv = new Ajv();
  const validate = ajv.compile(schema);

  for (const line of lines) {
    const valid = validate(JSON.parse(line));
    assert.equal(valid, true, JSON.stringify(validate.errors));
  }
});

test("formatDecisionLogJsonl returns an empty string for no decisions", () => {
  assert.equal(formatDecisionLogJsonl([]), "");
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mcp-servers/turso-state && npm test`
Expected: FAIL — `./export.js` does not exist yet.

- [ ] **Step 3: Write the implementation**

`mcp-servers/turso-state/src/export.ts`:

```ts
import { mkdtempSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import type { Backlog, Decision } from "./tools.js";
import { createDbClient } from "./db.js";
import { getBacklog, listDecisions } from "./tools.js";

export interface StoryBacklogJson {
  project: string;
  program_spec_ref?: string;
  architecture_mode: boolean;
  stories: Array<{
    id: string;
    title: string;
    ticket_id: string;
    acceptance_criteria: string[];
    context_mode: string;
    depends_on?: string[];
  }>;
}

export function formatStoryBacklogJson(backlog: Backlog): StoryBacklogJson {
  if (!backlog.meta) {
    throw new Error("Cannot export: backlog_meta has not been set yet");
  }
  return {
    project: backlog.meta.project,
    program_spec_ref: backlog.meta.program_spec_ref,
    architecture_mode: backlog.meta.architecture_mode,
    stories: backlog.stories.map((s) => ({
      id: s.id,
      title: s.title,
      ticket_id: s.ticket_id,
      acceptance_criteria: s.acceptance_criteria,
      context_mode: s.context_mode,
      depends_on: s.depends_on,
    })),
  };
}

export function formatDecisionLogJsonl(decisions: Decision[]): string {
  if (decisions.length === 0) return "";
  return (
    decisions
      .map((d) =>
        JSON.stringify({
          id: d.id,
          date: d.date,
          story_id: d.story_id,
          significance: d.significance,
          context: d.context,
          decision: d.decision,
          reasoning: d.reasoning,
          alternatives_considered: d.alternatives_considered,
          consequences: d.consequences,
          tradeoffs: d.tradeoffs,
        })
      )
      .join("\n") + "\n"
  );
}

async function main() {
  const databaseUrl = process.env.TURSO_DATABASE_URL;
  const authToken = process.env.TURSO_AUTH_TOKEN;
  if (!databaseUrl) {
    throw new Error("TURSO_DATABASE_URL environment variable is required");
  }

  const client = createDbClient(databaseUrl, authToken);
  const backlog = await getBacklog(client);
  const decisions = await listDecisions(client);

  const storyBacklogJson = JSON.stringify(formatStoryBacklogJson(backlog), null, 2) + "\n";
  const decisionLogJsonl = formatDecisionLogJsonl(decisions);

  // The claude-state-export branch must already exist (created once, manually,
  // as part of provisioning) - this script does not create it.
  const worktreeDir = mkdtempSync(join(tmpdir(), "claude-state-export-"));
  execFileSync("git", ["worktree", "add", worktreeDir, "claude-state-export"], { stdio: "inherit" });
  try {
    const stateDir = join(worktreeDir, ".claude", "state");
    mkdirSync(stateDir, { recursive: true });
    writeFileSync(join(stateDir, "story-backlog.json"), storyBacklogJson);
    writeFileSync(join(stateDir, "decision-log.jsonl"), decisionLogJsonl);

    execFileSync(
      "git",
      ["-C", worktreeDir, "add", ".claude/state/story-backlog.json", ".claude/state/decision-log.jsonl"],
      { stdio: "inherit" }
    );
    execFileSync("git", ["-C", worktreeDir, "commit", "-m", "chore: export state from Turso"], {
      stdio: "inherit",
    });
    execFileSync("git", ["-C", worktreeDir, "push", "origin", "claude-state-export"], { stdio: "inherit" });
  } finally {
    execFileSync("git", ["worktree", "remove", worktreeDir, "--force"]);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd mcp-servers/turso-state && npm test`
Expected: PASS — 21 tests passed.

- [ ] **Step 5: Commit**

```bash
git add mcp-servers/turso-state/src/export.ts mcp-servers/turso-state/src/export.test.ts
git commit -m "feat(turso-state): add export script with schema-conformance tests"
```

---

### Task 7: `orchestration.yaml` config, `install.ps1` copy + conditional MCP registration

**Files:**
- Modify: `project-template/.claude/config/orchestration.yaml`
- Modify: `install.ps1:214-263` (new variables + copy block)
- Modify: `install.ps1` (new section inserted between line 315 and line 317 — the `state_backend: turso` MCP registration)

**Interfaces:**
- Consumes: the `mcp-servers/turso-state/` directory produced by Tasks 1-6
- Produces: `.mcp.json` at the target project root (when opted in), registering a `turso-state` server entry that runs `node .claude/mcp-servers/turso-state/dist/index.js`

- [ ] **Step 1: Add `state_backend`/`turso` block to the config template**

Append to `project-template/.claude/config/orchestration.yaml`:

```yaml

# Where story-backlog.json and decision-log.jsonl are stored and accessed from.
# 'file' (default): plain files under state_dir, read/written directly - zero
# external dependencies, right for a solo engineer or a small team without
# real concurrent-branch contention on this state.
# 'turso': routes story-backlog/decision-log reads and writes through a local
# MCP server (.claude/mcp-servers/turso-state/) backed by a hosted Turso
# database - opt into this once multiple engineers are running
# feature-orchestrator concurrently on separate branches against the same
# backlog/decision log. Only story-backlog.json and decision-log.jsonl move
# to Turso in this mode - everything under stories_dir stays plain files
# either way. See agentic-sdlc-core's
# docs/features/specs/2026-09-11-turso-state-backend-design.md for the
# full design.
state_backend: file   # file | turso

# Only read when state_backend is turso. The database URL is an identifier,
# not a secret - safe to commit. The auth token is NEVER stored here; it
# comes from the TURSO_AUTH_TOKEN environment variable, set locally by each
# engineer from their own scoped Turso token. install.ps1 never touches
# credentials.
turso:
  database_url: libsql://<db-name>-<org>.turso.io
```

- [ ] **Step 2: Add the mcp-servers copy block to `install.ps1`**

In `install.ps1`, modify the variable block at lines 214-221 (add two new lines after the existing four `...Src`/`...Dest` pairs):

```powershell
$mcpServersSrc  = Join-Path $tempDir "mcp-servers"
$mcpServersDest = Join-Path $claudeDir "mcp-servers"
```

Then insert a new copy block after the existing scripts block (currently lines 255-263, immediately before the `# Record what's installed` comment at line 265):

```powershell
if (Test-Path $mcpServersSrc) {
    Write-Step "Installing mcp-servers -> $mcpServersDest"
    New-Item -ItemType Directory -Force -Path $mcpServersDest | Out-Null
    Copy-Item -Path "$mcpServersSrc\*" -Destination $mcpServersDest -Recurse -Force
    Remove-StaleEntries -SourceDir $mcpServersSrc -DestDir $mcpServersDest -Label "mcp server"
    Write-Ok "MCP servers installed"
} else {
    Write-Warn "No mcp-servers/ folder found in the source repo at ref '$Ref' - skipped."
}
```

This always copies `mcp-servers/turso-state/` into every project, mirrored the same way as `skills`/`agents`/`schemas`/`scripts` via the existing `Remove-StaleEntries` function — regardless of whether the project has opted into `state_backend: turso`. It stays inert until registered in the next step.

- [ ] **Step 3: Add the conditional `.mcp.json` registration block**

Insert a new section in `install.ps1` between the end of the scaffold block (line 315, `} else {` / `Write-Warn "No project-template/..."` closing at line 315) and the analytics section comment at line 317:

```powershell
# --- Register turso-state MCP server if this project has opted into state_backend: turso

$orchestrationPath = Join-Path $claudeDir "config\orchestration.yaml"
if (Test-Path $orchestrationPath) {
    $orchestrationLines = [System.IO.File]::ReadAllLines((Resolve-Path $orchestrationPath), [System.Text.Encoding]::UTF8)
    $stateBackendLine = $orchestrationLines | Where-Object { $_ -match '^\s*state_backend:\s*turso\s*$' }

    if ($stateBackendLine) {
        Write-Step "state_backend: turso detected - registering turso-state MCP server"

        $dbUrlLine = $orchestrationLines | Where-Object { $_ -match '^\s*database_url:\s*(\S+)' } | Select-Object -First 1
        $databaseUrl = if ($dbUrlLine) { ($dbUrlLine -replace '^\s*database_url:\s*', '').Trim() } else { "" }

        if (-not $databaseUrl -or $databaseUrl -eq "libsql://<db-name>-<org>.turso.io") {
            Write-Warn "turso.database_url is not set in $orchestrationPath - fill it in before this server will work."
        }

        $mcpConfigPath = ".mcp.json"
        $serverEntryPath = Join-Path $claudeDir "mcp-servers\turso-state\dist\index.js"

        if (Test-Path $mcpConfigPath) {
            $mcpConfig = Get-Content $mcpConfigPath -Raw | ConvertFrom-Json
        } else {
            $mcpConfig = [PSCustomObject]@{ mcpServers = [PSCustomObject]@{} }
        }

        if (-not $mcpConfig.mcpServers) {
            $mcpConfig | Add-Member -MemberType NoteProperty -Name mcpServers -Value ([PSCustomObject]@{})
        }

        if ($mcpConfig.mcpServers.PSObject.Properties.Name -contains "turso-state") {
            Write-Info "turso-state already registered in $mcpConfigPath - leaving existing entry untouched. Delete it first if you want this install to rewrite it."
        } else {
            $tursoEntry = [PSCustomObject]@{
                command = "node"
                args    = @($serverEntryPath)
                env     = [PSCustomObject]@{
                    TURSO_DATABASE_URL = $databaseUrl
                    TURSO_AUTH_TOKEN   = "`${TURSO_AUTH_TOKEN}"
                }
            }
            $mcpConfig.mcpServers | Add-Member -MemberType NoteProperty -Name "turso-state" -Value $tursoEntry
            ($mcpConfig | ConvertTo-Json -Depth 10) | Set-Content -Path $mcpConfigPath
            Write-Ok "Registered turso-state MCP server in $mcpConfigPath"
        }
    }
}
```

Note for whoever implements this step: verify against current Claude Code documentation that `${VAR}`-style environment variable expansion is supported in a project's `.mcp.json` `env` block before relying on it — if it isn't (or the syntax differs), the `TURSO_AUTH_TOKEN` line in the `env` block can simply be dropped, since `index.ts` (Task 5) already reads `process.env.TURSO_AUTH_TOKEN` directly and will pick it up from an inherited shell environment either way; only `TURSO_DATABASE_URL`, which isn't secret, strictly needs to be written into the file.

- [ ] **Step 4: Manual verification (no automated test — this is PowerShell orchestration, verified by running it)**

Run, from a scratch temp directory with a fake git remote pointing at a local clone of this repo (or against a real fork), with `orchestration.yaml`'s `state_backend` set to `turso` beforehand or via `-Force` after a first install:

```powershell
.\install.ps1 -RepoUrl "<local-or-test-repo-url>" -Ref "<branch-with-this-work>"
```

Expected: `.claude/mcp-servers/turso-state/` exists with the full package copied; if `state_backend: turso` is set in `.claude/config/orchestration.yaml`, `.mcp.json` exists at the project root with a `turso-state` entry pointing at `.claude/mcp-servers/turso-state/dist/index.js`. Re-running the install does not duplicate or overwrite an existing `.mcp.json` entry.

- [ ] **Step 5: Commit**

```bash
git add project-template/.claude/config/orchestration.yaml install.ps1
git commit -m "feat(turso-state): install mcp-servers/ and conditionally register turso-state MCP server"
```

---

### Task 8: `decision-recorder` conditional branch

**Files:**
- Modify: `skills/decision-recorder/SKILL.md`

**Interfaces:**
- Consumes: the `append_decision` MCP tool name and its argument shape from Task 5

- [ ] **Step 1: Replace the write procedure with a state_backend-conditional version**

In `skills/decision-recorder/SKILL.md`, replace the paragraph beginning "Record the decision that was just made in this session, as one line appended to..." and the numbered "To write an entry:" list that follows it, with:

```markdown
Record the decision that was just made in this session, matching `decision-log.schema.json`. Where it's written depends on this project's `state_backend` in `config/orchestration.yaml`:
- `file` (default): one line appended to `.claude/state/decision-log.jsonl` — JSON Lines, one compact object per line. Never rewrite existing lines; only append.
- `turso`: one row inserted via the `turso-state` MCP server's `append_decision` tool. The tool assigns the sequential id itself, atomically, at the database — skip step 1 below entirely in this mode, and use the `id` the tool call returns.

To write an entry:
1. **file mode only** — if `decision-log.jsonl` exists, read it and find the highest `DEC-####` id present. Use the next number. If the file doesn't exist or is empty, start at `DEC-0001`. **turso mode skips this step** — `append_decision` assigns the id.
2. Construct the entry with:
   - `date` — today, ISO 8601 (`YYYY-MM-DD`)
   - `story_id` — the current story's id, or `program` if this is being recorded during /project-scoper
   - `significance` — `architectural` if the calling skill tells you this one is (service boundaries, data ownership, integration patterns, an irreversible or foundational choice), otherwise `routine`. This isn't your judgment call — record whatever the caller states; if it states nothing, default to `routine`.
   - `context` — what situation led to this decision
   - `decision` — what was decided
   - `reasoning` — why
   - `alternatives_considered` — what else was on the table
   - `consequences` — what this leads to
   - `tradeoffs` — what was given up
3. Write it:
   - **file mode**: prepend the `id` from step 1, and append the whole object as a single compact JSON line — no pretty-printing, one line per entry, consistent with every other line in the file.
   - **turso mode**: call `append_decision` with the fields from step 2 (no `id` — the tool assigns it). Use the `id` the tool returns for anything else this call needs to reference. If the call fails (network, auth, Turso outage), that's a hard stop — surface the error to whatever invoked decision-recorder rather than retrying silently or falling back to file mode.
```

- [ ] **Step 2: Manual verification (prompt instructions, not code — no automated test)**

Read the full updated `skills/decision-recorder/SKILL.md` top to bottom and confirm: the `file`-mode instructions are byte-for-byte equivalent in meaning to what existed before this edit (no accidental behavior change for existing projects), and the `turso`-mode instructions reference exactly the tool name and argument shape defined in `mcp-servers/turso-state/src/server.ts` (Task 5) — `append_decision` with `date`, `story_id`, `significance?`, `context?`, `decision`, `reasoning?`, `alternatives_considered?`, `consequences?`, `tradeoffs?`.

- [ ] **Step 3: Commit**

```bash
git add skills/decision-recorder/SKILL.md
git commit -m "feat(turso-state): branch decision-recorder on state_backend"
```

---

### Task 9: `story-converter` conditional branch

**Files:**
- Modify: `agents/story-converter.md`

**Interfaces:**
- Consumes: `get_backlog`, `set_backlog_meta`, `add_story` MCP tool names and argument shapes from Task 5

- [ ] **Step 1: Replace the spec-mode backlog read/write instructions**

In `agents/story-converter.md`, replace the three paragraphs (the "For each story, create its directory..." paragraph through the "If `.claude/state/story-backlog.json` already exists, read it first..." paragraph) with:

```markdown
For each story, create its directory at `<stories_dir>/<story-id>-<slug>/` (you choose the slug, from the story's title) and write `ticket.json` there: the story's `ticket_id` plus an empty sync log. `stories_dir` is given to you explicitly by whoever invoked you - you have no project config access of your own. This step is unaffected by `state_backend` — `ticket.json` always lives under `stories_dir` as a plain file, in both modes.

Write the whole backlog — `project`, `program_spec_ref`, `architecture_mode`, and the `stories` array with every field set above. Where depends on this project's `state_backend`, given to you explicitly by whoever invoked you (you have no project config access of your own):
- `file` (default): to `.claude/state/story-backlog.json`, matching `story-backlog.schema.json` exactly: a single JSON object, not JSON Lines. Written once per project (or once per project-scoper re-run against an already-scoped project), not appended to incrementally the way `decision-log.jsonl` is.
- `turso`: call `set_backlog_meta` once with `project`/`program_spec_ref`/`architecture_mode`, then `add_story` once per story with that story's fields. `add_story` errors if a story `id` you pass already exists — treat that the same as the file-mode duplicate-id check below, not as a transient failure to retry past.

If checking for an already-scoped project (this run is a `project-scoper` re-run):
- `file` mode: if `.claude/state/story-backlog.json` already exists, read it first: never assign a story id already in use, and never recreate a ticket for a story that's already there.
- `turso` mode: call `get_backlog` first for the same reason - never assign a story id `get_backlog` already returned, and never recreate a ticket for a story it already lists.
```

- [ ] **Step 2: Manual verification (prompt instructions, not code — no automated test)**

Read the full updated `agents/story-converter.md` and confirm plan mode (ticket sync) is completely untouched — it never read or wrote `story-backlog.json` in file mode either, so it has no `state_backend` branch to add. Confirm the `turso`-mode tool names/arguments match `mcp-servers/turso-state/src/server.ts` exactly.

- [ ] **Step 3: Commit**

```bash
git add agents/story-converter.md
git commit -m "feat(turso-state): branch story-converter spec mode on state_backend"
```

---

### Task 10: `feature-orchestrator` conditional branch

**Files:**
- Modify: `skills/feature-orchestrator/SKILL.md`

**Interfaces:**
- Consumes: `get_story`, `get_backlog`, `list_decisions` MCP tool names and argument shapes from Task 5

- [ ] **Step 1: Replace step 0's context-loading instructions**

In `skills/feature-orchestrator/SKILL.md`, replace step 0 (the numbered list item beginning "0. If this run is executing one story from a /project-scoper backlog...") with:

```markdown
0. Read `state_backend` from `config/orchestration.yaml` now (`file` or `turso`) - it governs how every read/write to `story-backlog.json`/`decision-log.jsonl` happens for the rest of this run, in this step and in "Context escalation" below. If this run is executing one story from a /project-scoper backlog, look up that story's `context_mode`: in `file` mode, from `.claude/state/story-backlog.json`; in `turso` mode, via the `turso-state` MCP server's `get_story` tool. Then load context per that value before proceeding: `full-spec` loads the program-level spec as reference for /grill-me and /spec-writer; `decision-log-only` loads only the shared decision log (`.claude/state/decision-log.jsonl` in `file` mode, the `list_decisions` MCP tool in `turso` mode); `independent` loads neither. This is a starting point, not fixed for the run — see "Context escalation" below. This only affects what context is available going in — decision-recorder writes at steps 7, 10, and 14 below always happen regardless of `context_mode`, and decision-recorder branches on `state_backend` itself for those writes (see `skills/decision-recorder/SKILL.md`) - nothing here needs to duplicate that logic. Also read `stories_dir` from `config/orchestration.yaml` now — every per-story file this run writes (steps 6 and 9 below) goes under `<stories_dir>/<story-id>-<slug>/`, this project's configured location, never a hardcoded path, and unaffected by `state_backend` either way.
```

- [ ] **Step 2: Replace context escalation step 2**

In the "Context escalation" section, replace the numbered item "2. Load the program-level spec via `program_spec_ref` from the story backlog (already on `main`..." with:

```markdown
2. Load the program-level spec via `program_spec_ref` - from `.claude/state/story-backlog.json` in `file` mode (already on `main`, since `project-scoper` writes it before any story branches exist, so there's no branch-visibility issue like the rest of `.claude/state/` has in that mode), or via the `get_backlog` MCP tool in `turso` mode (branch-independent by construction, since the database isn't part of any branch).
```

- [ ] **Step 3: Manual verification (prompt instructions, not code — no automated test)**

Read the full updated `skills/feature-orchestrator/SKILL.md` and confirm: no other step references `story-backlog.json` or `decision-log.jsonl` directly (steps 7/10/14 delegate to `/decision-recorder`, which already branches internally per Task 8; step 16 delegates to `story-converter` plan mode, which has no `state_backend` branch per Task 9). Confirm `turso`-mode tool names/arguments match `mcp-servers/turso-state/src/server.ts` exactly.

- [ ] **Step 4: Commit**

```bash
git add skills/feature-orchestrator/SKILL.md
git commit -m "feat(turso-state): branch feature-orchestrator context loading on state_backend"
```

---

### Task 11: Docs and version bump

**Files:**
- Modify: `VERSION`
- Modify: `CHANGELOG.md`
- Modify: `README.md`
- Modify: `HOW-IT-WORKS.md`
- Modify: `docs/OPEN-DISCUSSIONS.md`

**Interfaces:**
- Consumes: nothing new — this task only documents Tasks 1-10's completed work

- [ ] **Step 1: Bump VERSION**

Set the contents of `VERSION` to:

```
7.5.0
```

- [ ] **Step 2: Add a CHANGELOG.md entry**

Insert at the top of `CHANGELOG.md`, immediately after the `# Changelog` heading and before the existing `## 7.4.0` entry:

```markdown
## 7.5.0 — opt-in Turso-backed state store for story-backlog and decision-log

**Added**
- New `state_backend` setting in `orchestration.yaml` (`file` | `turso`, defaults to `file`). When set to `turso`, `story-backlog.json` and `decision-log.jsonl` reads/writes route through a new local MCP server (`.claude/mcp-servers/turso-state/`, Node/TypeScript) backed by a hosted Turso (libSQL) database, instead of plain files - opt into this once multiple engineers are running `feature-orchestrator` concurrently on separate branches against the same backlog/decision log. Everything under `stories_dir` (`spec.md`, `plan.json`, `ticket.json`) is unaffected either way - those files were never the source of the concurrency problem this solves.
- The `turso` mode's `append_decision` MCP tool assigns each decision's sequential id atomically at the database (SQLite/libSQL `AUTOINCREMENT`), which directly removes a real race condition in `decision-recorder`'s file-mode id assignment (`read the file, find the highest DEC-####, use the next number`) that existed under concurrent writers before this change.
- `decision-recorder`, `story-converter` (spec mode), and `feature-orchestrator` (step 0 and the context escalation section) now branch on `state_backend` - `file` mode is byte-for-byte the same behavior as before this release; `turso` mode calls the new MCP tools instead of reading/writing files directly.
- New `mcp-servers/turso-state/export.ts` script regenerates `story-backlog.json`/`decision-log.jsonl` from the live Turso tables onto a dedicated `claude-state-export` git branch, on demand - keeps `scripts/rotate-decision-log.ps1` and `scripts/export-adrs.ps1` working completely unmodified against a `turso`-backed project. Rotation in this mode is now purely a file-readability convenience, not a retention operation - Turso retains every row indefinitely.
- `install.ps1` now always installs `mcp-servers/turso-state/` (mirrored via the existing `Remove-StaleEntries` mechanism, same as `skills`/`agents`/`schemas`/`scripts`), and additionally registers it in the project's `.mcp.json` when `state_backend: turso` is already set at install time. `install.ps1` never writes or generates Turso credentials - `TURSO_AUTH_TOKEN` is set locally by each engineer from a scoped token, per the same constraint already agreed for the ticket-system MCP integration.

**Why**: real design discussion (see `docs/features/specs/2026-09-11-turso-state-backend-design.md`) about a genuine target environment for this tool - a monorepo with several engineers, each running `feature-orchestrator` on their own feature branch off a backlog a tech lead produced once. `story-backlog.json` and `decision-log.jsonl` living inside whatever branch a session happens to be on doesn't hold up under that concurrency: `decision-log`'s id assignment has a real read-then-increment race today, and `story-backlog.json` (write-once, no status field - the ticket system is the system of record for anything that changes after creation) gives every engineer's branch a possibly-stale local copy. Considered a custom-hosted REST API and a git-native dedicated-branch-only approach first; rejected both - the former means operating your own database and auth from scratch, the latter still doesn't remove the id-race condition, since "highest id in the file" is read-then-increment even on a branch nobody's feature work touches. A hosted libSQL database gives atomic sequential ids and real transactional writes for free, and a local/stdio MCP server means no one has to host anything beyond the database itself. Kept strictly opt-in, matching this repo's "narrow default, cheap escalation" pattern already used for `context_mode` and `depends_on` - a solo engineer or small team never has to know this exists.
```

- [ ] **Step 3: Add a bullet to README.md's "What's in here" list**

In `README.md`, after the `- **`project-template/`** — ...` bullet (line 19), add:

```markdown
- **`mcp-servers/turso-state/`** — an optional local MCP server (Node/TypeScript), backed by a hosted Turso database, that a project can opt into via `orchestration.yaml`'s `state_backend: turso` setting to share `story-backlog.json`/`decision-log.jsonl` across multiple engineers' concurrent feature branches instead of each branch carrying its own file copy. Off by default; `file` mode (plain files, no external dependency) is unaffected either way.
```

- [ ] **Step 4: Add a paragraph to README.md's "Using this in a project" section**

In `README.md`, after the paragraph ending "...See `project-template/.claude/config/orchestration.yaml` for the format." (line 57), add:

```markdown
If multiple engineers will run `feature-orchestrator` concurrently on separate branches against the same backlog, consider `state_backend: turso` in that same config file instead of the `file` default - see `mcp-servers/turso-state/` above and this repo's design spec (`docs/features/specs/2026-09-11-turso-state-backend-design.md`) for what that changes and what it doesn't.
```

- [ ] **Step 5: Add a HOW-IT-WORKS.md subsection**

In `HOW-IT-WORKS.md`, insert a new subsection immediately before the `### Updating a project's core version` heading (line 226):

```markdown
### Sharing state across concurrent engineers (optional Turso backend)

By default (`state_backend: file`), `story-backlog.json` and `decision-log.jsonl` are plain files, read and written directly - fine for one engineer, but each of several engineers' feature branches ends up with its own copy once more than one is running `feature-orchestrator` at the same time. `decision-log.jsonl`'s id assignment in particular is a real read-then-increment race under that concurrency, not just a merge inconvenience.

Setting `state_backend: turso` in `orchestration.yaml` routes `story-backlog.json`/`decision-log.jsonl` reads and writes through `.claude/mcp-servers/turso-state/`, a local MCP server backed by a hosted Turso (libSQL) database instead. `decision-recorder`, `story-converter` (spec mode), and `feature-orchestrator` all branch on this setting internally - nothing else about how you invoke them changes. Everything under `stories_dir` stays a plain file in both modes; it was never the part of `.claude/state/` with a concurrency problem.

This is opt-in and off by default - only turn it on once real concurrent-branch contention on this state is an actual, not hypothetical, problem for your team. See `docs/features/specs/2026-09-11-turso-state-backend-design.md` in agentic-sdlc-core for the full design, including the export mechanism that keeps `rotate-decision-log.ps1`/`export-adrs.ps1` working unmodified against a `turso`-backed project.
```

- [ ] **Step 6: Add a resolution note to docs/OPEN-DISCUSSIONS.md**

In `docs/OPEN-DISCUSSIONS.md`, at the end of the "MCP tool integration for skills/agents" section, add:

```markdown
**Resolved for internal state, as of 7.5.0**: the concurrent-branch state-sharing question (a different one from the ticket-system MCP integration above, but using the same mechanism) is addressed for teams that opt in - see `docs/features/specs/2026-09-11-turso-state-backend-design.md` and the `7.5.0` `CHANGELOG.md` entry. The ticket-system MCP integration itself, and its open question about whether an org uses one ticket system uniformly, remain unbuilt and unresolved.
```

- [ ] **Step 7: Commit**

```bash
git add VERSION CHANGELOG.md README.md HOW-IT-WORKS.md docs/OPEN-DISCUSSIONS.md
git commit -m "docs(turso-state): version bump to 7.5.0 and document the opt-in Turso state backend"
```
