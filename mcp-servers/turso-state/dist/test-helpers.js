import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createDbClient, applySchema } from "./db.js";
export async function createTestDb() {
    const dir = mkdtempSync(join(tmpdir(), "turso-state-test-"));
    const path = join(dir, "test.db");
    const client = createDbClient(`file:${path}`);
    await applySchema(client);
    return { client, path };
}
