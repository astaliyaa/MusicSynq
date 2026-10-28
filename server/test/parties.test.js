import assert from "node:assert/strict";
import { after, before, describe, test } from "node:test";
import { sleep, startServer } from "./helpers.js";

const TRACK = {
  catalogId: "1440857781",
  isrc: "GBUM71029604",
  title: "Dancing Queen",
  artist: "ABBA",
  album: "Arrival",
  duration: 230.4,
  artworkUrl: "https://is1-ssl.mzstatic.com/image/thumb/abba/600x600bb.jpg",
};

describe("listening parties", () => {
  let server;
  before(async () => {
    server = await startServer();
  });
  after(() => server.close());

  /** A host and a guest who are friends, both with sockets open. */
  async function pair() {
    const host = await server.user();
    const guest = await server.user();
    await server.befriend(host, guest);
    const hostSocket = await host.connect();
    const guestSocket = await guest.connect();
    return { host, guest, hostSocket, guestSocket };
  }

  test("host starts a party; friends see it without the code", async () => {
    const { host, guest, hostSocket } = await pair();
    const hello = await hostSocket.next("hello");
    assert.equal(hello.party, null);

    const started = await host.post("/parties", {});
    assert.equal(started.status, 201);
    assert.equal(started.body.party.role, "host");
    assert.match(started.body.party.code, /^[A-Z2-9]{6}$/);

    const again = await host.post("/parties");
    assert.equal(again.body.party.id, started.body.party.id, "starting twice returns the same party");

    const list = await guest.get("/parties/friends");
    assert.equal(list.body.parties.length, 1);
    assert.equal(list.body.parties[0].host.id, host.id);
    assert.equal(list.body.parties[0].code, undefined);

    const friends = await guest.get("/friends");
    assert.equal(friends.body.friends[0].party.id, started.body.party.id);
    assert.ok(server.notifier.sent.some((n) => n.userId === guest.id && n.data.type === "party_started"));
  });

  test("join with code, sync playback, guest controls, leave", async () => {
    const { host, guest, hostSocket, guestSocket } = await pair();
    const { party } = (await host.post("/parties")).body;

    const wrong = await guest.post(`/parties/${party.id}/join`, { code: "ZZZZZZ" });
    assert.equal(wrong.status, 403);
    assert.equal(wrong.body.error.code, "wrong_code");

    // Lowercase with a dash still matches.
    const typed = `${party.code.slice(0, 3).toLowerCase()}-${party.code.slice(3).toLowerCase()}`;
    const joined = await guest.post(`/parties/${party.id}/join`, { code: typed });
    assert.equal(joined.status, 200);
    assert.equal(joined.body.party.role, "guest");
    assert.equal(joined.body.party.code, null, "guests don't get the code");

    hostSocket.drain("party.updated");
    // Host reports what it's playing; the guest gets it.
    const timestamp = Date.now();
    hostSocket.send({ type: "playback", playback: { track: TRACK, isPlaying: true, position: 42.5, timestamp, rate: 1 } });
    const playback = await guestSocket.next("playback");
    assert.equal(playback.partyId, party.id);
    assert.deepEqual(playback.playback.track, TRACK);
    assert.equal(playback.playback.position, 42.5);
    assert.equal(playback.playback.timestamp, timestamp);
    assert.equal(hostSocket.has("playback"), false, "the host isn't echoed its own state");

    // Late joiners get the current state in the party snapshot.
    const current = await guest.get("/parties/current");
    assert.equal(current.body.party.playback.position, 42.5);

    // Guest presses pause: forwarded to the host's app.
    guestSocket.send({ type: "control", action: "pause" });
    const control = await hostSocket.next("control");
    assert.equal(control.action, "pause");
    assert.equal(control.from.id, guest.id);

    guestSocket.send({ type: "control", action: "seek", position: 95 });
    assert.equal((await hostSocket.next("control")).position, 95);

    // Host turns guest controls off.
    const updated = await host.patch(`/parties/${party.id}`, { allowGuestControl: false });
    assert.equal(updated.body.party.allowGuestControl, false);
    guestSocket.send({ type: "control", action: "play" });
    assert.equal((await guestSocket.next("error")).code, "control_not_allowed");

    // Guests can't report playback.
    guestSocket.send({ type: "playback", playback: { track: null, isPlaying: false, position: 0, timestamp } });
    assert.equal((await guestSocket.next("error")).code, "not_hosting");

    hostSocket.drain("party.updated");
    assert.equal((await guest.post(`/parties/${party.id}/leave`)).status, 204);
    const ended = await guestSocket.next("party.ended");
    assert.equal(ended.reason, "left");
    const after = await hostSocket.next("party.updated");
    assert.equal(after.party.members.length, 0);
  });

  test("host ending the party stops it for everyone", async () => {
    const { host, guest, guestSocket } = await pair();
    const { party } = (await host.post("/parties")).body;
    await guest.post("/parties/join", { code: party.code });

    assert.equal((await guest.del(`/parties/${party.id}`)).status, 403, "guests can't end it");
    assert.equal((await host.del(`/parties/${party.id}`)).status, 204);
    const ended = await guestSocket.next("party.ended");
    assert.equal(ended.reason, "host_ended");
    assert.equal((await guest.get("/parties/current")).body.party, null);
    assert.equal((await guest.get("/parties/friends")).body.parties.length, 0);
  });

  test("ask to join: host approves from a notification", async () => {
    const { host, guest, hostSocket, guestSocket } = await pair();
    const { party } = (await host.post("/parties")).body;

    const asked = await guest.post(`/parties/${party.id}/requests`);
    assert.equal(asked.status, 201);
    assert.equal(asked.body.request.status, "pending");

    const prompt = await hostSocket.next("join_request");
    assert.equal(prompt.request.user.id, guest.id);
    const push = server.notifier.sent.find((n) => n.userId === host.id && n.data.type === "join_request");
    assert.equal(push.category, "JOIN_REQUEST");
    assert.equal(push.data.requestId, asked.body.request.id);

    const summary = (await guest.get("/parties/friends")).body.parties[0];
    assert.equal(summary.myRequest.id, asked.body.request.id);

    const approved = await host.post(`/parties/${party.id}/requests/${asked.body.request.id}/approve`);
    assert.equal(approved.body.request.status, "approved");
    const resolved = await guestSocket.next("join_request.updated");
    assert.equal(resolved.request.status, "approved");
    assert.equal(resolved.party.role, "guest");
    assert.equal((await guest.get("/parties/current")).body.party.id, party.id);

    const again = await host.post(`/parties/${party.id}/requests/${asked.body.request.id}/decline`);
    assert.equal(again.status, 409, "a request can only be answered once");
  });

  test("ask to join: host declines; guest can cancel", async () => {
    const { host, guest, guestSocket } = await pair();
    const { party } = (await host.post("/parties")).body;

    const first = (await guest.post(`/parties/${party.id}/requests`)).body.request;
    await host.post(`/parties/${party.id}/requests/${first.id}/decline`);
    const declined = await guestSocket.next("join_request.updated");
    assert.equal(declined.request.status, "declined");
    assert.equal(declined.party, null);

    const second = (await guest.post(`/parties/${party.id}/requests`)).body.request;
    const cancelled = await guest.del(`/parties/${party.id}/requests/${second.id}`);
    assert.equal(cancelled.body.request.status, "cancelled");
    const hostView = (await host.get("/parties/current")).body.party;
    assert.equal(hostView.pendingRequests.length, 0);
  });

  test("strangers can't join, even with the right code", async () => {
    const host = await server.user();
    const stranger = await server.user();
    const { party } = (await host.post("/parties")).body;
    const res = await stranger.post("/parties/join", { code: party.code });
    assert.equal(res.status, 403);
    assert.equal(res.body.error.code, "not_friends");
    assert.equal((await stranger.post(`/parties/${party.id}/requests`)).status, 403);
    assert.equal((await stranger.get("/parties/friends")).body.parties.length, 0);
  });

  test("wrong codes are rate limited", async () => {
    const { host, guest } = await pair();
    const { party } = (await host.post("/parties")).body;
    for (let i = 0; i < 10; i++) await guest.post(`/parties/${party.id}/join`, { code: "WRONG1" });
    const blocked = await guest.post(`/parties/${party.id}/join`, { code: party.code });
    assert.equal(blocked.status, 429);
  });

  test("joining another party leaves the first; hosts can't join others", async () => {
    const guest = await server.user();
    const hostA = await server.user();
    const hostB = await server.user();
    await server.befriend(hostA, guest);
    await server.befriend(hostB, guest);
    await server.befriend(hostA, hostB);
    const guestSocket = await guest.connect();
    const a = (await hostA.post("/parties")).body.party;
    const b = (await hostB.post("/parties")).body.party;

    await guest.post("/parties/join", { code: a.code });
    await guest.post("/parties/join", { code: b.code });
    const ended = await guestSocket.next("party.ended");
    assert.equal(ended.partyId, a.id);
    assert.equal((await guest.get("/parties/current")).body.party.id, b.id);

    const res = await hostA.post("/parties/join", { code: b.code });
    assert.equal(res.status, 409);
    assert.equal(res.body.error.code, "hosting_party");
  });

  test("host can remove a guest; unfriending removes them too", async () => {
    const { host, guest, guestSocket } = await pair();
    const { party } = (await host.post("/parties")).body;
    await guest.post("/parties/join", { code: party.code });
    assert.equal((await host.del(`/parties/${party.id}/members/${guest.id}`)).status, 204);
    assert.equal((await guestSocket.next("party.ended")).reason, "removed");

    await guest.post("/parties/join", { code: party.code });
    await host.del(`/friends/${guest.id}`);
    assert.equal((await guestSocket.next("party.ended")).reason, "unfriended");
  });

  test("ping/pong for clock sync, and bad host clocks are corrected", async () => {
    const { host, guest, hostSocket, guestSocket } = await pair();
    hostSocket.send({ type: "ping", id: 7, clientTime: 123 });
    const pong = await hostSocket.next("pong");
    assert.equal(pong.id, 7);
    assert.equal(pong.clientTime, 123);
    assert.ok(Math.abs(pong.serverTime - Date.now()) < 1000);

    const { party } = (await host.post("/parties")).body;
    await guest.post("/parties/join", { code: party.code });
    hostSocket.send({
      type: "playback",
      playback: { track: TRACK, isPlaying: true, position: 10, timestamp: Date.now() - 3_600_000 },
    });
    const playback = (await guestSocket.next("playback")).playback;
    assert.ok(Math.abs(playback.timestamp - Date.now()) < 1000);
    assert.equal(playback.rate, 1, "rate defaults to 1");

    hostSocket.send({ type: "playback", playback: { track: { title: "x" }, isPlaying: true } });
    assert.equal((await hostSocket.next("error")).code, "invalid_message");
  });

  test("deleting your account withdraws your join requests", async () => {
    const { host, guest, hostSocket } = await pair();
    const { party } = (await host.post("/parties")).body;
    await guest.post(`/parties/${party.id}/requests`);
    await hostSocket.next("join_request");
    hostSocket.drain("party.updated");
    await guest.del("/me", { password: "correct horse battery" });
    const updated = await hostSocket.next("party.updated");
    assert.equal(updated.party.pendingRequests.length, 0);
  });

  test("deleting your account ends the party you host", async () => {
    const { host, guest, guestSocket } = await pair();
    const { party } = (await host.post("/parties")).body;
    await guest.post("/parties/join", { code: party.code });
    await host.del("/me", { password: "correct horse battery" });
    assert.equal((await guestSocket.next("party.ended")).reason, "account_deleted");
  });
});

describe("disconnects", () => {
  let server;
  before(async () => {
    server = await startServer({ hostGraceMs: 300, guestGraceMs: 300 });
  });
  after(() => server.close());

  test("party survives a quick host reconnect but ends if the host stays away", async () => {
    const host = await server.user();
    const guest = await server.user();
    await server.befriend(host, guest);
    let hostSocket = await host.connect();
    const guestSocket = await guest.connect();
    const { party } = (await host.post("/parties")).body;
    await guest.post("/parties/join", { code: party.code });
    guestSocket.drain("party.updated");

    await hostSocket.close();
    const offline = await guestSocket.next("party.updated");
    assert.equal(offline.party.hostConnected, false);

    hostSocket = await host.connect();
    const hello = await hostSocket.next("hello");
    assert.equal(hello.party.id, party.id, "hello carries the party on reconnect");
    await sleep(500);
    assert.equal((await guest.get("/parties/current")).body.party.hostConnected, true);
    assert.equal(guestSocket.has("party.ended"), false);

    await hostSocket.close();
    const ended = await guestSocket.next("party.ended", 3000);
    assert.equal(ended.reason, "host_disconnected");
  });

  test("a guest who stays disconnected is removed", async () => {
    const host = await server.user();
    const guest = await server.user();
    await server.befriend(host, guest);
    const hostSocket = await host.connect();
    const guestSocket = await guest.connect();
    const { party } = (await host.post("/parties")).body;
    await guest.post("/parties/join", { code: party.code });
    await guestSocket.close();
    await sleep(600);
    hostSocket.drain("party.updated");
    assert.equal((await host.get("/parties/current")).body.party.members.length, 0);
    assert.equal((await guest.get("/parties/current")).body.party, null);
  });
});
