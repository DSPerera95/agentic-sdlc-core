import { test } from "node:test";
import assert from "node:assert/strict";
import { createTestDb } from "./test-helpers.js";

test("applySchema creates the three expected tables", async () => {
  const { client } = await createTestDb();
  const result = await client.execute(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
  );
  const tableNames = result.rows.map((r) => String(r.name));
  assert.deepEqual(tableNames, ["backlog_meta", "decisions", "stories"]);
});
