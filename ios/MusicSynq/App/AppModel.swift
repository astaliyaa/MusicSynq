import MusicSynqKit
import SwiftUI
import UIKit
import UserNotifications

/**
 * The app's single source of truth: who's signed in, the live connection,
 * your friends, and the party you're in. Views read it from the environment
 * and call its methods; it drives `HostPlayer` and `GuestPlayer`.
 */
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Tab: Hashable {
        case listen, friends, settings
    }

    struct Notice: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    /** Your request to join a friend's party, while you wait for them to answer. */
    struct PendingJoin: Equatable {
        var request: JoinRequest
        var host: User
    }

    // MARK: State

    private(set) var user: User?
    private(set) var serverURL: URL = ServerSettings.url
    private(set) var isConnected = false
    private(set) var party: Party?
    private(set) var friends = FriendsList()
    private(set) var friendsParties: [PartySummary] = []
    private(set) var pendingJoin: PendingJoin?
    /** A join request the host hasn't answered yet, shown as an alert wherever they are in the app. */
    var joinPrompt: JoinRequest?
    var selectedTab: Tab = .listen
    var notice: Notice?

    /** Play silence during parties so iOS keeps the app (and the sync) running in the background. */
    var keepAliveEnabled: Bool = UserDefaults.standard.object(forKey: "keepAliveEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(keepAliveEnabled, forKey: "keepAliveEnabled")
            updateKeepAlive()
        }
    }

    let music: MusicAccess
    let host: HostPlayer
    let guest: GuestPlayer

    @ObservationIgnored private(set) var api: APIClient
    private let keepAlive = BackgroundKeepAlive()
    @ObservationIgnored private var connection: RealtimeConnection?
    @ObservationIgnored private var events: Task<Void, Never>?
    @ObservationIgnored private var friendsRefresh: Task<Void, Never>?
    @ObservationIgnored private var pushToken: String?

    private init() {
        let music = MusicAccess()
        self.music = music
        self.host = HostPlayer()
        self.guest = GuestPlayer(access: music)
        self.api = APIClient(baseURL: ServerSettings.url, token: SessionStore.loadToken())

        // Show the app straight away with the last known profile, then confirm with the server.
        if api.token != nil, let cached = Self.loadCachedUser() {
            user = cached
            connect()
            Task { await refreshEverything() }
        } else if api.token != nil {
            Task { await restoreSession() }
        }
    }

    var isHost: Bool { party?.isHost == true }

    /** The server's clock in milliseconds, used to line up positions. */
    func serverNow() -> Double {
        connection?.clock.serverNow() ?? ClockSync.localNow()
    }

    // MARK: Account

    func signIn(username: String, password: String) async throws {
        let auth = try await APIClient(baseURL: serverURL).login(username: username, password: password)
        completeSignIn(auth)
    }

    func register(username: String, displayName: String, password: String) async throws {
        let auth = try await APIClient(baseURL: serverURL).register(username: username, displayName: displayName, password: password)
        completeSignIn(auth)
    }

    func signOut() async {
        if let pushToken { try? await api.unregisterDevice(token: pushToken) }
        try? await api.logout()
        signOutLocally()
    }

    func deleteAccount(password: String) async throws {
        try await api.deleteAccount(password: password)
        signOutLocally()
    }

    func updateDisplayName(_ name: String) async throws {
        let updated = try await api.updateDisplayName(name)
        user = updated
        Self.cacheUser(updated)
    }

    /** Only while signed out, from the sign-in screen's server field. */
    func setServerURL(_ url: URL) {
        ServerSettings.url = url
        serverURL = url
        api = APIClient(baseURL: url, token: nil)
    }

    private func completeSignIn(_ auth: AuthResponse) {
        SessionStore.saveToken(auth.token)
        Self.cacheUser(auth.user)
        api = APIClient(baseURL: serverURL, token: auth.token)
        user = auth.user
        selectedTab = .listen
        connect()
        Task {
            await refreshEverything()
            await requestNotificationPermission()
        }
    }

    private func restoreSession() async {
        do {
            let me = try await api.me()
            user = me
            Self.cacheUser(me)
            connect()
            await refreshEverything()
        } catch let error as APIError where error.isUnauthorized {
            signOutLocally()
        } catch {
            notice = Notice(title: "Can't reach MusicSynq", message: error.localizedDescription)
        }
    }

    private func signOutLocally(message: String? = nil) {
        disconnect()
        apply(nil)
        SessionStore.deleteToken()
        UserDefaults.standard.removeObject(forKey: "cachedUser")
        api = APIClient(baseURL: serverURL, token: nil)
        user = nil
        friends = FriendsList()
        friendsParties = []
        pendingJoin = nil
        joinPrompt = nil
        if let message { notice = Notice(title: "Signed out", message: message) }
    }

    private static func cacheUser(_ user: User) {
        if let data = try? JSONEncoder().encode(user) {
            UserDefaults.standard.set(data, forKey: "cachedUser")
        }
    }

    private static func loadCachedUser() -> User? {
        guard let data = UserDefaults.standard.data(forKey: "cachedUser") else { return nil }
        return try? JSONDecoder().decode(User.self, from: data)
    }

    // MARK: Live connection

    private func connect() {
        guard let token = api.token else { return }
        disconnect()
        let connection = RealtimeConnection(url: api.webSocketURL, token: token)
        self.connection = connection
        events = Task { [weak self] in
            for await event in connection.events {
                self?.handle(event)
            }
        }
        connection.start()
    }

    private func disconnect() {
        events?.cancel()
        events = nil
        connection?.stop()
        connection = nil
        isConnected = false
    }

    /** Coming back to the foreground: the socket may have died while we were away. */
    func appBecameActive() {
        guard user != nil else { return }
        if !isConnected { connection?.reconnectNow() }
        Task {
            await refreshEverything()
            await music.refreshSubscription()
        }
    }

    private func handle(_ event: RealtimeConnection.Event) {
        switch event {
        case .connected:
            isConnected = true
            if isHost { host.reportSoon() }
        case .disconnected:
            isConnected = false
        case .unauthorized:
            signOutLocally(message: "Your session expired. Sign in again.")
        case let .message(message):
            handle(message)
        }
    }

    private func handle(_ message: ServerMessage) {
        switch message {
        case let .hello(_, user, party):
            self.user = user
            Self.cacheUser(user)
            apply(party)

        case let .partyUpdated(party):
            apply(party)

        case let .partyEnded(partyID, reason):
            guard party?.id == partyID else { return }
            apply(nil)
            if reason != .left {
                notice = Notice(title: "The party's over", message: reason.message)
            }
            scheduleFriendsRefresh()

        case let .playback(partyID, playback):
            guard var current = party, current.id == partyID else { return }
            current.playback = playback
            party = current
            guest.follow(playback)

        case let .joinRequest(request):
            if isHost { joinPrompt = request }

        case let .joinRequestUpdated(request, party):
            guard let pending = pendingJoin, pending.request.id == request.id else { return }
            pendingJoin = nil
            switch request.status {
            case .approved:
                if let party { apply(party) }
            case .declined:
                notice = Notice(title: "Not this time", message: "\(pending.host.displayName) didn't let you in.")
            case .cancelled:
                notice = Notice(title: "Party ended", message: "\(pending.host.displayName)'s party ended before they answered.")
            default:
                break
            }
            scheduleFriendsRefresh()

        case let .control(_, action, position, _):
            guard isHost else { return }
            host.perform(action, position: position)

        case .friendsChanged:
            scheduleFriendsRefresh()

        case let .error(_, message):
            notice = Notice(title: "Couldn't do that", message: message)

        case .pong, .unknown:
            break
        }
    }

    /** Switches the players on/off to match the party we're in (if any). */
    private func apply(_ newParty: Party?) {
        let previous = party
        party = newParty

        guard let newParty, let connection else {
            host.stop()
            guest.stop()
            updateKeepAlive()
            return
        }

        if newParty.isHost {
            if guest.isRunning { guest.stop() }
            if !host.isRunning || previous?.id != newParty.id {
                host.start(connection: connection)
            }
            if let prompt = joinPrompt, !newParty.pendingRequests.contains(where: { $0.id == prompt.id }) {
                joinPrompt = nil
            }
        } else {
            if host.isRunning { host.stop() }
            if previous?.id != newParty.id { guest.stop() }
            guest.start(connection: connection)
            if previous?.id != newParty.id || previous?.playback != newParty.playback {
                guest.follow(newParty.playback)
            }
            pendingJoin = nil
            joinPrompt = nil
        }
        updateKeepAlive()
    }

    private func updateKeepAlive() {
        if party != nil && keepAliveEnabled {
            keepAlive.start()
        } else {
            keepAlive.stop()
        }
    }

    // MARK: Parties

    func startParty() async {
        guard await music.requestAccess() else {
            notice = Notice(title: "Apple Music access needed", message: "Allow MusicSynq to use Apple Music in Settings so your friends can hear what you play.")
            return
        }
        await run { [self] in
            let party = try await api.startParty(allowGuestControl: true)
            apply(party)
        }
    }

    func endParty() async {
        guard let party, party.isHost else { return }
        await run { [self] in
            try await api.endParty(id: party.id)
            apply(nil)
        }
        scheduleFriendsRefresh()
    }

    func leaveParty() async {
        guard let party, !party.isHost else { return }
        await run { [self] in
            try await api.leaveParty(id: party.id)
            apply(nil)
        }
        scheduleFriendsRefresh()
    }

    /** Join with the host's code. Throws so the join sheet can show the error inline. */
    func joinParty(_ summary: PartySummary?, code: String) async throws {
        await music.requestAccess()
        let party = try await api.joinParty(partyID: summary?.id, code: code)
        apply(party)
        pendingJoin = nil
    }

    func requestToJoin(_ summary: PartySummary) async throws {
        await music.requestAccess()
        let request = try await api.requestToJoin(partyID: summary.id)
        pendingJoin = PendingJoin(request: request, host: summary.host)
    }

    func cancelJoinRequest() async {
        guard let pending = pendingJoin else { return }
        pendingJoin = nil
        _ = try? await api.cancelJoinRequest(partyID: pending.request.partyId, requestID: pending.request.id)
    }

    func answer(_ request: JoinRequest, approve: Bool) async {
        if joinPrompt?.id == request.id { joinPrompt = nil }
        await run { [self] in
            _ = try await api.answerJoinRequest(partyID: request.partyId, requestID: request.id, approve: approve)
            if let current = try await api.currentParty() { apply(current) }
        }
    }

    func setAllowGuestControl(_ allow: Bool) async {
        guard let party, party.isHost else { return }
        await run { [self] in
            let updated = try await api.updateParty(id: party.id, allowGuestControl: allow)
            apply(updated)
        }
    }

    func remove(_ member: PartyMember) async {
        guard let party, party.isHost else { return }
        await run { [self] in
            try await api.removeMember(partyID: party.id, userID: member.user.id)
        }
    }

    /** A guest's play/pause/seek/skip, carried out by the host's app. */
    func sendControl(_ action: ControlAction, position: Double? = nil) {
        connection?.send(.control(action: action, position: position))
    }

    // MARK: Friends

    func refreshEverything() async {
        guard user != nil else { return }
        let api = self.api
        async let friends = api.friends()
        async let parties = api.friendsParties()
        async let current = api.currentParty()
        do {
            self.friends = try await friends
            self.friendsParties = try await parties
            let party = try await current
            // The socket is the authority while connected; this covers being offline.
            if !isConnected { apply(party) }
            if let mine = friendsParties.compactMap(\.myRequest).first, let host = friendsParties.first(where: { $0.id == mine.partyId })?.host {
                pendingJoin = PendingJoin(request: mine, host: host)
            } else if party != nil {
                pendingJoin = nil
            }
        } catch let error as APIError where error.isUnauthorized {
            signOutLocally(message: "Your session expired. Sign in again.")
        } catch {
            // Offline; the socket reconnecting will bring us up to date.
        }
    }

    /** Coalesces bursts of "friends changed" events into one refresh. */
    private func scheduleFriendsRefresh() {
        friendsRefresh?.cancel()
        friendsRefresh = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.refreshEverything()
        }
    }

    func searchUsers(_ query: String) async -> [UserSearchResult] {
        (try? await api.searchUsers(query)) ?? []
    }

    func addFriend(username: String) async throws -> FriendRequestResult {
        let result = try await api.sendFriendRequest(username: username)
        await refreshEverything()
        return result
    }

    func accept(_ request: FriendRequest) async {
        await run { [self] in friends = try await api.acceptFriendRequest(id: request.id) }
        await refreshEverything()
    }

    func acceptRequest(id: String) async {
        await run { [self] in friends = try await api.acceptFriendRequest(id: id) }
        await refreshEverything()
    }

    /** Decline a request you received, or withdraw one you sent. */
    func removeRequest(id: String) async {
        await run { [self] in friends = try await api.removeFriendRequest(id: id) }
    }

    func removeFriend(_ friend: Friend) async {
        await run { [self] in friends = try await api.removeFriend(userID: friend.user.id) }
        await refreshEverything()
    }

    // MARK: Push notifications

    func requestNotificationPermission() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            if granted { UIApplication.shared.registerForRemoteNotifications() }
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
        default:
            break
        }
    }

    func didRegisterForPush(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        pushToken = token
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        Task { try? await api.registerDevice(token: token, environment: environment) }
    }

    /** The user tapped a notification or one of its buttons. */
    func handle(_ push: PushPayload) async {
        switch (push.type, push.action) {
        case ("join_request", NotificationHandler.approveAction), ("join_request", NotificationHandler.declineAction):
            guard let partyID = push.partyID, let requestID = push.requestID else { return }
            let approve = push.action == NotificationHandler.approveAction
            _ = try? await api.answerJoinRequest(partyID: partyID, requestID: requestID, approve: approve)
            if joinPrompt?.id == requestID { joinPrompt = nil }
        case ("join_request", _), ("party_started", _), ("join_approved", _):
            selectedTab = .listen
            await refreshEverything()
        case ("friend_request", _), ("friend_accepted", _):
            selectedTab = .friends
            await refreshEverything()
        default:
            break
        }
    }

    // MARK: Helpers

    /** Runs an API call, turning any error into an alert. */
    private func run(_ work: () async throws -> Void) async {
        do {
            try await work()
        } catch let error as APIError where error.isUnauthorized {
            signOutLocally(message: "Your session expired. Sign in again.")
        } catch {
            notice = Notice(title: "Couldn't do that", message: error.localizedDescription)
        }
    }
}
