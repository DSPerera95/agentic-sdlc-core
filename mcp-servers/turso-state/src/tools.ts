import type { Client } from "@libsql/client";

export interface Story {
  id: string;
  title: string;
  ticket_id: string;
  acceptance_criteria: string[];
  context_mode: "full-spec" | "decision-log-only" | "independent";
  depends_on?: string[];
}

export interface BacklogMeta {
  project: string;
  program_spec_ref?: string;
  architecture_mode: boolean;
}

export interface Backlog {
  meta: BacklogMeta | null;
  stories: Story[];
}

export class DuplicateStoryIdError extends Error {
  constructor(id: string) {
    super(`Story id already exists: ${id}`);
    this.name = "DuplicateStoryIdError";
  }
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function rowToStory(row: any): Story {
  return {
    id: String(row.id),
    title: String(row.title),
    ticket_id: String(row.ticket_id),
    acceptance_criteria: JSON.parse(String(row.acceptance_criteria)),
    context_mode: String(row.context_mode) as Story["context_mode"],
    depends_on: row.depends_on ? JSON.parse(String(row.depends_on)) : undefined,
  };
}

export async function getBacklog(client: Client): Promise<Backlog> {
  const metaResult = await client.execute(
    "SELECT project, program_spec_ref, architecture_mode FROM backlog_meta WHERE id = 1"
  );
  const storiesResult = await client.execute(
    "SELECT id, title, ticket_id, acceptance_criteria, context_mode, depends_on FROM stories ORDER BY id"
  );

  const metaRow = metaResult.rows[0];
  const meta: BacklogMeta | null = metaRow
    ? {
        project: String(metaRow.project),
        program_spec_ref: metaRow.program_spec_ref ? String(metaRow.program_spec_ref) : undefined,
        architecture_mode: Boolean(metaRow.architecture_mode),
      }
    : null;

  return { meta, stories: storiesResult.rows.map(rowToStory) };
}

export async function getStory(client: Client, storyId: string): Promise<Story | null> {
  const result = await client.execute({
    sql: "SELECT id, title, ticket_id, acceptance_criteria, context_mode, depends_on FROM stories WHERE id = ?",
    args: [storyId],
  });
  if (result.rows.length === 0) return null;
  return rowToStory(result.rows[0]);
}

export async function setBacklogMeta(client: Client, meta: BacklogMeta): Promise<void> {
  await client.execute({
    sql: `INSERT INTO backlog_meta (id, project, program_spec_ref, architecture_mode)
          VALUES (1, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET project = excluded.project,
            program_spec_ref = excluded.program_spec_ref,
            architecture_mode = excluded.architecture_mode`,
    args: [meta.project, meta.program_spec_ref ?? null, meta.architecture_mode ? 1 : 0],
  });
}

export async function addStory(client: Client, story: Story): Promise<void> {
  const existing = await getStory(client, story.id);
  if (existing) {
    throw new DuplicateStoryIdError(story.id);
  }
  await client.execute({
    sql: `INSERT INTO stories (id, title, ticket_id, acceptance_criteria, context_mode, depends_on)
          VALUES (?, ?, ?, ?, ?, ?)`,
    args: [
      story.id,
      story.title,
      story.ticket_id,
      JSON.stringify(story.acceptance_criteria),
      story.context_mode,
      story.depends_on ? JSON.stringify(story.depends_on) : null,
    ],
  });
}

export interface DecisionInput {
  date: string;
  story_id: string;
  significance?: "architectural" | "routine";
  context?: string;
  decision: string;
  reasoning?: string;
  alternatives_considered?: string[];
  consequences?: string;
  tradeoffs?: string;
}

export interface Decision extends DecisionInput {
  id: string;
  seq: number;
  significance: "architectural" | "routine";
  created_at: string;
}

function formatDecisionId(seq: number): string {
  return `DEC-${String(seq).padStart(4, "0")}`;
}

export async function appendDecision(client: Client, input: DecisionInput): Promise<Decision> {
  const significance = input.significance ?? "routine";
  const result = await client.execute({
    sql: `INSERT INTO decisions (date, story_id, significance, context, decision, reasoning, alternatives_considered, consequences, tradeoffs)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          RETURNING seq, created_at`,
    args: [
      input.date,
      input.story_id,
      significance,
      input.context ?? null,
      input.decision,
      input.reasoning ?? null,
      input.alternatives_considered ? JSON.stringify(input.alternatives_considered) : null,
      input.consequences ?? null,
      input.tradeoffs ?? null,
    ],
  });
  const row = result.rows[0];
  const seq = Number(row.seq);
  return {
    id: formatDecisionId(seq),
    seq,
    date: input.date,
    story_id: input.story_id,
    significance,
    context: input.context,
    decision: input.decision,
    reasoning: input.reasoning,
    alternatives_considered: input.alternatives_considered,
    consequences: input.consequences,
    tradeoffs: input.tradeoffs,
    created_at: String(row.created_at),
  };
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function rowToDecision(row: any): Decision {
  const seq = Number(row.seq);
  return {
    id: formatDecisionId(seq),
    seq,
    date: String(row.date),
    story_id: String(row.story_id),
    significance: String(row.significance) as Decision["significance"],
    context: row.context ? String(row.context) : undefined,
    decision: String(row.decision),
    reasoning: row.reasoning ? String(row.reasoning) : undefined,
    alternatives_considered: row.alternatives_considered
      ? JSON.parse(String(row.alternatives_considered))
      : undefined,
    consequences: row.consequences ? String(row.consequences) : undefined,
    tradeoffs: row.tradeoffs ? String(row.tradeoffs) : undefined,
    created_at: String(row.created_at),
  };
}

export async function listDecisions(
  client: Client,
  opts: { story_id?: string; since?: string; limit?: number } = {}
): Promise<Decision[]> {
  const conditions: string[] = [];
  const args: unknown[] = [];
  if (opts.story_id) {
    conditions.push("story_id = ?");
    args.push(opts.story_id);
  }
  if (opts.since) {
    conditions.push("created_at >= ?");
    args.push(opts.since);
  }
  const where = conditions.length ? `WHERE ${conditions.join(" AND ")}` : "";
  const limitClause = opts.limit ? `LIMIT ${Number(opts.limit)}` : "";
  const result = await client.execute({
    sql: `SELECT seq, date, story_id, significance, context, decision, reasoning, alternatives_considered, consequences, tradeoffs, created_at
          FROM decisions ${where} ORDER BY seq ${limitClause}`,
    args,
  });
  return result.rows.map(rowToDecision);
}
