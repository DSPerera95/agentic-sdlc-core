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
