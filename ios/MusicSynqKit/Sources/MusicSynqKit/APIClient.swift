import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/** An error the server explained (`{ error: { code, message } }`), or a transport failure. */
public struct APIError: LocalizedError, Equatable, Sendable {
    /** HTTP status, or 0 when the server couldn't be reached. */
    public var status: Int
    /** Machine-readable, e.g. "wrong_code", "not_friends", "unauthorized". */
    public var code: String
    public var message: String

    public init(status: Int, code: String, message: String) {
        self.status = status
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
    public var isUnauthorized: Bool { status == 401 }
}

/** The REST half of the server API. Every call is `async` and throws `APIError`. */
public struct APIClient: Sendable {
    public var baseURL: URL
    public var token: String?
    private let session: URLSession

    public init(baseURL: URL, token: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    // MARK: Account

    public func register(username: String, displayName: String, password: String) async throws -> AuthResponse {
        try await send("POST", "auth/register", body: ["username": username, "displayName": displayName, "password": password])
    }

    public func login(username: String, password: String) async throws -> AuthResponse {
        try await send("POST", "auth/login", body: ["username": username, "password": password])
    }

    public func logout() async throws {
        try await sendEmpty("POST", "auth/logout")
    }

    public func me() async throws -> User {
        let response: UserEnvelope = try await send("GET", "me")
        return response.user
    }

    public func updateDisplayName(_ displayName: String) async throws -> User {
        let response: UserEnvelope = try await send("PATCH", "me", body: ["displayName": displayName])
        return response.user
    }

    public func deleteAccount(password: String) async throws {
        try await sendEmpty("DELETE", "me", body: ["password": password])
    }

    public func searchUsers(_ query: String) async throws -> [UserSearchResult] {
        let response: UsersEnvelope = try await send("GET", "users/search", query: ["q": query])
        return response.users
    }

    // MARK: Friends

    public func friends() async throws -> FriendsList {
        try await send("GET", "friends")
    }

    public func sendFriendRequest(username: String) async throws -> FriendRequestResult {
        try await send("POST", "friends/requests", body: ["username": username])
    }

    public func acceptFriendRequest(id: String) async throws -> FriendsList {
        try await send("POST", "friends/requests/\(id)/accept")
    }

    /** Declines a request sent to you, or withdraws one you sent. */
    public func removeFriendRequest(id: String) async throws -> FriendsList {
        try await send("DELETE", "friends/requests/\(id)")
    }

    public func removeFriend(userID: String) async throws -> FriendsList {
        try await send("DELETE", "friends/\(userID)")
    }

    // MARK: Parties

    public func currentParty() async throws -> Party? {
        let response: OptionalPartyEnvelope = try await send("GET", "parties/current")
        return response.party
    }

    public func friendsParties() async throws -> [PartySummary] {
        let response: PartiesEnvelope = try await send("GET", "parties/friends")
        return response.parties
    }

    public func startParty(allowGuestControl: Bool) async throws -> Party {
        let response: PartyEnvelope = try await send("POST", "parties", body: ["allowGuestControl": allowGuestControl])
        return response.party
    }

    /** Join with the host's code. Pass `partyID` when joining from the friends list. */
    public func joinParty(partyID: String? = nil, code: String) async throws -> Party {
        let path = partyID.map { "parties/\($0)/join" } ?? "parties/join"
        let response: PartyEnvelope = try await send("POST", path, body: ["code": code])
        return response.party
    }

    public func updateParty(id: String, allowGuestControl: Bool) async throws -> Party {
        let response: PartyEnvelope = try await send("PATCH", "parties/\(id)", body: ["allowGuestControl": allowGuestControl])
        return response.party
    }

    public func endParty(id: String) async throws {
        try await sendEmpty("DELETE", "parties/\(id)")
    }

    public func leaveParty(id: String) async throws {
        try await sendEmpty("POST", "parties/\(id)/leave")
    }

    public func requestToJoin(partyID: String) async throws -> JoinRequest {
        let response: RequestEnvelope = try await send("POST", "parties/\(partyID)/requests")
        return response.request
    }

    public func cancelJoinRequest(partyID: String, requestID: String) async throws -> JoinRequest {
        let response: RequestEnvelope = try await send("DELETE", "parties/\(partyID)/requests/\(requestID)")
        return response.request
    }

    public func answerJoinRequest(partyID: String, requestID: String, approve: Bool) async throws -> JoinRequest {
        let verb = approve ? "approve" : "decline"
        let response: RequestEnvelope = try await send("POST", "parties/\(partyID)/requests/\(requestID)/\(verb)")
        return response.request
    }

    public func removeMember(partyID: String, userID: String) async throws {
        try await sendEmpty("DELETE", "parties/\(partyID)/members/\(userID)")
    }

    // MARK: Push notifications

    public func registerDevice(token deviceToken: String, environment: String) async throws {
        try await sendEmpty("PUT", "devices", body: ["token": deviceToken, "environment": environment])
    }

    public func unregisterDevice(token deviceToken: String) async throws {
        try await sendEmpty("DELETE", "devices/\(deviceToken)")
    }

    // MARK: Plumbing

    /** URL for the realtime socket, e.g. https://host/ → wss://host/ws. */
    public var webSocketURL: URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("ws"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        return components.url!
    }

    private func send<Response: Decodable>(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil) async throws -> Response {
        let data = try await perform(method, path, query: query, body: body)
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw APIError(status: 200, code: "bad_response", message: "The server sent something this app doesn't understand. Is the app up to date?")
        }
    }

    private func sendEmpty(_ method: String, _ path: String, body: [String: Any]? = nil) async throws {
        _ = try await perform(method, path, query: [:], body: body)
    }

    private func perform(_ method: String, _ path: String, query: [String: String], body: [String: Any]?) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError(status: 0, code: "offline", message: "Couldn't reach the MusicSynq server. Check your connection.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
                throw APIError(status: status, code: envelope.error.code, message: envelope.error.message)
            }
            throw APIError(status: status, code: "http_\(status)", message: "The server had a problem (\(status)). Try again.")
        }
        return data
    }
}

private struct ErrorEnvelope: Decodable {
    struct Body: Decodable {
        var code: String
        var message: String
    }
    var error: Body
}

private struct UserEnvelope: Decodable { var user: User }
private struct UsersEnvelope: Decodable { var users: [UserSearchResult] }
private struct PartyEnvelope: Decodable { var party: Party }
private struct OptionalPartyEnvelope: Decodable { var party: Party? }
private struct PartiesEnvelope: Decodable { var parties: [PartySummary] }
private struct RequestEnvelope: Decodable { var request: JoinRequest }
