-- OpenScribe Cloud schema. All timestamps are Unix epoch milliseconds (INTEGER).

-- One row per Google account, keyed by the Google `sub` claim.
CREATE TABLE users (
  id           TEXT PRIMARY KEY,           -- Google `sub`
  email        TEXT NOT NULL DEFAULT '',
  name         TEXT NOT NULL DEFAULT '',
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL,
  last_sync_at INTEGER
);

-- Desktop-app tokens. Only the SHA-256 (hex) of the opaque token is stored.
CREATE TABLE app_tokens (
  token_hash   TEXT PRIMARY KEY,
  user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at   INTEGER NOT NULL,
  last_used_at INTEGER,
  revoked_at   INTEGER
);
CREATE INDEX app_tokens_user ON app_tokens(user_id);

-- Normalized documents (see docs/CONTEXT-API.md). `pk` backs the FTS index.
CREATE TABLE documents (
  pk               INTEGER PRIMARY KEY,
  user_id          TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  id               TEXT NOT NULL,
  kind             TEXT NOT NULL CHECK (kind IN ('note', 'meeting')),
  title            TEXT NOT NULL DEFAULT '',
  created_at       INTEGER NOT NULL,
  updated_at       INTEGER NOT NULL,
  deleted          INTEGER NOT NULL DEFAULT 0,
  body             TEXT NOT NULL DEFAULT '',
  summary          TEXT,
  transcript       TEXT,
  action_items     TEXT NOT NULL DEFAULT '[]',  -- JSON array of strings
  duration_seconds REAL NOT NULL DEFAULT 0,
  tags             TEXT NOT NULL DEFAULT '[]',  -- JSON array of strings
  synced_at        INTEGER NOT NULL,
  UNIQUE (user_id, id)
);
CREATE INDEX documents_user_updated ON documents(user_id, deleted, updated_at DESC);
CREATE INDEX documents_user_kind_created ON documents(user_id, kind, deleted, created_at DESC);

-- Full-text index over document content (external content table, kept in sync by triggers).
CREATE VIRTUAL TABLE documents_fts USING fts5(
  title, body, summary, transcript, tags, action_items,
  content = 'documents',
  content_rowid = 'pk',
  tokenize = 'porter unicode61 remove_diacritics 2'
);

CREATE TRIGGER documents_ai AFTER INSERT ON documents BEGIN
  INSERT INTO documents_fts (rowid, title, body, summary, transcript, tags, action_items)
  VALUES (new.pk, new.title, new.body, new.summary, new.transcript, new.tags, new.action_items);
END;

CREATE TRIGGER documents_ad AFTER DELETE ON documents BEGIN
  INSERT INTO documents_fts (documents_fts, rowid, title, body, summary, transcript, tags, action_items)
  VALUES ('delete', old.pk, old.title, old.body, old.summary, old.transcript, old.tags, old.action_items);
END;

CREATE TRIGGER documents_au AFTER UPDATE ON documents BEGIN
  INSERT INTO documents_fts (documents_fts, rowid, title, body, summary, transcript, tags, action_items)
  VALUES ('delete', old.pk, old.title, old.body, old.summary, old.transcript, old.tags, old.action_items);
  INSERT INTO documents_fts (rowid, title, body, summary, transcript, tags, action_items)
  VALUES (new.pk, new.title, new.body, new.summary, new.transcript, new.tags, new.action_items);
END;
