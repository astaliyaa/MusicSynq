import Foundation
import XCTest
@testable import MusicSynqKit

/** JSON in these tests is copied from what server/src produces. */
final class ProtocolTests: XCTestCase {
    func decode(_ json: String) throws -> ServerMessage {
        try JSONDecoder().decode(ServerMessage.self, from: Data(json.utf8))
    }

    let partyJSON = """
    {"id":"p1","role":"host","code":"K7QF2M",
     "host":{"id":"u1","username":"alex","displayName":"Alex"},"hostConnected":true,
     "allowGuestControl":true,"createdAt":1793175785793,
     "members":[{"user":{"id":"u2","username":"sam","displayName":"Sam Lee"},"joinedAt":1793175785800,"connected":false}],
     "pendingRequests":[{"id":"r1","partyId":"p1","user":{"id":"u3","username":"kim","displayName":"Kim"},"status":"pending","createdAt":1793175785900}],
     "playback":{"track":{"catalogId":"1440857781","isrc":"GBUM71029604","title":"Dancing Queen","artist":"ABBA","album":"Arrival","duration":230.4,"artworkUrl":"https://is1-ssl.mzstatic.com/a.jpg"},
                 "isPlaying":true,"position":42.5,"timestamp":1793175785793,"rate":1}}
    """

    func testDecodesHelloWithParty() throws {
        let message = try decode(#"{"type":"hello","serverTime":1793175785793,"user":{"id":"u1","username":"alex","displayName":"Alex"},"party":\#(partyJSON)}"#)
        guard case let .hello(serverTime, user, party?) = message else { return XCTFail("expected hello with party, got \(message)") }
        XCTAssertEqual(serverTime, 1_793_175_785_793)
        XCTAssertEqual(user.username, "alex")
        XCTAssertTrue(party.isHost)
        XCTAssertEqual(party.code, "K7QF2M")
        XCTAssertEqual(party.members.first?.user.initials, "SL")
        XCTAssertEqual(party.members.first?.connected, false)
        XCTAssertEqual(party.pendingRequests.first?.status, .pending)
        XCTAssertEqual(party.playback?.track?.matchKey, "id:1440857781")
        XCTAssertEqual(party.playback?.track?.artworkURL?.host, "is1-ssl.mzstatic.com")
    }

    func testDecodesHelloWithoutParty() throws {
        let message = try decode(#"{"type":"hello","serverTime":1,"user":{"id":"u1","username":"a","displayName":"A"},"party":null}"#)
        guard case .hello(_, _, nil) = message else { return XCTFail("expected hello without party") }
    }

    func testDecodesGuestPartyWithNullCodeAndNullishTrackFields() throws {
        let json = """
        {"type":"party.updated","party":{"id":"p1","role":"guest","code":null,
         "host":{"id":"u1","username":"alex","displayName":"Alex"},"hostConnected":false,"allowGuestControl":false,
         "createdAt":1,"members":[],"pendingRequests":[],
         "playback":{"track":{"title":"Demo","artist":"Me","catalogId":null},"isPlaying":false,"position":0,"timestamp":5,"rate":1}}}
        """
        guard case let .partyUpdated(party) = try decode(json) else { return XCTFail() }
        XCTAssertEqual(party.role, .guest)
        XCTAssertNil(party.code)
        XCTAssertEqual(party.playback?.track?.matchKey, "meta:demo|me")
    }

    func testDecodesEveryOtherServerMessage() throws {
        let user = #"{"id":"u2","username":"sam","displayName":"Sam"}"#
        let request = #"{"id":"r1","partyId":"p1","user":\#(user),"status":"approved","createdAt":3}"#

        guard case .partyEnded("p1", .hostDisconnected) = try decode(#"{"type":"party.ended","partyId":"p1","reason":"host_disconnected"}"#) else { return XCTFail() }
        guard case .partyEnded(_, .unknown) = try decode(#"{"type":"party.ended","partyId":"p1","reason":"meteor"}"#) else { return XCTFail() }

        guard case let .playback("p1", state) = try decode(#"{"type":"playback","partyId":"p1","playback":{"track":null,"isPlaying":false,"position":3,"timestamp":9,"rate":1}}"#) else { return XCTFail() }
        XCTAssertNil(state.track)

        guard case let .joinRequest(req) = try decode(#"{"type":"join_request","request":\#(request)}"#) else { return XCTFail() }
        XCTAssertEqual(req.status, .approved)

        guard case .joinRequestUpdated(_, nil) = try decode(#"{"type":"join_request.updated","request":\#(request),"party":null}"#) else { return XCTFail() }

        guard case let .control("p1", .seek, position, from) = try decode(#"{"type":"control","partyId":"p1","action":"seek","position":95,"from":\#(user)}"#) else { return XCTFail() }
        XCTAssertEqual(position, 95)
        XCTAssertEqual(from.id, "u2")
        guard case .control(_, .pause, nil, _) = try decode(#"{"type":"control","partyId":"p1","action":"pause","position":null,"from":\#(user)}"#) else { return XCTFail() }

        guard case .friendsChanged("party_started", _?) = try decode(#"{"type":"friends.changed","reason":"party_started","user":\#(user)}"#) else { return XCTFail() }
        guard case .friendsChanged("friend_removed", nil) = try decode(#"{"type":"friends.changed","reason":"friend_removed"}"#) else { return XCTFail() }

        guard case .pong(7, 123, 456) = try decode(#"{"type":"pong","id":7,"clientTime":123,"serverTime":456}"#) else { return XCTFail() }
        guard case .error("control_not_allowed", _) = try decode(#"{"type":"error","code":"control_not_allowed","message":"No."}"#) else { return XCTFail() }
        guard case .unknown("something.new") = try decode(#"{"type":"something.new","x":1}"#) else { return XCTFail() }
    }

    func testDecodesFriendsList() throws {
        let json = """
        {"friends":[{"user":{"id":"u1","username":"alex","displayName":"Alex"},"online":true,
                     "party":{"id":"p1","host":{"id":"u1","username":"alex","displayName":"Alex"},"memberCount":2,"createdAt":1,
                              "nowPlaying":null,"isPlaying":false,"myRequest":null}}],
         "incoming":[{"id":"f1","from":{"id":"u3","username":"kim","displayName":"Kim"},"to":{"id":"u0","username":"me","displayName":"Me"},"createdAt":2}],
         "outgoing":[]}
        """
        let list = try JSONDecoder().decode(FriendsList.self, from: Data(json.utf8))
        XCTAssertEqual(list.friends.first?.party?.memberCount, 2)
        XCTAssertEqual(list.incoming.first?.from.username, "kim")
    }

    func testEncodesClientMessagesTheWayTheServerExpects() throws {
        func object(_ message: ClientMessage) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as! [String: Any]
        }

        let ping = try object(.ping(id: 3, clientTime: 1000.5))
        XCTAssertEqual(ping["type"] as? String, "ping")
        XCTAssertEqual(ping["id"] as? Int, 3)

        // Nothing playing: the server requires "track": null, not a missing key.
        let idle = try object(.playback(PlaybackState(track: nil, isPlaying: false, position: 0, timestamp: 1_793_175_785_793)))
        let playback = try XCTUnwrap(idle["playback"] as? [String: Any])
        XCTAssertTrue(playback.keys.contains("track"))
        XCTAssertTrue(playback["track"] is NSNull)
        XCTAssertEqual((playback["timestamp"] as? NSNumber)?.int64Value, 1_793_175_785_793)

        let seek = try object(.control(action: .seek, position: 12))
        XCTAssertEqual(seek["action"] as? String, "seek")
        XCTAssertEqual(seek["position"] as? Double, 12)
        XCTAssertNil(try object(.control(action: .pause, position: nil))["position"])
    }

    func testPositionExtrapolation() {
        let track = TrackInfo(title: "T", artist: "A", duration: 100)
        let playing = PlaybackState(track: track, isPlaying: true, position: 10, timestamp: 1_000_000)
        XCTAssertEqual(playing.position(atServerTime: 1_002_500), 12.5, accuracy: 0.0001)
        XCTAssertEqual(playing.position(atServerTime: 1_500_000), 100, "clamped to the song length")
        let paused = PlaybackState(track: track, isPlaying: false, position: 10, timestamp: 1_000_000)
        XCTAssertEqual(paused.position(atServerTime: 1_900_000), 10)
    }

    func testMatchKeyPrefersCatalogID() {
        XCTAssertEqual(TrackInfo(catalogId: "1", isrc: "x", title: "T", artist: "A").matchKey, "id:1")
        XCTAssertEqual(TrackInfo(catalogId: "", isrc: "abc", title: "T", artist: "A").matchKey, "isrc:ABC")
        XCTAssertEqual(TrackInfo(title: "Tí", artist: "A").matchKey, "meta:tí|a")
    }
}
