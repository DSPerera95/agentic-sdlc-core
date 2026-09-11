// Runs against the compiled dist/ output (not src/ via tsx) to catch
// build-packaging bugs that unit tests can't see - e.g. schema.sql not
// being copied alongside the compiled JS. Requires `npm run build` first
// (the "test:dist" script does this).
import { mkdtempSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import assert from "node:assert/strict";
import { createDbClient, applySchema } from "./dist/db.js";

const dir = mkdtempSync(join(tmpdir(), "turso-state-dist-smoke-"));
const dbPath = join(dir, "smoke.db");

assert.ok(existsSync("./dist/schema.sql"), "dist/schema.sql must exist after build");
assert.ok(existsSync("./dist/package.json"), "dist/package.json must exist after build");

const client = createDbClient(`file:${dbPath}`);
await applySchema(client);

const result = await client.execute(
  "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
);
const tableNames = result.rows.map((row) => row.name).sort();
assert.deepEqual(tableNames, ["backlog_meta", "decisions", "stories"]);

rmSync(dir, { recursive: true, force: true });
console.log("dist smoke test passed");
