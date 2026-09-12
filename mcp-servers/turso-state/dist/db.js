import { createClient } from "@libsql/client";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
const __dirname = dirname(fileURLToPath(import.meta.url));
export function createDbClient(url, authToken) {
    return createClient({ url, authToken });
}
export async function applySchema(client) {
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
