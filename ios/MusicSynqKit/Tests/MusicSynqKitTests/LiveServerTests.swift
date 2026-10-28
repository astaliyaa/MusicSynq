import Foundation
import XCTest
@testable import MusicSynqKit

/**
 * Runs a whole party against a real server. Skipped unless
 * MUSICSYNQ_SERVER_URL is set, e.g.:
 *
 *     (cd server && npm start) &
 *     MUSICSYNQ_SERVER_URL=http://127.0.0.1:8080 swift test
 */
final class LiveServerTests: XCTestCase {
    var baseURL: URL!

    override func setUpWithError() throws {
        guard let raw = ProcessInfo.processInfo.environment["MUSICSYNQ_SERVER_URL"], let url = URL(string: raw) else {
            throw XCTSkip("Set MUSICSYNQ_SERVER_URL to run against a live server.")
        }
        baseURL = url
    }

    func signUp(_ prefix: String) async throws -> APIClient {
        let name = "\(prefix)\(Int.random(in: 100_000...999_999))"
        let auth = try await APIClient(baseURL: baseURL).register(username: name, displayName: prefix.capitalized, password: "correct horse battery")
        return APIClient(baseURL: baseURL, token: auth.token)
    }

    /**
     * Collects a connection's messages. `events` allows a single consumer, and
     * cancelling it ends the stream, so tests read from this buffer instead.
     */
    final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [ServerMessage] = []

        init(_ connection: RealtimeConnection) {
            Task { [weak self] in
                for await event in connection.events {
                    guard case let .message(message) = event else { continue }
                    self?.append(message)
                }
            }
        }

        private func append(_ message: ServerMessage) {
            lock.lock()
            defer { lock.unlock() }
            messages.append(message)
        }

        private func take<T>(_ match: (ServerMessage) -> T?) -> T? {
            lock.lock()
            defer { lock.unlock() }
            for (index, message) in messages.enumerated() {
                if let value = match(message) {
                    messages.remove(at: index)
                    return value
                }
            }
            return nil
        }

        /** Waits for the first message matching `match`, leaving others in place. */
        func next<T>(timeout: TimeInterval = 5, _ match: (ServerMessage) -> T?) async throws -> T {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let value = take(match) { return value }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            throw APIError(status: 0, code: "timeout", message: "timed out waiting for a message")
        }
    }

    /** Accounts, friends, and joining with a code: the REST half. Runs anywhere. */
    func testAccountsFriendsAndJoining() async throws {
        let host = try await signUp("host")
        let guest = try await signUp("guest")
        let hostMe = try await host.me()
        let guestMe = try await guest.me()

        let search = try await host.searchUsers(String(guestMe.username.prefix(8)))
        XCTAssertEqual(search.first(where: { $0.user.id == guestMe.id })?.relationship, Relationship.none)

        let request = try await host.sendFriendRequest(username: guestMe.username)
        XCTAssertEqual(request.status, "requested")
        let pending = try await guest.friends()
        XCTAssertEqual(pending.incoming.first?.from.id, hostMe.id)
        let friends = try await guest.acceptFriendRequest(id: try XCTUnwrap(request.request?.id))
        XCTAssertEqual(friends.friends.first?.user.id, hostMe.id)

        let party = try await host.startParty(allowGuestControl: true)
        let code = try XCTUnwrap(party.code)
        let visible = try await guest.friendsParties()
        XCTAssertEqual(visible.first?.id, party.id)
        XCTAssertEqual(visible.first?.host.id, hostMe.id)

        do {
            _ = try await guest.joinParty(partyID: party.id, code: "AAAAAA")
            XCTFail("wrong code should fail")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "wrong_code")
            XCTAssertEqual(error.status, 403)
        }

        // Ask-to-join, approved by the host.
        let ask = try await guest.requestToJoin(partyID: party.id)
        XCTAssertEqual(ask.status, .pending)
        let hostView = try await host.currentParty()
        XCTAssertEqual(hostView?.pendingRequests.first?.id, ask.id)
        let approved = try await host.answerJoinRequest(partyID: party.id, requestID: ask.id, approve: true)
        XCTAssertEqual(approved.status, .approved)
        let guestView = try await guest.currentParty()
        XCTAssertEqual(guestView?.role, .guest)
        XCTAssertNil(guestView?.code)

        try await guest.leaveParty(id: party.id)
        let rejoined = try await guest.joinParty(code: code.lowercased())
        XCTAssertEqual(rejoined.id, party.id)

        let updated = try await host.updateParty(id: party.id, allowGuestControl: false)
        XCTAssertFalse(updated.allowGuestControl)
        XCTAssertEqual(updated.members.first?.user.id, guestMe.id)

        try await host.endParty(id: party.id)
        let afterEnd = try await guest.currentParty()
        XCTAssertNil(afterEnd)

        try await guest.logout()
        do {
            _ = try await guest.me()
            XCTFail("signed out")
        } catch let error as APIError {
            XCTAssertTrue(error.isUnauthorized)
        }
    }

    /** The realtime half: clock sync, playback, controls, ending. */
    func testRealtimePartyFlow() async throws {
        #if os(Linux)
        // swift-corelibs-foundation needs a libcurl built with WebSocket support,
        // which most distributions don't ship. Run this one on a Mac.
        throw XCTSkip("URLSessionWebSocketTask isn't available on this Linux build.")
        #else
        let host = try await signUp("host")
        let guest = try await signUp("guest")
        let guestMe = try await guest.me()
        let request = try await host.sendFriendRequest(username: guestMe.username)
        _ = try await guest.acceptFriendRequest(id: try XCTUnwrap(request.request?.id))

        let hostSocket = RealtimeConnection(url: host.webSocketURL, token: host.token!)
        let hostInbox = Inbox(hostSocket)
        hostSocket.start()
        defer { hostSocket.stop() }
        _ = try await hostInbox.next { if case let .hello(_, user, _) = $0 { return user } else { return nil } }

        let party = try await host.startParty(allowGuestControl: true)
        _ = try await guest.joinParty(partyID: party.id, code: try XCTUnwrap(party.code))

        let guestSocket = RealtimeConnection(url: guest.webSocketURL, token: guest.token!)
        let guestInbox = Inbox(guestSocket)
        guestSocket.start()
        defer { guestSocket.stop() }
        let guestHello: Party? = try await guestInbox.next { if case let .hello(_, _, party) = $0 { return party } else { return nil } }
        XCTAssertEqual(guestHello?.id, party.id)

        // Let the clock sync settle.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(hostSocket.clock.isSynced)
        XCTAssertLessThan(abs(try XCTUnwrap(hostSocket.clock.offset)), 1_000)

        // Host plays a song; the guest's planner decides to load it.
        let track = Track(catalogId: "1440857781", isrc: "GBUM71029604", title: "Dancing Queen", artist: "ABBA", duration: 230)
        let state = PlaybackState(track: track, isPlaying: true, position: 12, timestamp: Int64(hostSocket.clock.serverNow()))
        hostSocket.send(.playback(state))
        let received: PlaybackState = try await guestInbox.next { if case let .playback(_, playback) = $0 { return playback } else { return nil } }
        XCTAssertEqual(received, state)

        var planner = GuestSyncPlanner()
        let action = planner.plan(for: received, local: LocalPlayerSnapshot(loadedKey: nil, isPlaying: false, position: 0), serverNow: guestSocket.clock.serverNow(), trigger: .hostUpdate)
        guard case .load(track, let position, true) = action else { return XCTFail("expected load, got \(action)") }
        XCTAssertEqual(position, 12.25, accuracy: 0.5)

        // Guest asks to pause; the host's app gets the control.
        guestSocket.send(.control(action: .pause, position: nil))
        let control: ControlAction = try await hostInbox.next { if case let .control(_, action, _, _) = $0 { return action } else { return nil } }
        XCTAssertEqual(control, .pause)

        // Host ends the party; the guest is told to stop.
        try await host.endParty(id: party.id)
        let reason: PartyEndReason = try await guestInbox.next { if case let .partyEnded(_, reason) = $0 { return reason } else { return nil } }
        XCTAssertEqual(reason, .hostEnded)
        #endif
    }
}
