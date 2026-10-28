import WebSocket from "ws";
import { buildApp } from "../src/app.js";

/** Records notifications instead of talking to Apple. */
export class FakeNotifier {
  constructor() {
    this.sent = [];
  }
  registerDevice() {}
  unregisterDevice() {}
  notify(userIds, message) {
    for (const userId of userIds) this.sent.push({ userId, ...message });
  }
}

export async function startServer(configOverrides = {}) {
  const config = {
    host: "127.0.0.1",
    port: 0,
    databasePath: ":memory:",
    hostGraceMs: 60_000,
    guestGraceMs: 60_000,
    socketPingIntervalMs: 60_000,
    signupsPerHour: 10_000,
    loginAttemptsPer15Min: 10_000,
    apns: null,
    logLevel: "silent",
    ...configOverrides,
  };
  const notifier = new FakeNotifier();
  const app = await buildApp(config, { notifier, logger: false });
  await app.listen({ host: config.host, port: 0 });
  const { port } = app.server.address();
  const baseUrl = `http://127.0.0.1:${port}`;
  const sockets = [];

  async function request(method, path, { token, body } = {}) {
    const headers = {};
    if (token) headers.authorization = `Bearer ${token}`;
    if (body !== undefined) headers["content-type"] = "application/json";
    const res = await fetch(baseUrl + path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
    const text = await res.text();
    return { status: res.status, body: text ? JSON.parse(text) : null };
  }

  let counter = 0;
  /** Registers a user and returns a small client bound to their token. */
  async function user(name = `user${++counter}`) {
    const res = await request("POST", "/auth/register", {
      body: { username: name, displayName: name[0].toUpperCase() + name.slice(1), password: "correct horse battery" },
    });
    if (res.status !== 201) throw new Error(`register failed: ${JSON.stringify(res.body)}`);
    const { token, user: profile } = res.body;
    const client = {
      token,
      ...profile,
      get: (path) => request("GET", path, { token }),
      post: (path, body) => request("POST", path, { token, body }),
      patch: (path, body) => request("PATCH", path, { token, body }),
      put: (path, body) => request("PUT", path, { token, body }),
      del: (path, body) => request("DELETE", path, { token, body }),
      connect: () => connect(token),
    };
    return client;
  }

  async function befriend(a, b) {
    const sent = await a.post("/friends/requests", { username: b.username });
    if (sent.status !== 201) throw new Error(`friend request failed: ${JSON.stringify(sent.body)}`);
    const accepted = await b.post(`/friends/requests/${sent.body.request.id}/accept`);
    if (accepted.status !== 200) throw new Error(`accept failed: ${JSON.stringify(accepted.body)}`);
  }

  function connect(token) {
    const ws = new WebSocket(`${baseUrl.replace("http", "ws")}/ws`, { headers: { authorization: `Bearer ${token}` } });
    sockets.push(ws);
    const queue = [];
    const waiters = [];
    ws.on("message", (data) => {
      const message = JSON.parse(data.toString());
      const index = waiters.findIndex((w) => w.type === message.type);
      if (index >= 0) waiters.splice(index, 1)[0].resolve(message);
      else queue.push(message);
    });
    const client = {
      ws,
      send: (message) => ws.send(JSON.stringify(message)),
      /** Resolves with the next message of `type` (including ones that already arrived). */
      next(type, timeoutMs = 2000) {
        const index = queue.findIndex((m) => m.type === type);
        if (index >= 0) return Promise.resolve(queue.splice(index, 1)[0]);
        return new Promise((resolve, reject) => {
          const timer = setTimeout(() => reject(new Error(`timed out waiting for "${type}"`)), timeoutMs);
          waiters.push({ type, resolve: (m) => (clearTimeout(timer), resolve(m)) });
        });
      },
      /** Drops queued messages of `type`, e.g. stale party.updated snapshots. */
      drain(type) {
        for (let i = queue.length - 1; i >= 0; i--) if (queue[i].type === type) queue.splice(i, 1);
      },
      has: (type) => queue.some((m) => m.type === type),
      close: () =>
        new Promise((resolve) => {
          if (ws.readyState === WebSocket.CLOSED) return resolve();
          ws.once("close", resolve);
          ws.close();
        }),
    };
    return new Promise((resolve, reject) => {
      ws.once("open", () => resolve(client));
      ws.once("unexpected-response", (_req, res) => reject(new Error(`upgrade failed: ${res.statusCode}`)));
      ws.once("error", reject);
    });
  }

  return {
    app,
    notifier,
    request,
    user,
    befriend,
    connect,
    async close() {
      for (const ws of sockets) ws.terminate();
      await app.close();
    },
  };
}

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
