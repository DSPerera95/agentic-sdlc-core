import { mkdtempSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import type { Backlog, Decision } from "./tools.js";
import { createDbClient } from "./db.js";
import { getBacklog, listDecisions } from "./tools.js";

export interface StoryBacklogJson {
  project: string;
  program_spec_ref?: string;
  architecture_mode: boolean;
  stories: Array<{
    id: string;
    title: string;
    ticket_id: string;
    acceptance_criteria: string[];
    context_mode: string;
    depends_on?: string[];
  }>;
}

export function formatStoryBacklogJson(backlog: Backlog): StoryBacklogJson {
  if (!backlog.meta) {
    throw new Error("Cannot export: backlog_meta has not been set yet");
  }
  return {
    project: backlog.meta.project,
    program_spec_ref: backlog.meta.program_spec_ref,
    architecture_mode: backlog.meta.architecture_mode,
    stories: backlog.stories.map((s) => ({
      id: s.id,
      title: s.title,
      ticket_id: s.ticket_id,
      acceptance_criteria: s.acceptance_criteria,
      context_mode: s.context_mode,
      depends_on: s.depends_on,
    })),
  };
}

export function formatDecisionLogJsonl(decisions: Decision[]): string {
  if (decisions.length === 0) return "";
  return (
    decisions
      .map((d) =>
        JSON.stringify({
          id: d.id,
          date: d.date,
          story_id: d.story_id,
          significance: d.significance,
          context: d.context,
          decision: d.decision,
          reasoning: d.reasoning,
          alternatives_considered: d.alternatives_considered,
          consequences: d.consequences,
          tradeoffs: d.tradeoffs,
        })
      )
      .join("\n") + "\n"
  );
}

async function main() {
  const databaseUrl = process.env.TURSO_DATABASE_URL;
  const authToken = process.env.TURSO_AUTH_TOKEN;
  if (!databaseUrl) {
    throw new Error("TURSO_DATABASE_URL environment variable is required");
  }

  const client = createDbClient(databaseUrl, authToken);
  const backlog = await getBacklog(client);
  const decisions = await listDecisions(client);

  const storyBacklogJson = JSON.stringify(formatStoryBacklogJson(backlog), null, 2) + "\n";
  const decisionLogJsonl = formatDecisionLogJsonl(decisions);

  // The claude-state-export branch must already exist (created once, manually,
  // as part of provisioning) - this script does not create it.
  const worktreeDir = mkdtempSync(join(tmpdir(), "claude-state-export-"));
  execFileSync("git", ["worktree", "add", worktreeDir, "claude-state-export"], { stdio: "inherit" });
  try {
    const stateDir = join(worktreeDir, ".claude", "state");
    mkdirSync(stateDir, { recursive: true });
    writeFileSync(join(stateDir, "story-backlog.json"), storyBacklogJson);
    writeFileSync(join(stateDir, "decision-log.jsonl"), decisionLogJsonl);

    execFileSync(
      "git",
      ["-C", worktreeDir, "add", ".claude/state/story-backlog.json", ".claude/state/decision-log.jsonl"],
      { stdio: "inherit" }
    );
    execFileSync("git", ["-C", worktreeDir, "commit", "-m", "chore: export state from Turso"], {
      stdio: "inherit",
    });
    execFileSync("git", ["-C", worktreeDir, "push", "origin", "claude-state-export"], { stdio: "inherit" });
  } finally {
    execFileSync("git", ["worktree", "remove", worktreeDir, "--force"]);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
