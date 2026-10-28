import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/**
 * The app's live connection to the server. Reconnects on its own with backoff,
 * keeps `clock` in sync with the server, and delivers everything through
 * `events`, which has exactly one consumer.
 */
public final class RealtimeConnection: @unchecked Sendable {
    public enum Event: Sendable {
        case connected
        case message(ServerMessage)
        /** The connection dropped; it retries on its own. */
        case disconnected
        /** The server rejected our token. The connection has stopped; sign in again. */
        case unauthorized
    }

    public let clock = ClockSync()
    public let events: AsyncStream<Event>

    private let continuation: AsyncStream<Event>.Continuation
    private let url: URL
    private let token: String
    private let session: URLSession

    private let lock = NSLock()
    private var socket: URLSessionWebSocketTask?
    private var runner: Task<Void, Never>?
    private var nextPingID = 0
    private var pendingPings: [Int: (wallClock: Double, uptime: TimeInterval)] = [:]
    private var connected = false
    private var skipBackoff = false

    public init(url: URL, token: String, session: URLSession = .shared) {
        self.url = url
        self.token = token
        self.session = session
        (events, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
    }

    deinit {
        runner?.cancel()
        continuation.finish()
    }

    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return connected
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard runner == nil else { return }
        runner = Task { [weak self] in await self?.run() }
    }

    /** Disconnects for good and finishes `events`. */
    public func stop() {
        lock.lock()
        let runner = self.runner
        let socket = self.socket
        self.runner = nil
        self.socket = nil
        connected = false
        lock.unlock()
        runner?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        continuation.finish()
    }

    /**
     * Drops the current socket and reconnects right away, skipping any backoff.
     * Call it when the app comes back to the foreground, where the old socket
     * may have silently died.
     */
    public func reconnectNow() {
        lock.lock()
        let socket = self.socket
        skipBackoff = true
        lock.unlock()
        socket?.cancel(with: .goingAway, reason: nil)
    }

    /** Fire and forget. Messages sent while disconnected are dropped. */
    public func send(_ message: ClientMessage) {
        lock.lock()
        let socket = connected ? self.socket : nil
        lock.unlock()
        guard let socket, let data = try? JSONEncoder().encode(message), let text = String(data: data, encoding: .utf8) else { return }
        Task { try? await socket.send(.string(text)) }
    }

    // MARK: - Connection loop

    private func run() async {
        var failures = 0
        while !Task.isCancelled {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let socket = session.webSocketTask(with: request)
            setSocket(socket)
            socket.resume()

            var pinger: Task<Void, Never>?
            do {
                // The server always says hello first; until it does, we aren't really connected.
                let hello = try await socket.receive()
                failures = 0
                setConnected(true)
                continuation.yield(.connected)
                handle(hello)
                pinger = Task { [weak self] in await self?.pingLoop() }
                while !Task.isCancelled {
                    handle(try await socket.receive())
                }
            } catch {
                if (socket.response as? HTTPURLResponse)?.statusCode == 401 {
                    pinger?.cancel()
                    setConnected(false)
                    continuation.yield(.unauthorized)
                    return
                }
            }
            pinger?.cancel()
            socket.cancel(with: .goingAway, reason: nil)
            let wasConnected = setConnected(false)
            if wasConnected { continuation.yield(.disconnected) }
            if Task.isCancelled { return }

            failures += 1
            if !takeSkipBackoff() {
                // 1s, 2s, 4s ... up to 30s, with jitter so a server restart isn't stampeded.
                let delay = min(30, pow(2, Double(min(failures - 1, 5)))) * Double.random(in: 0.8...1.2)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    // Small synchronous helpers: NSLock can't be held across an `await`.

    private func setSocket(_ socket: URLSessionWebSocketTask) {
        lock.lock()
        defer { lock.unlock() }
        self.socket = socket
    }

    private func takeSkipBackoff() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let value = skipBackoff
        skipBackoff = false
        return value
    }

    @discardableResult
    private func setConnected(_ value: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let old = connected
        connected = value
        if !value { pendingPings.removeAll() }
        return old
    }

    private func handle(_ frame: URLSessionWebSocketTask.Message) {
        let data: Data
        switch frame {
        case let .string(text): data = Data(text.utf8)
        case let .data(bytes): data = bytes
        @unknown default: return
        }
        guard let message = try? JSONDecoder().decode(ServerMessage.self, from: data) else { return }

        switch message {
        case let .hello(serverTime, _, _):
            clock.recordRough(serverTime: Double(serverTime))
        case let .pong(id, _, serverTime):
            lock.lock()
            let ping = id.flatMap { pendingPings.removeValue(forKey: $0) }
            lock.unlock()
            if let ping {
                let rtt = (ProcessInfo.processInfo.systemUptime - ping.uptime) * 1000
                clock.record(sentAt: ping.wallClock, rtt: rtt, serverTime: Double(serverTime))
            }
            return // Internal; nobody else needs pongs.
        default:
            break
        }
        continuation.yield(.message(message))
    }

    /** A quick burst of pings to sync the clock, then one every 15 seconds to track drift. */
    private func pingLoop() async {
        for index in 0... {
            guard !Task.isCancelled, isConnected else { return }
            sendPing()
            let seconds: Double = index < 5 ? 0.3 : 15
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    private func sendPing() {
        lock.lock()
        nextPingID += 1
        let id = nextPingID
        let wallClock = ClockSync.localNow()
        pendingPings[id] = (wallClock, ProcessInfo.processInfo.systemUptime)
        // Forget pings that never came back.
        pendingPings = pendingPings.filter { $0.key > id - 20 }
        lock.unlock()
        send(.ping(id: id, clientTime: wallClock))
    }
}
