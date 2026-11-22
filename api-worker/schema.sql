-- PoppyCoop friends database (Cloudflare D1). Apply once:
--   npx wrangler d1 execute poppycoop --remote --file=schema.sql
CREATE TABLE IF NOT EXISTS accounts (
  id          TEXT PRIMARY KEY,            -- random, made by the launcher (16 hex)
  secret_hash TEXT NOT NULL,               -- SHA-256 of the launcher's secret (the secret never leaves the PC otherwise)
  name        TEXT NOT NULL,
  name_lc     TEXT NOT NULL,
  tag         TEXT NOT NULL,               -- 5 digits: friend code = name#tag
  created     INTEGER NOT NULL,
  last_seen   INTEGER NOT NULL,
  chapter     INTEGER NOT NULL DEFAULT 0,  -- what the player is doing (shown to friends only)
  room        TEXT NOT NULL DEFAULT '',
  ingame      INTEGER NOT NULL DEFAULT 0,
  UNIQUE (name_lc, tag)
);
CREATE TABLE IF NOT EXISTS friends (
  a     TEXT NOT NULL,                     -- stored both ways (a,b) and (b,a)
  b     TEXT NOT NULL,
  since INTEGER NOT NULL,
  PRIMARY KEY (a, b)
);
CREATE TABLE IF NOT EXISTS requests (
  from_id TEXT NOT NULL,
  to_id   TEXT NOT NULL,
  created INTEGER NOT NULL,
  PRIMARY KEY (from_id, to_id)
);
CREATE INDEX IF NOT EXISTS requests_to ON requests (to_id);
