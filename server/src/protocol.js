import { z } from "zod";
import { badRequest } from "./errors.js";

// ----------------------------------------------------------------- REST bodies

export const username = z
  .string()
  .trim()
  .min(3, "Usernames need at least 3 characters.")
  .max(20, "Usernames can be at most 20 characters.")
  .regex(/^[A-Za-z0-9_.]+$/, "Usernames can only use letters, numbers, dots and underscores.");

export const displayName = z.string().trim().min(1, "Enter a display name.").max(40, "Display names can be at most 40 characters.");

export const password = z
  .string()
  .min(8, "Passwords need at least 8 characters.")
  .max(200, "Passwords can be at most 200 characters.");

export const RegisterBody = z.object({ username, displayName, password });
export const LoginBody = z.object({ username: z.string().trim().min(1), password: z.string().min(1) });
export const UpdateMeBody = z.object({ displayName });
export const DeleteMeBody = z.object({ password: z.string().min(1) });
export const SearchQuery = z.object({ q: z.string().trim().min(1).max(20) });
export const FriendRequestBody = z.object({ username: z.string().trim().min(1).max(20) });
export const StartPartyBody = z.object({ allowGuestControl: z.boolean().optional() }).default({});
export const UpdatePartyBody = z.object({ allowGuestControl: z.boolean().optional() });
export const JoinWithCodeBody = z.object({ code: z.string().trim().min(4).max(12) });
export const RegisterDeviceBody = z.object({
  token: z.string().regex(/^[0-9a-fA-F]{32,200}$/, "Device tokens are hex strings."),
  environment: z.enum(["sandbox", "production"]),
});

// ------------------------------------------------------------ socket messages

const https = z
  .string()
  .max(2000)
  .refine((s) => s.startsWith("https://"), "Must be an https URL.");

/** Enough for any guest to find the same song in their own storefront. */
export const Track = z.object({
  catalogId: z.string().max(64).nullish(),
  isrc: z.string().max(32).nullish(),
  title: z.string().max(500),
  artist: z.string().max(500),
  album: z.string().max(500).nullish(),
  duration: z.number().nonnegative().max(86_400).nullish(),
  artworkUrl: https.nullish(),
});

/**
 * Where the host's player is. `position` (seconds) was measured at `timestamp`
 * (server-clock milliseconds), so anyone can work out where it is now.
 */
export const PlaybackState = z.object({
  track: Track.nullable(),
  isPlaying: z.boolean(),
  position: z.number().min(0).max(86_400),
  timestamp: z.number().int().nonnegative(),
  rate: z.number().min(0).max(4).default(1),
});

export const ControlAction = z.enum(["play", "pause", "seek", "next", "previous"]);

export const ClientMessage = z.discriminatedUnion("type", [
  z.object({ type: z.literal("ping"), id: z.union([z.string().max(64), z.number()]).optional(), clientTime: z.number() }),
  z.object({ type: z.literal("playback"), playback: PlaybackState }),
  z.object({ type: z.literal("control"), action: ControlAction, position: z.number().min(0).max(86_400).nullish() }),
]);

/** Parses `data` or throws a 400 carrying the first validation message. */
export function parse(schema, data) {
  const result = schema.safeParse(data);
  if (result.success) return result.data;
  const issue = result.error.issues[0];
  const field = issue?.path.join(".");
  throw badRequest("invalid_request", field ? `${field}: ${issue.message}` : issue?.message ?? "Invalid request.");
}
