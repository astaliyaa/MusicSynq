import Foundation

// These types mirror the JSON the server sends (see server/src/services/*.js).
// Timestamps are milliseconds since 1970 on the server's clock.

public struct User: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var username: String
    public var displayName: String

    public init(id: String, username: String, displayName: String) {
        self.id = id
        self.username = username
        self.displayName = displayName
    }

    /** One or two letters for an avatar. */
    public var initials: String {
        let words = displayName.split(separator: " ").prefix(2)
        let letters = words.compactMap(\.first).map(String.init).joined()
        return (letters.isEmpty ? String(username.prefix(1)) : letters).uppercased()
    }
}

public struct AuthResponse: Codable, Sendable {
    public var token: String
    public var user: User
}

// MARK: - Friends

public struct Friend: Codable, Hashable, Identifiable, Sendable {
    public var user: User
    public var online: Bool
    /** Set when this friend is hosting a party right now. */
    public var party: PartySummary?

    public var id: String { user.id }
}

public struct FriendRequest: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var from: User
    public var to: User
    public var createdAt: Int64
}

public struct FriendsList: Codable, Hashable, Sendable {
    public var friends: [Friend]
    public var incoming: [FriendRequest]
    public var outgoing: [FriendRequest]

    public init(friends: [Friend] = [], incoming: [FriendRequest] = [], outgoing: [FriendRequest] = []) {
        self.friends = friends
        self.incoming = incoming
        self.outgoing = outgoing
    }
}

public enum Relationship: String, Codable, Sendable {
    case none, friend, incoming, outgoing, unknown

    public init(from decoder: Decoder) throws {
        self = Relationship(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public struct UserSearchResult: Codable, Hashable, Identifiable, Sendable {
    public var user: User
    public var relationship: Relationship
    public var requestId: String?

    public var id: String { user.id }
}

public struct FriendRequestResult: Codable, Sendable {
    /** "requested", or "accepted" when they had already sent you a request. */
    public var status: String
    public var request: FriendRequest?
}

// MARK: - Parties

public enum PartyRole: String, Codable, Sendable {
    case host, guest
}

public struct PartyMember: Codable, Hashable, Identifiable, Sendable {
    public var user: User
    public var joinedAt: Int64
    /** False while their app is reconnecting. */
    public var connected: Bool

    public var id: String { user.id }
}

public enum JoinRequestStatus: String, Codable, Sendable {
    case pending, approved, declined, cancelled, unknown

    public init(from decoder: Decoder) throws {
        self = JoinRequestStatus(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public struct JoinRequest: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var partyId: String
    public var user: User
    public var status: JoinRequestStatus
    public var createdAt: Int64
}

/** A party as one of its members sees it. */
public struct Party: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var role: PartyRole
    /** Only the host sees the join code. */
    public var code: String?
    public var host: User
    public var hostConnected: Bool
    public var allowGuestControl: Bool
    public var createdAt: Int64
    /** Guests, not including the host. */
    public var members: [PartyMember]
    /** Only filled in for the host. */
    public var pendingRequests: [JoinRequest]
    public var playback: PlaybackState?

    public var isHost: Bool { role == .host }
}

/** A friend's party, as it appears in your list. */
public struct PartySummary: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var host: User
    public var memberCount: Int
    public var createdAt: Int64
    public var nowPlaying: Track?
    public var isPlaying: Bool
    /** Your pending request to join, if you've asked. */
    public var myRequest: JoinRequest?
}

public enum PartyEndReason: String, Codable, Sendable {
    case hostEnded = "host_ended"
    case hostDisconnected = "host_disconnected"
    case accountDeleted = "account_deleted"
    case left
    case removed
    case disconnected
    case unfriended
    case unknown

    public init(from decoder: Decoder) throws {
        self = PartyEndReason(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }

    /** What to tell a guest whose music just stopped. */
    public var message: String {
        switch self {
        case .hostEnded: return "The host ended the party."
        case .hostDisconnected: return "The host's app went offline, so the party ended."
        case .accountDeleted: return "The host deleted their account."
        case .left: return "You left the party."
        case .removed: return "The host removed you from the party."
        case .disconnected: return "You were offline for too long and left the party."
        case .unfriended: return "You're no longer friends with the host."
        case .unknown: return "The party ended."
        }
    }
}

public enum ControlAction: String, Codable, Sendable {
    case play, pause, seek, next, previous
}

// MARK: - Playback

/**
 * Enough information for any guest to find the same song in their own
 * country's Apple Music catalog.
 */
public struct Track: Codable, Hashable, Sendable {
    /** Apple Music catalog song ID (the same number as in a music.apple.com link). */
    public var catalogId: String?
    public var isrc: String?
    public var title: String
    public var artist: String
    public var album: String?
    /** Seconds. */
    public var duration: Double?
    public var artworkUrl: String?

    public init(
        catalogId: String? = nil,
        isrc: String? = nil,
        title: String,
        artist: String,
        album: String? = nil,
        duration: Double? = nil,
        artworkUrl: String? = nil
    ) {
        self.catalogId = catalogId
        self.isrc = isrc
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artworkUrl = artworkUrl
    }

    public var artworkURL: URL? { artworkUrl.flatMap(URL.init(string:)) }

    /**
     * Identifies "the same song" across updates. Prefers the catalog ID, which
     * is stable; falls back to title and artist for library-only tracks.
     */
    public var matchKey: String {
        if let catalogId, !catalogId.isEmpty { return "id:\(catalogId)" }
        if let isrc, !isrc.isEmpty { return "isrc:\(isrc.uppercased())" }
        return "meta:\(title.lowercased())|\(artist.lowercased())"
    }
}

/**
 * Where the host's player is: `position` seconds into `track`, measured at
 * `timestamp` (server-clock milliseconds), moving at `rate` while playing.
 */
public struct PlaybackState: Codable, Hashable, Sendable {
    public var track: Track?
    public var isPlaying: Bool
    public var position: Double
    public var timestamp: Int64
    public var rate: Double

    public init(track: Track?, isPlaying: Bool, position: Double, timestamp: Int64, rate: Double = 1) {
        self.track = track
        self.isPlaying = isPlaying
        self.position = position
        self.timestamp = timestamp
        self.rate = rate
    }

    enum CodingKeys: String, CodingKey {
        case track, isPlaying, position, timestamp, rate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        track = try c.decodeIfPresent(Track.self, forKey: .track)
        isPlaying = try c.decode(Bool.self, forKey: .isPlaying)
        position = try c.decode(Double.self, forKey: .position)
        timestamp = try c.decode(Int64.self, forKey: .timestamp)
        rate = try c.decodeIfPresent(Double.self, forKey: .rate) ?? 1
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // The server requires the key even when nothing is playing, so encode an explicit null.
        try c.encode(track, forKey: .track)
        try c.encode(isPlaying, forKey: .isPlaying)
        try c.encode(position, forKey: .position)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(rate, forKey: .rate)
    }

    /** Where the host's playhead is at `serverTime` (ms), clamped to the track. */
    public func position(atServerTime serverTime: Double) -> Double {
        var value = position
        if isPlaying {
            value += (serverTime - Double(timestamp)) / 1000 * rate
        }
        if let duration = track?.duration, duration > 0 {
            value = min(value, duration)
        }
        return max(0, value)
    }
}
