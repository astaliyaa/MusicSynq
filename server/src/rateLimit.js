import { tooManyRequests } from "./errors.js";

/** Fixed-window, in-memory limiter. Good enough for a single server process. */
export class RateLimiter {
  constructor({ limit, windowMs }) {
    this.limit = limit;
    this.windowMs = windowMs;
    this.hits = new Map();
  }

  /** Records a hit for `key`; throws a 429 once `limit` hits land inside one window. */
  hit(key, message = "Too many attempts. Try again in a few minutes.") {
    const now = Date.now();
    let entry = this.hits.get(key);
    if (!entry || now >= entry.resetAt) {
      entry = { count: 0, resetAt: now + this.windowMs };
      this.hits.set(key, entry);
    }
    entry.count++;
    if (entry.count > this.limit) throw tooManyRequests(message);
    if (this.hits.size > 10_000) this.sweep(now);
  }

  reset(key) {
    this.hits.delete(key);
  }

  sweep(now = Date.now()) {
    for (const [key, entry] of this.hits) if (now >= entry.resetAt) this.hits.delete(key);
  }
}
