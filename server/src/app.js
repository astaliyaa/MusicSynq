import websocket from "@fastify/websocket";
import Fastify from "fastify";
import { hashToken } from "./crypto.js";
import { openDatabase } from "./db.js";
import { ApiError, unauthorized } from "./errors.js";
import { Notifier } from "./push/notifier.js";
import { Hub } from "./realtime/hub.js";
import { accountRoutes, publicAccountRoutes } from "./routes/account.js";
import { friendRoutes } from "./routes/friends.js";
import { partyRoutes } from "./routes/parties.js";
import { FriendService } from "./services/friends.js";
import { PartyService } from "./services/parties.js";
import { UserService } from "./services/users.js";

function bearerToken(request) {
  const header = request.headers.authorization;
  if (header?.startsWith("Bearer ")) return header.slice(7).trim();
  // WebSocket clients that can't set headers may pass ?token= instead.
  return request.query?.token ?? null;
}

/**
 * Builds the server. `overrides` lets tests swap in a fake notifier or logger.
 * Call `app.listen()` on the result; `app.close()` shuts everything down.
 */
export async function buildApp(config, overrides = {}) {
  const app = Fastify({
    logger: overrides.logger ?? { level: config.logLevel },
    trustProxy: true,
    bodyLimit: 64 * 1024,
  });

  const ctx = { config, log: app.log, db: openDatabase(config.databasePath) };
  ctx.users = new UserService(ctx);
  ctx.friends = new FriendService(ctx);
  ctx.parties = new PartyService(ctx);
  ctx.hub = new Hub(ctx);
  ctx.notifier = overrides.notifier ?? new Notifier(ctx);
  app.decorate("ctx", ctx);
  app.decorateRequest("user", null);
  app.decorateRequest("token", null);
  app.decorateRequest("tokenHash", null);

  app.setErrorHandler((err, request, reply) => {
    if (err instanceof ApiError) {
      return reply.code(err.status).send({ error: { code: err.code, message: err.message } });
    }
    if (err.statusCode && err.statusCode < 500) {
      return reply.code(err.statusCode).send({ error: { code: "bad_request", message: err.message } });
    }
    request.log.error(err);
    return reply.code(500).send({ error: { code: "internal", message: "Something went wrong." } });
  });
  app.setNotFoundHandler((request, reply) =>
    reply.code(404).send({ error: { code: "not_found", message: "No such endpoint." } }),
  );

  await app.register(websocket, { options: { maxPayload: 64 * 1024 } });

  app.get("/health", async () => ({ ok: true, time: Date.now() }));
  await app.register(publicAccountRoutes, { ctx });

  // Everything below needs a signed-in user.
  await app.register(async (authed) => {
    authed.addHook("preValidation", async (request) => {
      const token = bearerToken(request);
      const user = ctx.users.userForToken(token);
      if (!user) throw unauthorized();
      request.user = user;
      request.token = token;
      request.tokenHash = hashToken(token);
    });

    authed.get("/ws", { websocket: true }, (socket, request) => {
      ctx.hub.attach(socket, request.user, request.tokenHash);
    });
    await authed.register(accountRoutes, { ctx });
    await authed.register(friendRoutes, { ctx });
    await authed.register(partyRoutes, { ctx });
  });

  app.addHook("onReady", async () => ctx.hub.start());
  app.addHook("onClose", async () => {
    ctx.hub.stop();
    ctx.notifier.close?.();
    ctx.db.close();
  });

  return app;
}
