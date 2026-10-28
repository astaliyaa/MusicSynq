import { ApiError } from "../errors.js";
import { ClientMessage } from "../protocol.js";
import { publicUser } from "../services/users.js";

const OPEN = 1; // WebSocket.OPEN

/**
 * Tracks every open app connection, routes socket messages to the party
 * service, and gives disconnected hosts/guests a grace period to come back.
 */
export class Hub {
  constructor(ctx) {
    this.ctx = ctx;
    /** userId -> Set of sockets (a user may be signed in on several devices). */
    this.sockets = new Map();
    /** partyId -> timer that ends the party if the host doesn't reconnect. */
    this.hostTimers = new Map();
    /** `${partyId}:${userId}` -> timer that removes a guest who doesn't reconnect. */
    this.guestTimers = new Map();
    this.pingInterval = null;
  }

  get log() {
    return this.ctx.log;
  }

  start() {
    // Parties survive a server restart, but everyone's connection didn't:
    // give them the usual grace period to reconnect.
    const active = this.ctx.db.prepare("SELECT * FROM parties WHERE status = 'active'").all();
    for (const party of active) {
      this.scheduleHostTimer(party.id);
      for (const guestId of this.ctx.parties.guestIds(party.id)) this.scheduleGuestTimer(party.id, guestId);
    }
    this.pingInterval = setInterval(() => this.pingAll(), this.ctx.config.socketPingIntervalMs);
    this.pingInterval.unref();
  }

  stop() {
    clearInterval(this.pingInterval);
    for (const timer of this.hostTimers.values()) clearTimeout(timer);
    for (const timer of this.guestTimers.values()) clearTimeout(timer);
    this.hostTimers.clear();
    this.guestTimers.clear();
    for (const set of this.sockets.values()) for (const socket of set) socket.terminate();
    this.sockets.clear();
  }

  // ------------------------------------------------------------- connections

  isOnline(userId) {
    return (this.sockets.get(userId)?.size ?? 0) > 0;
  }

  attach(socket, user, tokenHash) {
    socket.isAlive = true;
    socket.tokenHash = tokenHash;
    socket.on("pong", () => {
      socket.isAlive = true;
    });

    const wasOnline = this.isOnline(user.id);
    let set = this.sockets.get(user.id);
    if (!set) this.sockets.set(user.id, (set = new Set()));
    set.add(socket);

    const parties = this.ctx.parties;
    const party = parties.currentFor(user.id);
    this.send(socket, {
      type: "hello",
      serverTime: Date.now(),
      user: publicUser(user),
      party: party ? parties.serializeFor(party, user.id) : null,
    });

    if (!wasOnline && party) {
      if (party.host_id === user.id) this.clearHostTimer(party.id);
      else this.clearGuestTimer(party.id, user.id);
      parties.broadcastParty(party.id);
    }

    socket.on("message", (raw) => this.onMessage(socket, user, raw));
    socket.on("close", () => this.detach(socket, user));
    socket.on("error", (err) => this.log.warn({ err, userId: user.id }, "socket error"));
  }

  detach(socket, user) {
    const set = this.sockets.get(user.id);
    if (!set?.delete(socket)) return;
    if (set.size > 0) return;
    this.sockets.delete(user.id);

    const parties = this.ctx.parties;
    const party = parties.currentFor(user.id);
    if (!party) return;
    if (party.host_id === user.id) this.scheduleHostTimer(party.id);
    else this.scheduleGuestTimer(party.id, user.id);
    // Let everyone else see the "reconnecting…" state.
    parties.broadcastParty(party.id);
  }

  /** Closes the sockets opened with one session token (used on sign-out). */
  disconnectSession(userId, tokenHash) {
    for (const socket of this.sockets.get(userId) ?? []) {
      if (socket.tokenHash === tokenHash) socket.close(4001, "signed out");
    }
  }

  disconnectUser(userId) {
    for (const socket of this.sockets.get(userId) ?? []) socket.close(4001, "account deleted");
  }

  pingAll() {
    for (const set of this.sockets.values()) {
      for (const socket of set) {
        if (!socket.isAlive) {
          socket.terminate();
          continue;
        }
        socket.isAlive = false;
        socket.ping();
      }
    }
  }

  // ---------------------------------------------------------------- messages

  onMessage(socket, user, raw) {
    let message;
    try {
      const parsed = ClientMessage.safeParse(JSON.parse(raw.toString()));
      if (!parsed.success) {
        this.send(socket, { type: "error", code: "invalid_message", message: parsed.error.issues[0]?.message ?? "Invalid message." });
        return;
      }
      message = parsed.data;
    } catch {
      this.send(socket, { type: "error", code: "invalid_message", message: "Messages must be JSON." });
      return;
    }

    try {
      switch (message.type) {
        case "ping":
          this.send(socket, { type: "pong", id: message.id ?? null, clientTime: message.clientTime, serverTime: Date.now() });
          break;
        case "playback":
          this.ctx.parties.reportPlayback(user.id, message.playback);
          break;
        case "control":
          this.ctx.parties.forwardControl(user, message);
          break;
      }
    } catch (err) {
      if (err instanceof ApiError) {
        this.send(socket, { type: "error", code: err.code, message: err.message });
      } else {
        this.log.error({ err, userId: user.id, type: message.type }, "socket message failed");
        this.send(socket, { type: "error", code: "internal", message: "Something went wrong." });
      }
    }
  }

  send(socket, message) {
    if (socket.readyState === OPEN) socket.send(JSON.stringify(message));
  }

  sendToUser(userId, message) {
    const set = this.sockets.get(userId);
    if (!set) return;
    const data = JSON.stringify(message);
    for (const socket of set) if (socket.readyState === OPEN) socket.send(data);
  }

  sendToUsers(userIds, message) {
    for (const userId of userIds) this.sendToUser(userId, message);
  }

  // ------------------------------------------------------------ grace timers

  scheduleHostTimer(partyId) {
    this.clearHostTimer(partyId);
    const timer = setTimeout(() => {
      this.hostTimers.delete(partyId);
      const party = this.ctx.parties.get(partyId);
      if (party?.status === "active" && !this.isOnline(party.host_id)) {
        this.log.info({ partyId }, "host did not reconnect; ending party");
        this.ctx.parties.end(partyId, "host_disconnected");
      }
    }, this.ctx.config.hostGraceMs);
    timer.unref();
    this.hostTimers.set(partyId, timer);
  }

  clearHostTimer(partyId) {
    clearTimeout(this.hostTimers.get(partyId));
    this.hostTimers.delete(partyId);
  }

  scheduleGuestTimer(partyId, userId) {
    const key = `${partyId}:${userId}`;
    clearTimeout(this.guestTimers.get(key));
    const timer = setTimeout(() => {
      this.guestTimers.delete(key);
      const parties = this.ctx.parties;
      const party = parties.get(partyId);
      if (party?.status === "active" && !this.isOnline(userId)) parties.removeGuest(party, userId, "disconnected");
    }, this.ctx.config.guestGraceMs);
    timer.unref();
    this.guestTimers.set(key, timer);
  }

  clearGuestTimer(partyId, userId) {
    const key = `${partyId}:${userId}`;
    clearTimeout(this.guestTimers.get(key));
    this.guestTimers.delete(key);
  }

  clearPartyTimers(partyId, guestIds) {
    this.clearHostTimer(partyId);
    for (const guestId of guestIds) this.clearGuestTimer(partyId, guestId);
  }
}
