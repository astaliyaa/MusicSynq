import Database from "better-sqlite3";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";

/**
 * Each entry is applied once, in order. Never edit an entry that has shipped;
 * append a new one instead.
 */
const MIGRATIONS = [
  `
  CREATE TABLE users (
    id            TEXT PRIMARY KEY,
    username      TEXT NOT NULL UNIQUE,
    display_name  TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    created_at    INTEGER NOT NULL
  );

  CREATE TABLE sessions (
    token_hash   TEXT PRIMARY KEY,
    user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at   INTEGER NOT NULL,
    last_used_at INTEGER NOT NULL
  );
  CREATE INDEX sessions_user ON sessions(user_id);

  -- One row per friendship, stored with user_a < user_b.
  CREATE TABLE friendships (
    user_a     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    user_b     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at INTEGER NOT NULL,
    PRIMARY KEY (user_a, user_b),
    CHECK (user_a < user_b)
  );
  CREATE INDEX friendships_b ON friendships(user_b);

  CREATE TABLE friend_requests (
    id         TEXT PRIMARY KEY,
    from_user  TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    to_user    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at INTEGER NOT NULL,
    UNIQUE (from_user, to_user)
  );
  CREATE INDEX friend_requests_to ON friend_requests(to_user);

  CREATE TABLE devices (
    token       TEXT PRIMARY KEY,
    user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    environment TEXT NOT NULL CHECK (environment IN ('sandbox', 'production')),
    updated_at  INTEGER NOT NULL
  );
  CREATE INDEX devices_user ON devices(user_id);

  CREATE TABLE parties (
    id                  TEXT PRIMARY KEY,
    host_id             TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    code                TEXT NOT NULL,
    status              TEXT NOT NULL CHECK (status IN ('active', 'ended')),
    allow_guest_control INTEGER NOT NULL DEFAULT 1,
    created_at          INTEGER NOT NULL,
    ended_at            INTEGER
  );
  CREATE INDEX parties_host_status ON parties(host_id, status);

  CREATE TABLE party_members (
    party_id  TEXT NOT NULL REFERENCES parties(id) ON DELETE CASCADE,
    user_id   TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    joined_at INTEGER NOT NULL,
    left_at   INTEGER,
    PRIMARY KEY (party_id, user_id)
  );
  CREATE INDEX party_members_user ON party_members(user_id, left_at);

  CREATE TABLE join_requests (
    id          TEXT PRIMARY KEY,
    party_id    TEXT NOT NULL REFERENCES parties(id) ON DELETE CASCADE,
    user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status      TEXT NOT NULL CHECK (status IN ('pending', 'approved', 'declined', 'cancelled')),
    created_at  INTEGER NOT NULL,
    resolved_at INTEGER
  );
  CREATE INDEX join_requests_party ON join_requests(party_id, status);
  `,
];

export function openDatabase(path) {
  if (path !== ":memory:") mkdirSync(dirname(path), { recursive: true });
  const db = new Database(path);
  db.pragma("journal_mode = WAL");
  db.pragma("foreign_keys = ON");
  db.pragma("busy_timeout = 5000");
  migrate(db);
  return db;
}

function migrate(db) {
  const current = db.pragma("user_version", { simple: true });
  for (let version = current; version < MIGRATIONS.length; version++) {
    db.transaction(() => {
      db.exec(MIGRATIONS[version]);
      db.pragma(`user_version = ${version + 1}`);
    })();
  }
}
