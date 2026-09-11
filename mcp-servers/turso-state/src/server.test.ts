import { test } from "node:test";
import assert from "node:assert/strict";
import { Client as McpClient } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { createTestDb } from "./test-helpers.js";
import { createServer } from "./server.js";

async function connectedClient(dbClient: Awaited<ReturnType<typeof createTestDb>>["client"]) {
  const server = createServer(dbClient);
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  const mcpClient = new McpClient({ name: "test-client", version: "1.0.0" });
  await Promise.all([mcpClient.connect(clientTransport), server.connect(serverTransport)]);
  return mcpClient;
}

function textOf(result: { content: Array<{ type: string; text?: string }> }): string {
  const block = result.content[0];
  if (!block || block.type !== "text" || block.text === undefined) {
    throw new Error("Expected a text content block");
  }
  return block.text;
}

test("add_story then get_story round-trips via the MCP tool interface", async () => {
  const { client: dbClient } = await createTestDb();
  const mcpClient = await connectedClient(dbClient);

  await mcpClient.callTool({
    name: "add_story",
    arguments: {
      id: "STORY-001",
      title: "Comparison API",
      ticket_id: "JIRA-101",
      acceptance_criteria: ["returns quotes"],
      context_mode: "independent",
    },
  });

  const result = await mcpClient.callTool({ name: "get_story", arguments: { story_id: "STORY-001" } });
  const story = JSON.parse(textOf(result as any));
  assert.equal(story.title, "Comparison API");
});

test("get_story returns an error result for an unknown id, not a thrown exception", async () => {
  const { client: dbClient } = await createTestDb();
  const mcpClient = await connectedClient(dbClient);

  const result: any = await mcpClient.callTool({ name: "get_story", arguments: { story_id: "STORY-999" } });
  assert.equal(result.isError, true);
});

test("append_decision via MCP returns the assigned DEC-#### id", async () => {
  const { client: dbClient } = await createTestDb();
  const mcpClient = await connectedClient(dbClient);

  const result = await mcpClient.callTool({
    name: "append_decision",
    arguments: { date: "2026-09-11", story_id: "STORY-001", decision: "Use Turso" },
  });
  const decision = JSON.parse(textOf(result as any));
  assert.equal(decision.id, "DEC-0001");
});

test("add_story via MCP surfaces a duplicate id as an error result", async () => {
  const { client: dbClient } = await createTestDb();
  const mcpClient = await connectedClient(dbClient);

  const args = {
    id: "STORY-001",
    title: "First",
    ticket_id: "JIRA-1",
    acceptance_criteria: ["a"],
    context_mode: "independent",
  };
  await mcpClient.callTool({ name: "add_story", arguments: args });
  const result: any = await mcpClient.callTool({ name: "add_story", arguments: args });
  assert.equal(result.isError, true);
});
