import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { createDbClient, applySchema } from "./db.js";
import { createServer } from "./server.js";
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
