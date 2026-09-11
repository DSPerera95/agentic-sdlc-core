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
