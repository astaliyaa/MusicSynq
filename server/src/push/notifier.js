import { ApnsClient } from "./apns.js";

const DEAD_TOKEN_REASONS = new Set(["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"]);

/**
 * Sends push notifications to every registered device of a user. Fire and
 * forget: callers never wait on Apple, and failures are only logged.
 */
export class Notifier {
  constructor(ctx) {
    this.ctx = ctx;
    this.apns = ctx.config.apns ? new ApnsClient(ctx.config.apns, ctx.log) : null;
    if (!this.apns) ctx.log.info("APNs is not configured; push notifications are disabled");
  }

  registerDevice(userId, { token, environment }) {
    this.ctx.db
      .prepare(
        `INSERT INTO devices (token, user_id, environment, updated_at) VALUES (?, ?, ?, ?)
         ON CONFLICT (token) DO UPDATE SET user_id = excluded.user_id, environment = excluded.environment, updated_at = excluded.updated_at`,
      )
      .run(token.toLowerCase(), userId, environment, Date.now());
  }

  unregisterDevice(userId, token) {
    this.ctx.db.prepare("DELETE FROM devices WHERE token = ? AND user_id = ?").run(token.toLowerCase(), userId);
  }

  /**
   * @param {string[]} userIds
   * @param {{ title: string, body: string, category?: string, threadId?: string, data?: object }} message
   */
  notify(userIds, { title, body, category, threadId, data = {} }) {
    if (!this.apns || userIds.length === 0) return;
    const placeholders = userIds.map(() => "?").join(",");
    const devices = this.ctx.db.prepare(`SELECT * FROM devices WHERE user_id IN (${placeholders})`).all(...userIds);
    const payload = {
      aps: {
        alert: { title, body },
        sound: "default",
        ...(category && { category }),
        ...(threadId && { "thread-id": threadId }),
      },
      ...data,
    };
    for (const device of devices) {
      this.apns.send(device, payload).then((result) => {
        if (result.ok) return;
        this.ctx.log.warn({ status: result.status, reason: result.reason, userId: device.user_id }, "push failed");
        if (DEAD_TOKEN_REASONS.has(result.reason) || result.status === 410) {
          this.ctx.db.prepare("DELETE FROM devices WHERE token = ?").run(device.token);
        }
      });
    }
  }

  close() {
    this.apns?.close();
  }
}
