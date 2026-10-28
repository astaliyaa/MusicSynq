import { newId, newPartyCode, normalizePartyCode } from "../crypto.js";
import { badRequest, conflict, forbidden, notFound } from "../errors.js";
import { RateLimiter } from "../rateLimit.js";
import { publicUser } from "./users.js";

// Hosts stamp each report with their estimate of server time. Anything further
// off than this is a broken clock, so we fall back to the time we received it.
const MAX_TIMESTAMP_SKEW_MS = 10_000;

export class PartyService {
  constructor(ctx) {
    this.ctx = ctx;
    /** partyId -> latest playback state reported by the host. Lives in memory only. */
    this.playback = new Map();
    this.codeAttempts = new RateLimiter({ limit: 10, windowMs: 10 * 60 * 1000 });
  }

  get db() {
    return this.ctx.db;
  }

  // ---------------------------------------------------------------- queries

  get(partyId) {
    return this.db.prepare("SELECT * FROM parties WHERE id = ?").get(partyId) ?? null;
  }

  getActive(partyId) {
    const party = this.get(partyId);
    if (!party || party.status !== "active") throw notFound("party_not_found", "That party has ended.");
    return party;
  }

  activeHostedBy(userId) {
    return this.db.prepare("SELECT * FROM parties WHERE host_id = ? AND status = 'active'").get(userId) ?? null;
  }

  /** The active party a user is in, as host or guest. A user is in at most one. */
  currentFor(userId) {
    return (
      this.activeHostedBy(userId) ??
      this.db
        .prepare(
          `SELECT p.* FROM parties p
           JOIN party_members m ON m.party_id = p.id
           WHERE m.user_id = ? AND m.left_at IS NULL AND p.status = 'active'`,
        )
        .get(userId) ??
      null
    );
  }

  guestIds(partyId) {
    return this.db
      .prepare("SELECT user_id FROM party_members WHERE party_id = ? AND left_at IS NULL ORDER BY joined_at")
      .all(partyId)
      .map((r) => r.user_id);
  }

  isGuest(partyId, userId) {
    return !!this.db
      .prepare("SELECT 1 FROM party_members WHERE party_id = ? AND user_id = ? AND left_at IS NULL")
      .get(partyId, userId);
  }

  /** Active parties hosted by the viewer's friends. */
  listForFriends(viewerId) {
    const friendIds = this.ctx.friends.friendIds(viewerId);
    if (friendIds.length === 0) return [];
    const placeholders = friendIds.map(() => "?").join(",");
    return this.db
      .prepare(`SELECT * FROM parties WHERE status = 'active' AND host_id IN (${placeholders}) ORDER BY created_at DESC`)
      .all(...friendIds)
      .map((party) => this.summary(party, viewerId));
  }

  // ---------------------------------------------------------- serialization

  serializeRequest(row) {
    return {
      id: row.id,
      partyId: row.party_id,
      user: publicUser(this.ctx.users.get(row.user_id)),
      status: row.status,
      createdAt: row.created_at,
    };
  }

  /** What a friend sees in their party list. Never includes the join code. */
  summary(party, viewerId) {
    const playback = this.playback.get(party.id) ?? null;
    const myRequest = this.db
      .prepare("SELECT * FROM join_requests WHERE party_id = ? AND user_id = ? AND status = 'pending'")
      .get(party.id, viewerId);
    return {
      id: party.id,
      host: publicUser(this.ctx.users.get(party.host_id)),
      memberCount: this.guestIds(party.id).length,
      createdAt: party.created_at,
      nowPlaying: playback?.track ?? null,
      isPlaying: playback?.isPlaying ?? false,
      myRequest: myRequest ? this.serializeRequest(myRequest) : null,
    };
  }

  /** The full party as one member sees it. Only the host gets the code and pending requests. */
  serializeFor(party, viewerId) {
    const isHost = party.host_id === viewerId;
    const users = this.ctx.users;
    const hub = this.ctx.hub;
    const members = this.db
      .prepare("SELECT * FROM party_members WHERE party_id = ? AND left_at IS NULL ORDER BY joined_at")
      .all(party.id)
      .map((m) => ({ user: publicUser(users.get(m.user_id)), joinedAt: m.joined_at, connected: hub.isOnline(m.user_id) }));
    const pendingRequests = isHost
      ? this.db
          .prepare("SELECT * FROM join_requests WHERE party_id = ? AND status = 'pending' ORDER BY created_at")
          .all(party.id)
          .map((r) => this.serializeRequest(r))
      : [];
    return {
      id: party.id,
      role: isHost ? "host" : "guest",
      code: isHost ? party.code : null,
      host: publicUser(users.get(party.host_id)),
      hostConnected: hub.isOnline(party.host_id),
      allowGuestControl: !!party.allow_guest_control,
      createdAt: party.created_at,
      members,
      pendingRequests,
      playback: this.playback.get(party.id) ?? null,
    };
  }

  /** Sends every member (host included) their own view of the party. */
  broadcastParty(partyId) {
    const party = this.get(partyId);
    if (!party || party.status !== "active") return;
    for (const userId of [party.host_id, ...this.guestIds(partyId)]) {
      this.ctx.hub.sendToUser(userId, { type: "party.updated", party: this.serializeFor(party, userId) });
    }
  }

  // ---------------------------------------------------------------- hosting

  start(host, { allowGuestControl = true } = {}) {
    const existing = this.activeHostedBy(host.id);
    if (existing) return existing;

    // Starting your own party takes you out of anyone else's.
    const current = this.currentFor(host.id);
    if (current) this.leave(host.id, current.id);

    const party = {
      id: newId(),
      host_id: host.id,
      code: this.uniqueCode(),
      status: "active",
      allow_guest_control: allowGuestControl ? 1 : 0,
      created_at: Date.now(),
    };
    this.db
      .prepare(
        `INSERT INTO parties (id, host_id, code, status, allow_guest_control, created_at)
         VALUES (@id, @host_id, @code, @status, @allow_guest_control, @created_at)`,
      )
      .run(party);

    const friendIds = this.ctx.friends.friendIds(host.id);
    this.ctx.hub.sendToUsers(friendIds, { type: "friends.changed", reason: "party_started", user: publicUser(host) });
    this.ctx.notifier.notify(friendIds, {
      title: `${host.display_name} started a listening party`,
      body: "Open MusicSynq to listen along.",
      data: { type: "party_started", partyId: party.id },
      threadId: `party-${party.id}`,
    });
    return this.get(party.id);
  }

  uniqueCode() {
    const taken = this.db.prepare("SELECT 1 FROM parties WHERE code = ? AND status = 'active'");
    for (;;) {
      const code = newPartyCode();
      if (!taken.get(code)) return code;
    }
  }

  update(hostId, partyId, { allowGuestControl }) {
    const party = this.requireHost(hostId, partyId);
    if (allowGuestControl !== undefined) {
      this.db.prepare("UPDATE parties SET allow_guest_control = ? WHERE id = ?").run(allowGuestControl ? 1 : 0, party.id);
    }
    this.broadcastParty(party.id);
    return this.get(party.id);
  }

  requireHost(userId, partyId) {
    const party = this.getActive(partyId);
    if (party.host_id !== userId) throw forbidden("not_host", "Only the host can do that.");
    return party;
  }

  /**
   * Ends a party for everyone. `reason` is one of host_ended, host_disconnected,
   * account_deleted; guests' apps stop playback when they receive it.
   */
  end(partyId, reason) {
    const party = this.get(partyId);
    if (!party || party.status !== "active") return;
    const now = Date.now();
    const guests = this.guestIds(partyId);
    const pending = this.db.prepare("SELECT * FROM join_requests WHERE party_id = ? AND status = 'pending'").all(partyId);

    this.db.transaction(() => {
      this.db.prepare("UPDATE parties SET status = 'ended', ended_at = ? WHERE id = ?").run(now, partyId);
      this.db.prepare("UPDATE party_members SET left_at = ? WHERE party_id = ? AND left_at IS NULL").run(now, partyId);
      this.db
        .prepare("UPDATE join_requests SET status = 'cancelled', resolved_at = ? WHERE party_id = ? AND status = 'pending'")
        .run(now, partyId);
    })();
    this.playback.delete(partyId);
    this.ctx.hub.clearPartyTimers(partyId, guests);

    const hub = this.ctx.hub;
    hub.sendToUsers([party.host_id, ...guests], { type: "party.ended", partyId, reason });
    for (const request of pending) {
      hub.sendToUser(request.user_id, {
        type: "join_request.updated",
        request: this.serializeRequest({ ...request, status: "cancelled", resolved_at: now }),
        party: null,
      });
    }
    hub.sendToUsers(this.ctx.friends.friendIds(party.host_id), { type: "friends.changed", reason: "party_ended" });
  }

  // ---------------------------------------------------------------- joining

  /** Checks the things every way of getting into a party has in common. */
  assertCanJoin(userId, party) {
    if (party.host_id === userId) throw badRequest("own_party", "This is your own party.");
    if (!this.ctx.friends.areFriends(userId, party.host_id)) {
      throw forbidden("not_friends", "You can only join parties hosted by your friends.");
    }
    if (this.activeHostedBy(userId)) {
      throw conflict("hosting_party", "You're hosting a party. End it before joining someone else's.");
    }
  }

  /** Join with the code the host gave you. `partyId` is optional: a code alone is enough. */
  joinWithCode(user, { partyId, code }) {
    const normalized = normalizePartyCode(code);
    this.codeAttempts.hit(user.id, "Too many wrong codes. Wait a few minutes and try again.");

    const party = partyId
      ? this.getActive(partyId)
      : this.db.prepare("SELECT * FROM parties WHERE code = ? AND status = 'active'").get(normalized);
    if (!party || party.code !== normalized) {
      throw forbidden("wrong_code", "That code doesn't match. Ask the host to read it out again.");
    }
    this.assertCanJoin(user.id, party);
    this.codeAttempts.reset(user.id);
    this.addGuest(party, user.id);
    return this.get(party.id);
  }

  /** Ask the host to let you in. The host gets an in-app prompt and a push notification. */
  requestToJoin(user, partyId) {
    const party = this.getActive(partyId);
    this.assertCanJoin(user.id, party);
    if (this.isGuest(party.id, user.id)) throw conflict("already_member", "You're already in this party.");

    const existing = this.db
      .prepare("SELECT * FROM join_requests WHERE party_id = ? AND user_id = ? AND status = 'pending'")
      .get(party.id, user.id);
    if (existing) return this.serializeRequest(existing);

    const row = { id: newId(), party_id: party.id, user_id: user.id, status: "pending", created_at: Date.now() };
    this.db
      .prepare(
        `INSERT INTO join_requests (id, party_id, user_id, status, created_at)
         VALUES (@id, @party_id, @user_id, @status, @created_at)`,
      )
      .run(row);
    const request = this.serializeRequest(row);

    this.ctx.hub.sendToUser(party.host_id, { type: "join_request", request });
    this.broadcastParty(party.id);
    this.ctx.notifier.notify([party.host_id], {
      title: "Someone wants to join your party",
      body: `${user.display_name} (@${user.username}) is asking to listen along.`,
      category: "JOIN_REQUEST",
      data: { type: "join_request", partyId: party.id, requestId: row.id },
      threadId: `party-${party.id}`,
    });
    return request;
  }

  cancelRequest(user, partyId, requestId) {
    const request = this.db.prepare("SELECT * FROM join_requests WHERE id = ? AND party_id = ?").get(requestId, partyId);
    if (!request) throw notFound("request_not_found", "That request no longer exists.");
    if (request.user_id !== user.id) throw forbidden("not_your_request", "That isn't your request.");
    if (request.status !== "pending") return this.serializeRequest(request);
    this.db
      .prepare("UPDATE join_requests SET status = 'cancelled', resolved_at = ? WHERE id = ?")
      .run(Date.now(), requestId);
    this.broadcastParty(partyId);
    return this.serializeRequest(this.db.prepare("SELECT * FROM join_requests WHERE id = ?").get(requestId));
  }

  resolveRequest(host, partyId, requestId, approve) {
    const party = this.requireHost(host.id, partyId);
    const request = this.db.prepare("SELECT * FROM join_requests WHERE id = ? AND party_id = ?").get(requestId, partyId);
    if (!request) throw notFound("request_not_found", "That request no longer exists.");
    if (request.status !== "pending") {
      throw conflict("request_resolved", "That request was already answered or withdrawn.");
    }

    if (approve) {
      // Things may have changed since they asked (e.g. they started their own party).
      this.assertCanJoin(request.user_id, party);
    }
    const status = approve ? "approved" : "declined";
    this.db
      .prepare("UPDATE join_requests SET status = ?, resolved_at = ? WHERE id = ?")
      .run(status, Date.now(), requestId);
    if (approve) this.addGuest(party, request.user_id);
    else this.broadcastParty(party.id);

    const resolved = this.serializeRequest(this.db.prepare("SELECT * FROM join_requests WHERE id = ?").get(requestId));
    this.ctx.hub.sendToUser(request.user_id, {
      type: "join_request.updated",
      request: resolved,
      party: approve ? this.serializeFor(party, request.user_id) : null,
    });
    if (approve) {
      this.ctx.notifier.notify([request.user_id], {
        title: "You're in!",
        body: `${host.display_name} let you into their listening party.`,
        data: { type: "join_approved", partyId: party.id },
        threadId: `party-${party.id}`,
      });
    }
    return resolved;
  }

  addGuest(party, userId) {
    const current = this.currentFor(userId);
    if (current && current.id !== party.id) this.leave(userId, current.id);

    const now = Date.now();
    this.db.transaction(() => {
      this.db
        .prepare(
          `INSERT INTO party_members (party_id, user_id, joined_at, left_at) VALUES (?, ?, ?, NULL)
           ON CONFLICT (party_id, user_id) DO UPDATE SET joined_at = excluded.joined_at, left_at = NULL`,
        )
        .run(party.id, userId, now);
      // Joining with the code settles any request they had open.
      this.db
        .prepare(
          `UPDATE join_requests SET status = 'approved', resolved_at = ?
           WHERE party_id = ? AND user_id = ? AND status = 'pending'`,
        )
        .run(now, party.id, userId);
    })();
    this.broadcastParty(party.id);
  }

  // ---------------------------------------------------------------- leaving

  leave(userId, partyId) {
    const party = this.getActive(partyId);
    if (party.host_id === userId) {
      throw badRequest("host_cannot_leave", "You're the host. End the party instead.");
    }
    this.removeGuest(party, userId, "left");
  }

  kick(hostId, partyId, guestId) {
    const party = this.requireHost(hostId, partyId);
    if (!this.isGuest(party.id, guestId)) throw notFound("not_member", "That person isn't in your party.");
    this.removeGuest(party, guestId, "removed");
  }

  /** `reason` is sent to the guest's app: left, removed, disconnected, or unfriended. */
  removeGuest(party, userId, reason) {
    const result = this.db
      .prepare("UPDATE party_members SET left_at = ? WHERE party_id = ? AND user_id = ? AND left_at IS NULL")
      .run(Date.now(), party.id, userId);
    if (result.changes === 0) return;
    this.ctx.hub.clearGuestTimer(party.id, userId);
    this.ctx.hub.sendToUser(userId, { type: "party.ended", partyId: party.id, reason });
    this.broadcastParty(party.id);
  }

  /** After an unfriend: neither person stays in a party the other hosts. */
  separate(a, b) {
    for (const [host, guest] of [
      [a, b],
      [b, a],
    ]) {
      const party = this.activeHostedBy(host);
      if (party && this.isGuest(party.id, guest)) this.removeGuest(party, guest, "unfriended");
    }
  }

  /** Called before an account is deleted. */
  removeUserEverywhere(userId) {
    const hosted = this.activeHostedBy(userId);
    if (hosted) this.end(hosted.id, "account_deleted");
    const current = this.currentFor(userId);
    if (current) this.removeGuest(current, userId, "left");
    // Withdraw their open requests so hosts aren't left with a prompt for someone who's gone.
    const asked = this.db
      .prepare("SELECT DISTINCT party_id FROM join_requests WHERE user_id = ? AND status = 'pending'")
      .all(userId);
    this.db
      .prepare("UPDATE join_requests SET status = 'cancelled', resolved_at = ? WHERE user_id = ? AND status = 'pending'")
      .run(Date.now(), userId);
    for (const { party_id } of asked) this.broadcastParty(party_id);
  }

  // --------------------------------------------------------------- playback

  /** The host's app reports what it's playing. Guests get it right away. */
  reportPlayback(hostId, state) {
    const party = this.activeHostedBy(hostId);
    if (!party) throw badRequest("not_hosting", "You aren't hosting a party.");
    const now = Date.now();
    const timestamp = Math.abs(state.timestamp - now) > MAX_TIMESTAMP_SKEW_MS ? now : state.timestamp;
    const playback = { ...state, timestamp };
    this.playback.set(party.id, playback);
    this.ctx.hub.sendToUsers(this.guestIds(party.id), { type: "playback", partyId: party.id, playback });
    return playback;
  }

  /** A guest pressed play/pause/seek/skip. The host's app carries it out and reports the result. */
  forwardControl(guest, { action, position }) {
    const party = this.currentFor(guest.id);
    if (!party || party.host_id === guest.id) throw badRequest("not_guest", "You aren't a guest in a party.");
    if (!party.allow_guest_control) {
      throw forbidden("control_not_allowed", "The host hasn't turned on guest controls.");
    }
    if (!this.ctx.hub.isOnline(party.host_id)) {
      throw conflict("host_offline", "The host's app is offline right now.");
    }
    this.ctx.hub.sendToUser(party.host_id, {
      type: "control",
      partyId: party.id,
      action,
      position: position ?? null,
      from: publicUser(guest),
    });
  }
}
