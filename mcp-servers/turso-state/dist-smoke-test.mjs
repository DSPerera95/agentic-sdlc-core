// Runs against the compiled dist/ output (not src/ via tsx) to catch
// build-packaging bugs that unit tests can't see - e.g. schema.sql not
// being copied alongside the compiled JS. Requires `npm run build` first
// (the "test:dist" script does this).
import { mkdtempSync, rmSync, existsSync, mkdirSync, cpSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawn } from "node:child_process";
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

// --- Verify the sibling .env.local mechanism setup-mcp-server.ps1 relies on:
// simulate the installed consumer layout (.claude/mcp-servers/turso-state/
// with a sibling turso-state.env.local) and confirm the server picks up
// TURSO_DATABASE_URL from that file rather than requiring it already be in
// the process environment.
const consumerRoot = mkdtempSync(join(tmpdir(), "turso-state-envlocal-smoke-"));
const mcpServersDir = join(consumerRoot, ".claude", "mcp-servers");
const serverDir = join(mcpServersDir, "turso-state");
mkdirSync(serverDir, { recursive: true });
cpSync("./dist", serverDir, { recursive: true });
symlinkSync(resolve("./node_modules"), join(serverDir, "node_modules"));

const envLocalDbPath = join(consumerRoot, "envlocal-smoke.db");
writeFileSync(join(mcpServersDir, "turso-state.env.local"), `TURSO_DATABASE_URL=file:${envLocalDbPath}\n`);

const { TURSO_DATABASE_URL, TURSO_AUTH_TOKEN, ...envWithoutTurso } = process.env;
const child = spawn(process.execPath, ["index.js"], { cwd: serverDir, env: envWithoutTurso });

let stderr = "";
child.stderr.on("data", (chunk) => { stderr += chunk.toString(); });

const survived = await new Promise((res) => {
  const timer = setTimeout(() => res(true), 1500);
  child.on("exit", () => { clearTimeout(timer); res(false); });
});

child.kill("SIGTERM");
rmSync(consumerRoot, { recursive: true, force: true });

assert.ok(
  survived,
  `server exited instead of staying up - TURSO_DATABASE_URL from the sibling .env.local was not picked up. stderr:\n${stderr}`
);

console.log("dist smoke test passed");
