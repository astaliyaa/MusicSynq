import { newId } from "../crypto.js";
import { badRequest, conflict, forbidden, notFound } from "../errors.js";
import { publicUser } from "./users.js";

const orderedPair = (a, b) => (a < b ? [a, b] : [b, a]);

export class FriendService {
  constructor(ctx) {
    this.ctx = ctx;
  }

  get db() {
    return this.ctx.db;
  }

  areFriends(a, b) {
    const [x, y] = orderedPair(a, b);
    return !!this.db.prepare("SELECT 1 FROM friendships WHERE user_a = ? AND user_b = ?").get(x, y);
  }

  friendIds(userId) {
    return this.db
      .prepare(
        `SELECT user_b AS id FROM friendships WHERE user_a = ?
         UNION
         SELECT user_a AS id FROM friendships WHERE user_b = ?`,
      )
      .all(userId, userId)
      .map((r) => r.id);
  }

  /** How `otherId` relates to `viewerId`: none, friend, incoming or outgoing request. */
  relationship(viewerId, otherId) {
    if (this.areFriends(viewerId, otherId)) return { relationship: "friend", requestId: null };
    const outgoing = this.db
      .prepare("SELECT id FROM friend_requests WHERE from_user = ? AND to_user = ?")
      .get(viewerId, otherId);
    if (outgoing) return { relationship: "outgoing", requestId: outgoing.id };
    const incoming = this.db
      .prepare("SELECT id FROM friend_requests WHERE from_user = ? AND to_user = ?")
      .get(otherId, viewerId);
    if (incoming) return { relationship: "incoming", requestId: incoming.id };
    return { relationship: "none", requestId: null };
  }

  list(userId) {
    const users = this.ctx.users;
    const parties = this.ctx.parties;
    const hub = this.ctx.hub;
    const friends = this.friendIds(userId)
      .map((id) => users.get(id))
      .filter(Boolean)
      .sort((a, b) => a.display_name.localeCompare(b.display_name))
      .map((row) => {
        const party = parties.activeHostedBy(row.id);
        return {
          user: publicUser(row),
          online: hub.isOnline(row.id),
          party: party ? parties.summary(party, userId) : null,
        };
      });
    const requestRows = (column, value) =>
      this.db
        .prepare(`SELECT * FROM friend_requests WHERE ${column} = ? ORDER BY created_at DESC`)
        .all(value)
        .map((r) => this.serializeRequest(r));
    return {
      friends,
      incoming: requestRows("to_user", userId),
      outgoing: requestRows("from_user", userId),
    };
  }

  serializeRequest(row) {
    const users = this.ctx.users;
    return {
      id: row.id,
      from: publicUser(users.get(row.from_user)),
      to: publicUser(users.get(row.to_user)),
      createdAt: row.created_at,
    };
  }

  /**
   * Sends a friend request to `username`. If they already asked us, this
   * accepts their request instead, since both sides clearly want it.
   */
  sendRequest(fromUser, username) {
    const target = this.ctx.users.getByUsername(username);
    if (!target) throw notFound("user_not_found", `No one is called @${username}.`);
    if (target.id === fromUser.id) throw badRequest("cannot_friend_self", "You can't add yourself.");
    if (this.areFriends(fromUser.id, target.id)) throw conflict("already_friends", "You're already friends.");

    const reverse = this.db
      .prepare("SELECT * FROM friend_requests WHERE from_user = ? AND to_user = ?")
      .get(target.id, fromUser.id);
    if (reverse) {
      this.accept(fromUser, reverse.id);
      return { status: "accepted", request: null };
    }

    const existing = this.db
      .prepare("SELECT * FROM friend_requests WHERE from_user = ? AND to_user = ?")
      .get(fromUser.id, target.id);
    if (existing) return { status: "requested", request: this.serializeRequest(existing) };

    const row = { id: newId(), from_user: fromUser.id, to_user: target.id, created_at: Date.now() };
    this.db
      .prepare("INSERT INTO friend_requests (id, from_user, to_user, created_at) VALUES (@id, @from_user, @to_user, @created_at)")
      .run(row);

    this.ctx.hub.sendToUser(target.id, { type: "friends.changed", reason: "request_received", user: publicUser(fromUser) });
    this.ctx.notifier.notify([target.id], {
      title: "New friend request",
      body: `${fromUser.display_name} (@${fromUser.username}) wants to be friends.`,
      data: { type: "friend_request", requestId: row.id },
    });
    return { status: "requested", request: this.serializeRequest(row) };
  }

  accept(user, requestId) {
    const request = this.db.prepare("SELECT * FROM friend_requests WHERE id = ?").get(requestId);
    if (!request) throw notFound("request_not_found", "That friend request no longer exists.");
    if (request.to_user !== user.id) throw forbidden("not_your_request", "Only the person invited can accept.");

    const [a, b] = orderedPair(request.from_user, request.to_user);
    this.db.transaction(() => {
      this.db.prepare("INSERT OR IGNORE INTO friendships (user_a, user_b, created_at) VALUES (?, ?, ?)").run(a, b, Date.now());
      // Clear requests in both directions.
      this.db
        .prepare("DELETE FROM friend_requests WHERE (from_user = ? AND to_user = ?) OR (from_user = ? AND to_user = ?)")
        .run(a, b, b, a);
    })();

    this.ctx.hub.sendToUser(request.from_user, { type: "friends.changed", reason: "request_accepted", user: publicUser(user) });
    this.ctx.hub.sendToUser(user.id, { type: "friends.changed", reason: "friend_added" });
    this.ctx.notifier.notify([request.from_user], {
      title: "Friend request accepted",
      body: `You and ${user.display_name} are now friends.`,
      data: { type: "friend_accepted", userId: user.id },
    });
  }

  /** Declines an incoming request, or cancels an outgoing one. */
  removeRequest(user, requestId) {
    const request = this.db.prepare("SELECT * FROM friend_requests WHERE id = ?").get(requestId);
    if (!request) throw notFound("request_not_found", "That friend request no longer exists.");
    if (request.to_user !== user.id && request.from_user !== user.id) {
      throw forbidden("not_your_request", "That isn't your friend request.");
    }
    this.db.prepare("DELETE FROM friend_requests WHERE id = ?").run(requestId);
    const other = request.to_user === user.id ? request.from_user : request.to_user;
    this.ctx.hub.sendToUser(other, { type: "friends.changed", reason: "request_removed" });
  }

  remove(user, friendId) {
    if (!this.areFriends(user.id, friendId)) throw notFound("not_friends", "You aren't friends with that person.");
    const [a, b] = orderedPair(user.id, friendId);
    this.db.prepare("DELETE FROM friendships WHERE user_a = ? AND user_b = ?").run(a, b);
    // Parties are friends-only, so an unfriend also ends any listening the two share.
    this.ctx.parties.separate(user.id, friendId);
    this.ctx.hub.sendToUser(friendId, { type: "friends.changed", reason: "friend_removed" });
  }
}
