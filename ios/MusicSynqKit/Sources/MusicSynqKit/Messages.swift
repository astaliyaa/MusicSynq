import Foundation

/** Everything the server can push down the WebSocket (see server/src/realtime/hub.js). */
public enum ServerMessage: Sendable {
    /** First message on every connection. `party` is the party you're in, if any. */
    case hello(serverTime: Int64, user: User, party: Party?)
    case pong(id: Int?, clientTime: Double, serverTime: Int64)
    /** A fresh snapshot of the party you're in (members, requests, settings). */
    case partyUpdated(Party)
    /** Your party ended, or you're no longer in it. Stop the music. */
    case partyEnded(partyId: String, reason: PartyEndReason)
    /** The host's player changed (or a periodic heartbeat). Guests only. */
    case playback(partyId: String, playback: PlaybackState)
    /** Someone asked to join your party. Hosts only. */
    case joinRequest(JoinRequest)
    /** The host answered your request. `party` is set when you were let in. */
    case joinRequestUpdated(request: JoinRequest, party: Party?)
    /** A guest pressed a control. Hosts only: carry it out on your player. */
    case control(partyId: String, action: ControlAction, position: Double?, from: User)
    /** Something about your friends changed; refetch the list. */
    case friendsChanged(reason: String?, user: User?)
    case error(code: String, message: String)
    /** A message type this version of the app doesn't know about. */
    case unknown(type: String)
}

extension ServerMessage: Decodable {
    private enum Keys: String, CodingKey {
        case type, serverTime, user, party, id, clientTime, partyId, reason, playback, request
        case action, position, from, code, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "hello":
            self = .hello(
                serverTime: try c.decode(Int64.self, forKey: .serverTime),
                user: try c.decode(User.self, forKey: .user),
                party: try c.decodeIfPresent(Party.self, forKey: .party)
            )
        case "pong":
            self = .pong(
                id: try? c.decodeIfPresent(Int.self, forKey: .id),
                clientTime: try c.decode(Double.self, forKey: .clientTime),
                serverTime: try c.decode(Int64.self, forKey: .serverTime)
            )
        case "party.updated":
            self = .partyUpdated(try c.decode(Party.self, forKey: .party))
        case "party.ended":
            self = .partyEnded(
                partyId: try c.decode(String.self, forKey: .partyId),
                reason: try c.decode(PartyEndReason.self, forKey: .reason)
            )
        case "playback":
            self = .playback(
                partyId: try c.decode(String.self, forKey: .partyId),
                playback: try c.decode(PlaybackState.self, forKey: .playback)
            )
        case "join_request":
            self = .joinRequest(try c.decode(JoinRequest.self, forKey: .request))
        case "join_request.updated":
            self = .joinRequestUpdated(
                request: try c.decode(JoinRequest.self, forKey: .request),
                party: try c.decodeIfPresent(Party.self, forKey: .party)
            )
        case "control":
            self = .control(
                partyId: try c.decode(String.self, forKey: .partyId),
                action: try c.decode(ControlAction.self, forKey: .action),
                position: try c.decodeIfPresent(Double.self, forKey: .position),
                from: try c.decode(User.self, forKey: .from)
            )
        case "friends.changed":
            self = .friendsChanged(
                reason: try c.decodeIfPresent(String.self, forKey: .reason),
                user: try c.decodeIfPresent(User.self, forKey: .user)
            )
        case "error":
            self = .error(
                code: try c.decode(String.self, forKey: .code),
                message: try c.decode(String.self, forKey: .message)
            )
        default:
            self = .unknown(type: type)
        }
    }
}

/** Everything the app sends up the WebSocket. */
public enum ClientMessage: Sendable, Equatable {
    /** Clock sync. `clientTime` is echoed back in the pong. */
    case ping(id: Int, clientTime: Double)
    /** Host only: what the host's player is doing. */
    case playback(PlaybackState)
    /** Guest only: ask the host's app to play/pause/seek/skip. */
    case control(action: ControlAction, position: Double?)
}

extension ClientMessage: Encodable {
    private enum Keys: String, CodingKey {
        case type, id, clientTime, playback, action, position
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .ping(id, clientTime):
            try c.encode("ping", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(clientTime, forKey: .clientTime)
        case let .playback(state):
            try c.encode("playback", forKey: .type)
            try c.encode(state, forKey: .playback)
        case let .control(action, position):
            try c.encode("control", forKey: .type)
            try c.encode(action, forKey: .action)
            try c.encodeIfPresent(position, forKey: .position)
        }
    }
}
