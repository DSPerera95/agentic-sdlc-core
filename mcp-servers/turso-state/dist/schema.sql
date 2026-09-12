CREATE TABLE backlog_meta (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  project TEXT NOT NULL,
  program_spec_ref TEXT,
  architecture_mode INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE stories (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  ticket_id TEXT NOT NULL,
  acceptance_criteria TEXT NOT NULL,
  context_mode TEXT NOT NULL,
  depends_on TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE decisions (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  date TEXT NOT NULL,
  story_id TEXT NOT NULL,
  significance TEXT NOT NULL DEFAULT 'routine',
  context TEXT,
  decision TEXT NOT NULL,
  reasoning TEXT,
  alternatives_considered TEXT,
  consequences TEXT,
  tradeoffs TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
