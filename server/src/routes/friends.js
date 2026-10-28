import { FriendRequestBody, parse } from "../protocol.js";

export async function friendRoutes(app, { ctx }) {
  app.get("/friends", async (request) => ctx.friends.list(request.user.id));

  // Responds with status "requested", or "accepted" if they had already asked us.
  app.post("/friends/requests", async (request, reply) => {
    const { username } = parse(FriendRequestBody, request.body);
    const result = ctx.friends.sendRequest(request.user, username);
    reply.code(result.status === "requested" ? 201 : 200);
    return result;
  });

  app.post("/friends/requests/:id/accept", async (request) => {
    ctx.friends.accept(request.user, request.params.id);
    return ctx.friends.list(request.user.id);
  });

  // Declines a request sent to you, or cancels one you sent.
  app.delete("/friends/requests/:id", async (request) => {
    ctx.friends.removeRequest(request.user, request.params.id);
    return ctx.friends.list(request.user.id);
  });

  app.delete("/friends/:userId", async (request) => {
    ctx.friends.remove(request.user, request.params.userId);
    return ctx.friends.list(request.user.id);
  });
}
