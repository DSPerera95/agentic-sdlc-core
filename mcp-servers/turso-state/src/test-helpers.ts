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
