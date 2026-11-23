-- Phone Link: tokens the Mac mints for its paired phones (see docs/PHONE-LINK.md).
-- Only the SHA-256 (hex) of the opaque `oslp_` token is stored. `device_id` is the Mac's
-- pairing slot id; minting again for the same (user_id, device_id) revokes the previous token.
CREATE TABLE link_devices (
  token_hash   TEXT PRIMARY KEY,
  user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id    TEXT NOT NULL,
  name         TEXT NOT NULL DEFAULT '',
  created_at   INTEGER NOT NULL,
  last_used_at INTEGER,
  revoked_at   INTEGER
);
CREATE INDEX link_devices_user_device ON link_devices(user_id, device_id);
