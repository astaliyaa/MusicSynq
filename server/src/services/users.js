import {
  DUMMY_PASSWORD_HASH,
  hashPassword,
  hashToken,
  newId,
  newSessionToken,
  verifyPassword,
} from "../crypto.js";
import { conflict, unauthorized } from "../errors.js";

/** The shape every other user sees. Never includes credentials. */
export const publicUser = (row) => ({ id: row.id, username: row.username, displayName: row.display_name });

// Touching last_used_at on every request would mean a write per API call.
const SESSION_TOUCH_INTERVAL_MS = 60 * 60 * 1000;

export class UserService {
  constructor(ctx) {
    this.ctx = ctx;
  }

  get db() {
    return this.ctx.db;
  }

  get(id) {
    return this.db.prepare("SELECT * FROM users WHERE id = ?").get(id) ?? null;
  }

  getByUsername(username) {
    return this.db.prepare("SELECT * FROM users WHERE username = ?").get(username.toLowerCase()) ?? null;
  }

  async register({ username, displayName, password }) {
    const normalized = username.toLowerCase();
    if (this.getByUsername(normalized)) throw conflict("username_taken", "That username is already taken.");
    const passwordHash = await hashPassword(password);
    const user = {
      id: newId(),
      username: normalized,
      display_name: displayName,
      password_hash: passwordHash,
      created_at: Date.now(),
    };
    try {
      this.db
        .prepare(
          `INSERT INTO users (id, username, display_name, password_hash, created_at)
           VALUES (@id, @username, @display_name, @password_hash, @created_at)`,
        )
        .run(user);
    } catch (err) {
      // Two sign-ups racing for the same name: the UNIQUE constraint decides.
      if (err.code === "SQLITE_CONSTRAINT_UNIQUE") throw conflict("username_taken", "That username is already taken.");
      throw err;
    }
    return user;
  }

  /** Returns the user row, or throws a 401 that doesn't reveal which half was wrong. */
  async authenticate(username, password) {
    const user = this.getByUsername(username);
    const ok = await verifyPassword(password, user?.password_hash ?? DUMMY_PASSWORD_HASH);
    if (!user || !ok) throw unauthorized("Wrong username or password.");
    return user;
  }

  async checkPassword(user, password) {
    if (!(await verifyPassword(password, user.password_hash))) throw unauthorized("Wrong password.");
  }

  createSession(userId) {
    const token = newSessionToken();
    const now = Date.now();
    this.db
      .prepare("INSERT INTO sessions (token_hash, user_id, created_at, last_used_at) VALUES (?, ?, ?, ?)")
      .run(hashToken(token), userId, now, now);
    return token;
  }

  userForToken(token) {
    if (!token) return null;
    const tokenHash = hashToken(token);
    const row = this.db
      .prepare(
        `SELECT u.*, s.last_used_at AS session_last_used_at
         FROM sessions s JOIN users u ON u.id = s.user_id
         WHERE s.token_hash = ?`,
      )
      .get(tokenHash);
    if (!row) return null;
    const now = Date.now();
    if (now - row.session_last_used_at > SESSION_TOUCH_INTERVAL_MS) {
      this.db.prepare("UPDATE sessions SET last_used_at = ? WHERE token_hash = ?").run(now, tokenHash);
    }
    delete row.session_last_used_at;
    return row;
  }

  deleteSession(token) {
    this.db.prepare("DELETE FROM sessions WHERE token_hash = ?").run(hashToken(token));
  }

  updateDisplayName(userId, displayName) {
    this.db.prepare("UPDATE users SET display_name = ? WHERE id = ?").run(displayName, userId);
    return this.get(userId);
  }

  /** Prefix search on username, plus how each result relates to the viewer. */
  search(viewerId, query, limit = 20) {
    const prefix = query.toLowerCase().replace(/[%_\\]/g, (c) => `\\${c}`);
    const rows = this.db
      .prepare(
        `SELECT * FROM users
         WHERE username LIKE ? ESCAPE '\\' AND id != ?
         ORDER BY length(username), username
         LIMIT ?`,
      )
      .all(`${prefix}%`, viewerId, limit);
    const friends = this.ctx.friends;
    return rows.map((row) => ({ user: publicUser(row), ...friends.relationship(viewerId, row.id) }));
  }

  /** Deletes the account and everything hanging off it (sessions, friendships, devices, parties). */
  delete(userId) {
    this.db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  }
}
