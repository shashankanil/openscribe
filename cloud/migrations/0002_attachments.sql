-- Screenshots and meeting recordings. The bytes live in R2 (binding MEDIA) at `r2_key`
-- = u/{user_id}/{document_id}/{id}; this table holds metadata and drives quota and listing.
CREATE TABLE attachments (
  user_id          TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  document_id      TEXT NOT NULL,
  id               TEXT NOT NULL,
  kind             TEXT NOT NULL CHECK (kind IN ('screenshot', 'recording')),
  content_type     TEXT NOT NULL,
  bytes            INTEGER NOT NULL,
  sha256           TEXT NOT NULL,            -- lowercase hex
  r2_key           TEXT NOT NULL,
  created_at       INTEGER NOT NULL,
  duration_seconds REAL NOT NULL DEFAULT 0,
  caption          TEXT NOT NULL DEFAULT '',
  uploaded_at      INTEGER NOT NULL,
  UNIQUE (user_id, document_id, id)
);
CREATE INDEX attachments_user_document ON attachments(user_id, document_id);
