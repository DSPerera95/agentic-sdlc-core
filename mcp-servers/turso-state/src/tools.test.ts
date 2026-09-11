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
