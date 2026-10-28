import { createHash, randomBytes, randomInt, randomUUID, scrypt, timingSafeEqual } from "node:crypto";

export const newId = () => randomUUID();

/** Opaque session token handed to the app. Only its SHA-256 is stored. */
export const newSessionToken = () => randomBytes(32).toString("base64url");

export const hashToken = (token) => createHash("sha256").update(token).digest("hex");

// No 0/O or 1/I/L so codes are easy to read out loud over a call.
const CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
export const PARTY_CODE_LENGTH = 6;

export function newPartyCode() {
  let code = "";
  for (let i = 0; i < PARTY_CODE_LENGTH; i++) code += CODE_ALPHABET[randomInt(CODE_ALPHABET.length)];
  return code;
}

/** Uppercases and strips spaces/dashes so "k7q-f2m" matches "K7QF2M". */
export const normalizePartyCode = (code) => code.toUpperCase().replace(/[\s-]/g, "");

const SCRYPT = { N: 16384, r: 8, p: 1, keyLength: 64 };

function scryptAsync(password, salt, { N, r, p, keyLength }) {
  return new Promise((resolve, reject) => {
    scrypt(password, salt, keyLength, { N, r, p, maxmem: 64 * 1024 * 1024 }, (err, key) =>
      err ? reject(err) : resolve(key),
    );
  });
}

export async function hashPassword(password) {
  const salt = randomBytes(16);
  const key = await scryptAsync(password, salt, SCRYPT);
  return ["scrypt", SCRYPT.N, SCRYPT.r, SCRYPT.p, salt.toString("base64"), key.toString("base64")].join("$");
}

export async function verifyPassword(password, stored) {
  const [scheme, N, r, p, salt, hash] = stored.split("$");
  if (scheme !== "scrypt" || !salt || !hash) return false;
  const expected = Buffer.from(hash, "base64");
  const actual = await scryptAsync(password, Buffer.from(salt, "base64"), {
    N: Number(N),
    r: Number(r),
    p: Number(p),
    keyLength: expected.length,
  });
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

// Verified against when the username doesn't exist, so a failed login takes
// the same time whether or not the account is real.
export const DUMMY_PASSWORD_HASH = await hashPassword(randomBytes(16).toString("hex"));
