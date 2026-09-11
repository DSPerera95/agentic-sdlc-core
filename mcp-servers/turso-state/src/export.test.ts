import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import Ajv from "ajv";
import addFormats from "ajv-formats";
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
  addFormats(ajv);
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
  addFormats(ajv);
  const validate = ajv.compile(schema);

  for (const line of lines) {
    const valid = validate(JSON.parse(line));
    assert.equal(valid, true, JSON.stringify(validate.errors));
  }
});

test("formatDecisionLogJsonl returns an empty string for no decisions", () => {
  assert.equal(formatDecisionLogJsonl([]), "");
});
