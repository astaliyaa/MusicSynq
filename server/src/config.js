import { readFileSync } from "node:fs";

function int(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  const value = Number.parseInt(raw, 10);
  if (!Number.isFinite(value)) throw new Error(`${name} must be an integer, got "${raw}"`);
  return value;
}

/** APNs is optional: without it, notifications only reach users whose app is open. */
function loadApns() {
  const keyId = process.env.APNS_KEY_ID;
  const teamId = process.env.APNS_TEAM_ID;
  const bundleId = process.env.APNS_BUNDLE_ID;
  let privateKey = process.env.APNS_PRIVATE_KEY;
  const keyPath = process.env.APNS_PRIVATE_KEY_PATH;
  if (!privateKey && keyPath) privateKey = readFileSync(keyPath, "utf8");
  if (!keyId || !teamId || !bundleId || !privateKey) return null;
  // Allow the .p8 key to be passed in a single-line env var with literal "\n" sequences.
  return { keyId, teamId, bundleId, privateKey: privateKey.replace(/\\n/g, "\n") };
}

export function loadConfig() {
  return {
    host: process.env.HOST ?? "0.0.0.0",
    port: int("PORT", 8080),
    databasePath: process.env.DATABASE_PATH ?? "data/musicsynq.db",
    /** How long a party survives after the host's app loses its connection. */
    hostGraceMs: int("HOST_GRACE_SECONDS", 120) * 1000,
    /** How long a disconnected guest stays in a party before being removed. */
    guestGraceMs: int("GUEST_GRACE_SECONDS", 600) * 1000,
    /** Interval for WebSocket keep-alive pings sent by the server. */
    socketPingIntervalMs: int("SOCKET_PING_SECONDS", 20) * 1000,
    /** Per IP address. */
    signupsPerHour: int("SIGNUPS_PER_HOUR", 10),
    /** Per IP address and username. */
    loginAttemptsPer15Min: int("LOGIN_ATTEMPTS_PER_15_MIN", 20),
    apns: loadApns(),
    logLevel: process.env.LOG_LEVEL ?? "info",
  };
}
