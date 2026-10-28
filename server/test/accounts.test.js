import assert from "node:assert/strict";
import { after, before, describe, test } from "node:test";
import { startServer } from "./helpers.js";

describe("accounts", () => {
  let server;
  before(async () => {
    server = await startServer();
  });
  after(() => server.close());

  test("register, sign in, sign out", async () => {
    const reg = await server.request("POST", "/auth/register", {
      body: { username: "Alex_M", displayName: "Alex", password: "password123" },
    });
    assert.equal(reg.status, 201);
    assert.equal(reg.body.user.username, "alex_m", "usernames are stored lowercase");
    assert.ok(reg.body.token);

    const dup = await server.request("POST", "/auth/register", {
      body: { username: "ALEX_M", displayName: "Other", password: "password123" },
    });
    assert.equal(dup.status, 409);
    assert.equal(dup.body.error.code, "username_taken");

    const wrong = await server.request("POST", "/auth/login", { body: { username: "alex_m", password: "nope-nope" } });
    assert.equal(wrong.status, 401);

    const login = await server.request("POST", "/auth/login", { body: { username: "Alex_M", password: "password123" } });
    assert.equal(login.status, 200);
    const token = login.body.token;

    const me = await server.request("GET", "/me", { token });
    assert.deepEqual(me.body.user, reg.body.user);

    assert.equal((await server.request("POST", "/auth/logout", { token })).status, 204);
    assert.equal((await server.request("GET", "/me", { token })).status, 401);
    // The registration session is separate and still works.
    assert.equal((await server.request("GET", "/me", { token: reg.body.token })).status, 200);
  });

  test("rejects invalid sign-up details with a readable message", async () => {
    const res = await server.request("POST", "/auth/register", {
      body: { username: "a b", displayName: "X", password: "short" },
    });
    assert.equal(res.status, 400);
    assert.match(res.body.error.message, /username/i);
  });

  test("unauthenticated sockets are refused", async () => {
    await assert.rejects(server.connect("not-a-token"), /401/);
  });

  test("display name changes and account deletion", async () => {
    const sam = await server.user("sam");
    const renamed = await sam.patch("/me", { displayName: "Sammy" });
    assert.equal(renamed.body.user.displayName, "Sammy");

    assert.equal((await sam.del("/me", { password: "wrong password" })).status, 401);
    assert.equal((await sam.del("/me", { password: "correct horse battery" })).status, 204);
    assert.equal((await sam.get("/me")).status, 401);
    const login = await server.request("POST", "/auth/login", { body: { username: "sam", password: "correct horse battery" } });
    assert.equal(login.status, 401);
  });
});

describe("friends", () => {
  let server;
  before(async () => {
    server = await startServer();
  });
  after(() => server.close());

  test("request, accept, list, unfriend", async () => {
    const alex = await server.user("alex");
    const jo = await server.user("jordan");
    const joSocket = await jo.connect();

    const sent = await alex.post("/friends/requests", { username: "JORDAN" });
    assert.equal(sent.status, 201);
    assert.equal(sent.body.status, "requested");
    const changed = await joSocket.next("friends.changed");
    assert.equal(changed.reason, "request_received");
    assert.equal(server.notifier.sent.at(-1).userId, jo.id);

    const search = await jo.get("/users/search?q=al");
    assert.equal(search.body.users[0].relationship, "incoming");

    const joList = await jo.get("/friends");
    assert.equal(joList.body.incoming.length, 1);
    assert.equal(joList.body.incoming[0].from.username, "alex");

    const accepted = await jo.post(`/friends/requests/${sent.body.request.id}/accept`);
    assert.equal(accepted.body.friends.length, 1);
    assert.equal(accepted.body.friends[0].user.username, "alex");
    assert.equal(accepted.body.incoming.length, 0);

    const alexList = await alex.get("/friends");
    assert.equal(alexList.body.friends[0].user.username, "jordan");
    assert.equal(alexList.body.friends[0].online, true, "jo has a socket open");

    const removed = await alex.del(`/friends/${jo.id}`);
    assert.equal(removed.body.friends.length, 0);
    assert.equal((await jo.get("/friends")).body.friends.length, 0);
  });

  test("two people asking each other become friends straight away", async () => {
    const a = await server.user("mutual_a");
    const b = await server.user("mutual_b");
    await a.post("/friends/requests", { username: b.username });
    const res = await b.post("/friends/requests", { username: a.username });
    assert.equal(res.body.status, "accepted");
    assert.equal((await a.get("/friends")).body.friends.length, 1);
  });

  test("only the recipient can accept; either side can withdraw", async () => {
    const a = await server.user("perm_a");
    const b = await server.user("perm_b");
    const sent = await a.post("/friends/requests", { username: b.username });
    assert.equal((await a.post(`/friends/requests/${sent.body.request.id}/accept`)).status, 403);
    assert.equal((await a.del(`/friends/requests/${sent.body.request.id}`)).status, 200);
    assert.equal((await b.get("/friends")).body.incoming.length, 0);
  });

  test("cannot add yourself or someone who doesn't exist", async () => {
    const a = await server.user("lonely");
    assert.equal((await a.post("/friends/requests", { username: "lonely" })).status, 400);
    assert.equal((await a.post("/friends/requests", { username: "ghost" })).status, 404);
  });
});
