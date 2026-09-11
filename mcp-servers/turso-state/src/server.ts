import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import type { Client } from "@libsql/client";
import {
  getBacklog,
  getStory,
  setBacklogMeta,
  addStory,
  appendDecision,
  listDecisions,
  DuplicateStoryIdError,
} from "./tools.js";

export function createServer(client: Client): McpServer {
  const server = new McpServer({ name: "turso-state", version: "1.0.0" });

  server.tool("get_backlog", "Returns backlog metadata and all stories", {}, async () => {
    const backlog = await getBacklog(client);
    return { content: [{ type: "text", text: JSON.stringify(backlog) }] };
  });

  server.tool(
    "get_story",
    "Returns a single story by id",
    { story_id: z.string() },
    async ({ story_id }) => {
      const story = await getStory(client, story_id);
      if (!story) {
        return {
          content: [{ type: "text", text: `No story found with id ${story_id}` }],
          isError: true,
        };
      }
      return { content: [{ type: "text", text: JSON.stringify(story) }] };
    }
  );

  server.tool(
    "set_backlog_meta",
    "Upserts the single backlog metadata row (project, program_spec_ref, architecture_mode)",
    {
      project: z.string(),
      program_spec_ref: z.string().optional(),
      architecture_mode: z.boolean(),
    },
    async ({ project, program_spec_ref, architecture_mode }) => {
      await setBacklogMeta(client, { project, program_spec_ref, architecture_mode });
      return { content: [{ type: "text", text: "ok" }] };
    }
  );

  server.tool(
    "add_story",
    "Inserts one story; errors if the id already exists",
    {
      id: z.string(),
      title: z.string(),
      ticket_id: z.string(),
      acceptance_criteria: z.array(z.string()),
      context_mode: z.enum(["full-spec", "decision-log-only", "independent"]),
      depends_on: z.array(z.string()).optional(),
    },
    async (story) => {
      try {
        await addStory(client, story);
        return { content: [{ type: "text", text: "ok" }] };
      } catch (err) {
        if (err instanceof DuplicateStoryIdError) {
          return { content: [{ type: "text", text: err.message }], isError: true };
        }
        throw err;
      }
    }
  );

  server.tool(
    "append_decision",
    "Inserts one decision log entry, returns its formatted DEC-#### id",
    {
      date: z.string(),
      story_id: z.string(),
      significance: z.enum(["architectural", "routine"]).optional(),
      context: z.string().optional(),
      decision: z.string(),
      reasoning: z.string().optional(),
      alternatives_considered: z.array(z.string()).optional(),
      consequences: z.string().optional(),
      tradeoffs: z.string().optional(),
    },
    async (input) => {
      const result = await appendDecision(client, input);
      return { content: [{ type: "text", text: JSON.stringify(result) }] };
    }
  );

  server.tool(
    "list_decisions",
    "Returns decision log entries, optionally filtered by story_id/since, ordered oldest first",
    {
      story_id: z.string().optional(),
      since: z.string().optional(),
      limit: z.number().optional(),
    },
    async (opts) => {
      const decisions = await listDecisions(client, opts);
      return { content: [{ type: "text", text: JSON.stringify(decisions) }] };
    }
  );

  return server;
}
