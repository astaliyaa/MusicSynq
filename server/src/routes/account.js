import { RateLimiter } from "../rateLimit.js";
import {
  DeleteMeBody,
  LoginBody,
  parse,
  RegisterBody,
  RegisterDeviceBody,
  SearchQuery,
  UpdateMeBody,
} from "../protocol.js";
import { publicUser } from "../services/users.js";

/** Routes that don't need a signed-in user. */
export async function publicAccountRoutes(app, { ctx }) {
  const loginLimiter = new RateLimiter({ limit: ctx.config.loginAttemptsPer15Min, windowMs: 15 * 60 * 1000 });
  const registerLimiter = new RateLimiter({ limit: ctx.config.signupsPerHour, windowMs: 60 * 60 * 1000 });

  app.post("/auth/register", async (request, reply) => {
    registerLimiter.hit(request.ip, "Too many sign-ups from this network. Try again later.");
    const body = parse(RegisterBody, request.body);
    const user = await ctx.users.register(body);
    const token = ctx.users.createSession(user.id);
    reply.code(201);
    return { token, user: publicUser(user) };
  });

  app.post("/auth/login", async (request) => {
    const body = parse(LoginBody, request.body);
    const key = `${request.ip}:${body.username.toLowerCase()}`;
    loginLimiter.hit(key, "Too many sign-in attempts. Wait a few minutes and try again.");
    const user = await ctx.users.authenticate(body.username, body.password);
    loginLimiter.reset(key);
    return { token: ctx.users.createSession(user.id), user: publicUser(user) };
  });
}

/** Routes for the signed-in user's own account, user search and push devices. */
export async function accountRoutes(app, { ctx }) {
  app.post("/auth/logout", async (request, reply) => {
    ctx.users.deleteSession(request.token);
    ctx.hub.disconnectSession(request.user.id, request.tokenHash);
    reply.code(204);
  });

  app.get("/me", async (request) => ({ user: publicUser(request.user) }));

  app.patch("/me", async (request) => {
    const { displayName } = parse(UpdateMeBody, request.body);
    const user = ctx.users.updateDisplayName(request.user.id, displayName);
    const party = ctx.parties.currentFor(user.id);
    if (party) ctx.parties.broadcastParty(party.id);
    return { user: publicUser(user) };
  });

  // Apple requires apps that let you create an account to let you delete it.
  app.delete("/me", async (request, reply) => {
    const { password } = parse(DeleteMeBody, request.body);
    const user = request.user;
    await ctx.users.checkPassword(user, password);
    const friendIds = ctx.friends.friendIds(user.id);
    ctx.parties.removeUserEverywhere(user.id);
    ctx.users.delete(user.id);
    ctx.hub.disconnectUser(user.id);
    ctx.hub.sendToUsers(friendIds, { type: "friends.changed", reason: "friend_removed" });
    reply.code(204);
  });

  app.get("/users/search", async (request) => {
    const { q } = parse(SearchQuery, request.query);
    return { users: ctx.users.search(request.user.id, q) };
  });

  app.put("/devices", async (request, reply) => {
    ctx.notifier.registerDevice(request.user.id, parse(RegisterDeviceBody, request.body));
    reply.code(204);
  });

  app.delete("/devices/:token", async (request, reply) => {
    ctx.notifier.unregisterDevice(request.user.id, request.params.token);
    reply.code(204);
  });
}
