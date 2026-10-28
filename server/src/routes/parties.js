import { JoinWithCodeBody, parse, StartPartyBody, UpdatePartyBody } from "../protocol.js";

export async function partyRoutes(app, { ctx }) {
  const { parties } = ctx;
  const view = (party, request) => ({ party: parties.serializeFor(party, request.user.id) });

  /** The party you're in right now (as host or guest), or null. */
  app.get("/parties/current", async (request) => {
    const party = parties.currentFor(request.user.id);
    return { party: party ? parties.serializeFor(party, request.user.id) : null };
  });

  /** Live parties hosted by your friends. */
  app.get("/parties/friends", async (request) => ({ parties: parties.listForFriends(request.user.id) }));

  /** Start hosting. Returns your existing party if you already have one. */
  app.post("/parties", async (request, reply) => {
    const body = parse(StartPartyBody, request.body ?? {});
    const party = parties.start(request.user, body);
    reply.code(201);
    return view(party, request);
  });

  /** Join with just the code the host read out. */
  app.post("/parties/join", async (request) => {
    const { code } = parse(JoinWithCodeBody, request.body);
    return view(parties.joinWithCode(request.user, { code }), request);
  });

  /** Join a specific friend's party with its code. */
  app.post("/parties/:id/join", async (request) => {
    const { code } = parse(JoinWithCodeBody, request.body);
    return view(parties.joinWithCode(request.user, { partyId: request.params.id, code }), request);
  });

  app.patch("/parties/:id", async (request) => {
    const body = parse(UpdatePartyBody, request.body);
    return view(parties.update(request.user.id, request.params.id, body), request);
  });

  /** The host ends the party. Everyone's music stops. */
  app.delete("/parties/:id", async (request, reply) => {
    parties.requireHost(request.user.id, request.params.id);
    parties.end(request.params.id, "host_ended");
    reply.code(204);
  });

  /** A guest leaves. Their music stops; the party carries on. */
  app.post("/parties/:id/leave", async (request, reply) => {
    parties.leave(request.user.id, request.params.id);
    reply.code(204);
  });

  /** Ask the host to let you in (instead of typing the code). */
  app.post("/parties/:id/requests", async (request, reply) => {
    reply.code(201);
    return { request: parties.requestToJoin(request.user, request.params.id) };
  });

  app.delete("/parties/:id/requests/:requestId", async (request) => ({
    request: parties.cancelRequest(request.user, request.params.id, request.params.requestId),
  }));

  app.post("/parties/:id/requests/:requestId/approve", async (request) => ({
    request: parties.resolveRequest(request.user, request.params.id, request.params.requestId, true),
  }));

  app.post("/parties/:id/requests/:requestId/decline", async (request) => ({
    request: parties.resolveRequest(request.user, request.params.id, request.params.requestId, false),
  }));

  /** The host removes a guest. */
  app.delete("/parties/:id/members/:userId", async (request, reply) => {
    parties.kick(request.user.id, request.params.id, request.params.userId);
    reply.code(204);
  });
}
