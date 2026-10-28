import Foundation

/**
 * Estimates the difference between this device's clock and the server's, the
 * same way NTP does: ping the server, note the round trip, and assume the
 * server answered halfway through it. The sample with the shortest round trip
 * is the most trustworthy, so that's the one we use.
 *
 * Both friends measure against the same server clock, which is what lets a
 * guest work out exactly where the host's song is right now.
 */
public final class ClockSync: @unchecked Sendable {
    public struct Sample: Equatable, Sendable {
        /** Round-trip time in milliseconds. */
        public var rtt: Double
        /** serverTime - localTime, in milliseconds. */
        public var offset: Double
    }

    private let lock = NSLock()
    private var samples: [Sample] = []
    private var roughOffset: Double?
    private let maxSamples: Int

    public init(maxSamples: Int = 10) {
        self.maxSamples = maxSamples
    }

    /** Current wall-clock time on this device, in milliseconds. */
    public static func localNow() -> Double {
        Date().timeIntervalSince1970 * 1000
    }

    /**
     * Records one ping. `sentAt` is the local wall-clock time the ping left,
     * `rtt` how long the reply took, `serverTime` what the server stamped.
     */
    public func record(sentAt: Double, rtt: Double, serverTime: Double) {
        let offset = serverTime - (sentAt + rtt / 2)
        lock.lock()
        defer { lock.unlock() }
        samples.append(Sample(rtt: rtt, offset: offset))
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
    }

    /** A one-way timestamp (like the hello message's). Only used until a real ping lands. */
    public func recordRough(serverTime: Double, receivedAt: Double = ClockSync.localNow()) {
        lock.lock()
        defer { lock.unlock() }
        roughOffset = serverTime - receivedAt
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll()
        roughOffset = nil
    }

    private var bestSample: Sample? {
        samples.min(by: { $0.rtt < $1.rtt })
    }

    /** serverTime - localTime in milliseconds, or nil before any measurement. */
    public var offset: Double? {
        lock.lock()
        defer { lock.unlock() }
        return bestSample?.offset ?? roughOffset
    }

    /** The shortest round trip seen, in milliseconds. Half of it bounds the error of `offset`. */
    public var bestRTT: Double? {
        lock.lock()
        defer { lock.unlock() }
        return bestSample?.rtt
    }

    public var isSynced: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !samples.isEmpty
    }

    /** The server's clock right now, in milliseconds. */
    public func serverNow(localNow: Double = ClockSync.localNow()) -> Double {
        localNow + (offset ?? 0)
    }
}
