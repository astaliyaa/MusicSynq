import { createPrivateKey, sign } from "node:crypto";
import http2 from "node:http2";

const HOSTS = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com",
};

// Apple rejects provider tokens older than an hour and throttles refreshing
// more often than every 20 minutes.
const TOKEN_LIFETIME_MS = 50 * 60 * 1000;

const base64url = (value) => Buffer.from(typeof value === "string" ? value : JSON.stringify(value)).toString("base64url");

/** Minimal APNs client using token (.p8) auth over HTTP/2. */
export class ApnsClient {
  constructor({ keyId, teamId, bundleId, privateKey }, log) {
    this.keyId = keyId;
    this.teamId = teamId;
    this.bundleId = bundleId;
    this.key = createPrivateKey(privateKey);
    this.log = log;
    this.sessions = new Map();
    this.jwt = null;
    this.jwtIssuedAt = 0;
  }

  providerToken() {
    const now = Date.now();
    if (!this.jwt || now - this.jwtIssuedAt > TOKEN_LIFETIME_MS) {
      const header = base64url({ alg: "ES256", kid: this.keyId });
      const claims = base64url({ iss: this.teamId, iat: Math.floor(now / 1000) });
      const signature = sign("sha256", Buffer.from(`${header}.${claims}`), { key: this.key, dsaEncoding: "ieee-p1363" });
      this.jwt = `${header}.${claims}.${signature.toString("base64url")}`;
      this.jwtIssuedAt = now;
    }
    return this.jwt;
  }

  session(environment) {
    let session = this.sessions.get(environment);
    if (!session || session.closed || session.destroyed) {
      session = http2.connect(HOSTS[environment]);
      session.on("error", (err) => this.log.warn({ err, environment }, "APNs connection error"));
      session.on("goaway", () => session.close());
      session.on("close", () => {
        if (this.sessions.get(environment) === session) this.sessions.delete(environment);
      });
      session.unref();
      this.sessions.set(environment, session);
    }
    return session;
  }

  /**
   * Sends one notification. Resolves to { ok, status, reason }; a `reason` of
   * BadDeviceToken / Unregistered means the token should be forgotten.
   */
  send({ token, environment }, payload, { collapseId } = {}) {
    return new Promise((resolve) => {
      let req;
      try {
        const headers = {
          ":method": "POST",
          ":path": `/3/device/${token}`,
          authorization: `bearer ${this.providerToken()}`,
          "apns-topic": this.bundleId,
          "apns-push-type": "alert",
          "apns-priority": "10",
        };
        if (collapseId) headers["apns-collapse-id"] = collapseId;
        req = this.session(environment).request(headers);
      } catch (err) {
        resolve({ ok: false, status: 0, reason: err.message });
        return;
      }
      let status = 0;
      let body = "";
      req.setEncoding("utf8");
      req.setTimeout(10_000, () => req.close(http2.constants.NGHTTP2_CANCEL));
      req.on("response", (headers) => {
        status = headers[":status"];
      });
      req.on("data", (chunk) => {
        body += chunk;
      });
      req.on("end", () => {
        let reason = null;
        if (body) {
          try {
            reason = JSON.parse(body).reason ?? null;
          } catch {
            reason = body;
          }
        }
        resolve({ ok: status === 200, status, reason });
      });
      req.on("error", (err) => resolve({ ok: false, status, reason: err.message }));
      req.end(JSON.stringify(payload));
    });
  }

  close() {
    for (const session of this.sessions.values()) session.close();
    this.sessions.clear();
  }
}
