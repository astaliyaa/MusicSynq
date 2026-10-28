import Foundation

/**
 * Decides when the host's app should tell the server what it's playing.
 *
 * The host's app polls its player a couple of times a second. Sending every
 * poll would be wasteful, so we only send when something a guest would notice
 * changed: a different song, play/pause, a seek (the playhead jumped away from
 * where it should be), plus a regular heartbeat that keeps guests from
 * drifting and gives late joiners a fresh position.
 */
public struct HostReportPolicy: Sendable {
    /** Seconds between heartbeats while playing. */
    public var playingHeartbeat: Double
    /** Seconds between heartbeats while paused or stopped. */
    public var pausedHeartbeat: Double
    /** A playhead this far (seconds) from where we predicted counts as a seek. */
    public var seekThreshold: Double

    public private(set) var lastSent: PlaybackState?
    private var lastSentAt: Double?

    public init(playingHeartbeat: Double = 5, pausedHeartbeat: Double = 20, seekThreshold: Double = 1.5) {
        self.playingHeartbeat = playingHeartbeat
        self.pausedHeartbeat = pausedHeartbeat
        self.seekThreshold = seekThreshold
    }

    /** Forget what was sent, so the next observation goes out (e.g. after reconnecting). */
    public mutating func reset() {
        lastSent = nil
        lastSentAt = nil
    }

    /**
     * Returns true if `observed` should be sent, and if so remembers it as sent.
     * `observed.timestamp` must be the server time (ms) the observation was taken.
     */
    public mutating func shouldSend(_ observed: PlaybackState) -> Bool {
        let now = Double(observed.timestamp)
        guard let last = lastSent, let sentAt = lastSentAt else { return markSent(observed) }

        if last.track?.matchKey != observed.track?.matchKey { return markSent(observed) }
        if last.isPlaying != observed.isPlaying { return markSent(observed) }

        let predicted = last.position(atServerTime: now)
        if abs(predicted - observed.position) > seekThreshold { return markSent(observed) }

        let heartbeat = observed.isPlaying ? playingHeartbeat : pausedHeartbeat
        if (now - sentAt) / 1000 >= heartbeat { return markSent(observed) }
        return false
    }

    private mutating func markSent(_ state: PlaybackState) -> Bool {
        lastSent = state
        lastSentAt = Double(state.timestamp)
        return true
    }
}
