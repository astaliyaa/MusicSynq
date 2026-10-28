import assert from "node:assert/strict";
import { generateKeyPairSync, verify } from "node:crypto";
import { test } from "node:test";
import { ApnsClient } from "../src/push/apns.js";

test("provider token is a valid ES256 JWT and is reused until it expires", () => {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const pem = privateKey.export({ type: "pkcs8", format: "pem" });
  const client = new ApnsClient({ keyId: "ABC123DEFG", teamId: "TEAM123456", bundleId: "com.example.app", privateKey: pem }, console);

  const token = client.providerToken();
  const [header, claims, signature] = token.split(".");
  assert.deepEqual(JSON.parse(Buffer.from(header, "base64url")), { alg: "ES256", kid: "ABC123DEFG" });
  const body = JSON.parse(Buffer.from(claims, "base64url"));
  assert.equal(body.iss, "TEAM123456");
  assert.ok(Math.abs(body.iat - Date.now() / 1000) < 5);
  const valid = verify("sha256", Buffer.from(`${header}.${claims}`), { key: publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(signature, "base64url"));
  assert.ok(valid);
  assert.equal(client.providerToken(), token);
});
