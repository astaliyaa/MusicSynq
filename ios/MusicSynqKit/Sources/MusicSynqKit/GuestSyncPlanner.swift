import Foundation

/** What the guest's player is doing right now. */
public struct LocalPlayerSnapshot: Equatable, Sendable {
    /** `TrackInfo.matchKey` of the song loaded in the guest's player, if any. */
    public var loadedKey: String?
    public var isPlaying: Bool
    /** Seconds. */
    public var position: Double

    public init(loadedKey: String?, isPlaying: Bool, position: Double) {
        self.loadedKey = loadedKey
        self.isPlaying = isPlaying
        self.position = position
    }
}

/** One step for the guest's player to take. Positions are in seconds. */
public enum SyncAction: Equatable, Sendable {
    case none
    /** Host isn't playing anything: stop. */
    case stop
    /** Load a different song, start at `position`, and play if `play`. */
    case load(TrackInfo, position: Double, play: Bool)
    case play(seekTo: Double?)
    case pause(seekTo: Double?)
    case seek(to: Double)
    /** The host's song can't be played here (not in this country's catalog, say). Stay quiet. */
    case unavailable(TrackInfo)
}

/**
 * Decides how a guest's player should react to the host's state. It holds no
 * player itself: the app asks it what to do and carries the action out, which
 * keeps every timing rule here, where it can be tested.
 *
 * Call `plan(for:local:serverNow:trigger:)` whenever the host's state arrives
 * (`.hostUpdate`) and on a timer (`.tick`, about once a second).
 */
public struct GuestSyncPlanner: Sendable {
    public enum Trigger: Sendable {
        /** New state from the host: act on it immediately. */
        case hostUpdate
        /** Periodic drift check: only correct if things have settled. */
        case tick
    }

    /** Drift (seconds) we put up with before seeking. Seeks are audible, so not too tight. */
    public var tolerance: Double
    /** After any correction, wait this long (seconds) before the next timer-driven one. */
    public var cooldown: Double
    /** Don't bother correcting this close (seconds) to the end of a song. */
    public var endGuard: Double
    /**
     * How far ahead (seconds) to aim when seeking a playing song, to make up
     * for the time the player takes to start. Learned from each correction.
     */
    public private(set) var lead: Double
    public var leadRange: ClosedRange<Double>

    /** Songs this device couldn't find in its catalog, by `TrackInfo.matchKey`. */
    public var unavailableKeys: Set<String> = []

    private var lastCorrectionAt: Double?
    private var pendingLeadMeasurement: Double?

    public init(tolerance: Double = 0.6, cooldown: Double = 4, endGuard: Double = 2, initialLead: Double = 0.25, leadRange: ClosedRange<Double> = 0...2) {
        self.tolerance = tolerance
        self.cooldown = cooldown
        self.endGuard = endGuard
        self.lead = initialLead
        self.leadRange = leadRange
    }

    /** Forget timing history, e.g. after leaving a party. Keeps the learned lead. */
    public mutating func reset() {
        lastCorrectionAt = nil
        pendingLeadMeasurement = nil
        unavailableKeys.removeAll()
    }

    /**
     * - Parameters:
     *   - target: the host's latest state, or nil if we don't have one yet.
     *   - local: what the guest's player is doing.
     *   - serverNow: current server time in milliseconds (see `ClockSync`).
     */
    public mutating func plan(for target: PlaybackState?, local: LocalPlayerSnapshot, serverNow: Double, trigger: Trigger) -> SyncAction {
        let now = serverNow / 1000

        guard let target, let track = target.track else {
            return local.loadedKey != nil || local.isPlaying ? .stop : .none
        }

        if unavailableKeys.contains(track.matchKey) {
            return local.isPlaying ? .unavailable(track) : .none
        }

        let expected = target.position(atServerTime: serverNow)

        if local.loadedKey != track.matchKey {
            // Loading takes a while (network, buffering), so after it finishes the
            // app plans again with fresh numbers; that follow-up does the precise seek.
            let start = target.isPlaying ? expected + lead : expected
            return corrected(.load(track, position: clamp(start, track), play: target.isPlaying), at: now, measuring: false)
        }

        let settled = lastCorrectionAt.map { now - $0 >= cooldown } ?? true
        if trigger == .tick && !settled { return .none }

        if trigger == .tick && local.isPlaying && target.isPlaying {
            learnLead(drift: local.position - expected)
        }

        let drift = local.position - expected
        let nearEnd = track.duration.map { expected >= $0 - endGuard } ?? false

        if target.isPlaying != local.isPlaying {
            if target.isPlaying {
                // Our copy of the song ended a moment before the host's did. Playing
                // now would restart it; the host's next song is about to arrive.
                if nearEnd { return .none }
                let seek = abs(drift) > tolerance ? clamp(expected + lead, track) : nil
                return corrected(.play(seekTo: seek), at: now, measuring: seek != nil)
            }
            // Pausing: line up exactly with where the host stopped.
            let seek = abs(local.position - target.position) > 0.25 ? clamp(target.position, track) : nil
            return corrected(.pause(seekTo: seek), at: now, measuring: false)
        }

        if target.isPlaying {
            guard abs(drift) > tolerance, !nearEnd else { return .none }
            return corrected(.seek(to: clamp(expected + lead, track)), at: now)
        }

        // Both paused: follow the host's scrubbing.
        guard abs(local.position - target.position) > 0.5 else { return .none }
        return corrected(.seek(to: clamp(target.position, track)), at: now, measuring: false)
    }

    private mutating func corrected(_ action: SyncAction, at now: Double, measuring: Bool = true) -> SyncAction {
        lastCorrectionAt = now
        pendingLeadMeasurement = measuring ? lead : nil
        return action
    }

    /**
     * After a seek we aimed `lead` seconds ahead. Once settled, any remaining
     * drift says how wrong that was: behind means we needed more lead.
     */
    private mutating func learnLead(drift: Double) {
        guard let usedLead = pendingLeadMeasurement else { return }
        pendingLeadMeasurement = nil
        // A huge drift means something else happened (host seeked, stall); don't learn from it.
        guard abs(drift) < 3 else { return }
        let ideal = usedLead - drift
        lead = min(max(lead + (ideal - lead) * 0.5, leadRange.lowerBound), leadRange.upperBound)
    }

    private func clamp(_ position: Double, _ track: TrackInfo) -> Double {
        var value = max(0, position)
        if let duration = track.duration, duration > 0 { value = min(value, max(0, duration - 0.5)) }
        return value
    }
}
