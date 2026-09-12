import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { config as loadDotenv } from "dotenv";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { createDbClient, applySchema } from "./db.js";
import { createServer } from "./server.js";

const __dirname = dirname(fileURLToPath(import.meta.url));

// In the installed layout (.claude/mcp-servers/turso-state/index.js, written
// by setup-mcp-server.ps1), this is a sibling of the server's own install
// directory - not committed, holding real credential values. A no-op when it
// doesn't exist (e.g. running via tsx against src/ in this repo), and never
// overrides a value already present in the real environment.
loadDotenv({ path: join(__dirname, "..", "turso-state.env.local") });

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
