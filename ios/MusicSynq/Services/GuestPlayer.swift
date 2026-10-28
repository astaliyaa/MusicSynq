import MusicKit
import MusicSynqKit

/**
 * The guest side of a party. Plays the host's song through this app's own
 * Apple Music player and keeps it lined up with the host. All timing
 * decisions come from `GuestSyncPlanner`; this class just carries them out.
 *
 * It uses the app's player (not the Music app's), so the music stops when
 * you leave the party or close MusicSynq, and your own Music queue is left alone.
 */
@MainActor
@Observable
final class GuestPlayer {
    enum Status: Equatable {
        case idle
        case loading
        case synced
        case paused
        /** The host's song isn't in this country's catalog (or couldn't be found). */
        case unavailable(TrackInfo)
        case needsSubscription
        case needsPermission
        case failed(String)

        var text: String {
            switch self {
            case .idle: return "Waiting for the host…"
            case .loading: return "Loading song…"
            case .synced: return "In sync"
            case .paused: return "Paused"
            case let .unavailable(track): return "“\(track.title)” isn't available on your Apple Music"
            case .needsSubscription: return "You need an Apple Music subscription to listen along"
            case .needsPermission: return "Allow Apple Music access in Settings to listen along"
            case let .failed(message): return message
            }
        }
    }

    private(set) var status: Status = .idle
    /** How far (seconds) we are from the host. Positive means ahead. */
    private(set) var drift: Double?

    private let player = ApplicationMusicPlayer.shared
    @ObservationIgnored private var planner = GuestSyncPlanner()
    @ObservationIgnored private var target: PlaybackState?
    @ObservationIgnored private var loadedKey: String?
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var replanWhenDone = false
    @ObservationIgnored private var lastFailedLoad: (key: String, at: Date)?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var connection: RealtimeConnection?
    private let access: MusicAccess

    init(access: MusicAccess) {
        self.access = access
    }

    var isRunning: Bool { loop != nil }

    func start(connection: RealtimeConnection) {
        self.connection = connection
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.replan(.tick)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /** Stops the music: you left, or the party ended. */
    func stop() {
        loop?.cancel()
        loop = nil
        connection = nil
        target = nil
        loadedKey = nil
        lastFailedLoad = nil
        planner.reset()
        player.stop()
        status = .idle
        drift = nil
    }

    /** The host's latest state. */
    func follow(_ state: PlaybackState?) {
        target = state
        Task { await replan(.hostUpdate) }
    }

    /** Reload the song from scratch, e.g. after the user fixed their subscription. */
    func resync() {
        loadedKey = nil
        lastFailedLoad = nil
        planner.unavailableKeys.removeAll()
        Task { await replan(.hostUpdate) }
    }

    // MARK: Planning

    private func replan(_ trigger: GuestSyncPlanner.Trigger) async {
        guard let connection else { return }
        guard !busy else {
            if trigger == .hostUpdate { replanWhenDone = true }
            return
        }

        let serverNow = connection.clock.serverNow()
        let local = LocalPlayerSnapshot(
            loadedKey: loadedKey,
            isPlaying: player.state.playbackStatus == .playing,
            position: player.playbackTime
        )
        if let target, let track = target.track, track.matchKey == loadedKey {
            drift = local.position - target.position(atServerTime: serverNow)
        } else {
            drift = nil
        }

        let action = planner.plan(for: target, local: local, serverNow: serverNow, trigger: trigger)
        if action == .none {
            refreshStatus()
            return
        }

        busy = true
        let loaded = await perform(action)
        busy = false
        refreshStatus()

        // After loading, plan again straight away with fresh timing to start
        // playback in the right place; likewise if the host changed something meanwhile.
        if loaded || replanWhenDone {
            replanWhenDone = false
            await replan(.hostUpdate)
        }
    }

    /** Returns true if a new song was loaded. */
    private func perform(_ action: SyncAction) async -> Bool {
        switch action {
        case .none:
            return false

        case .stop:
            player.stop()
            loadedKey = nil
            return false

        case let .unavailable(track):
            player.pause()
            status = .unavailable(track)
            return false

        case let .load(track, position, _):
            if let failed = lastFailedLoad, failed.key == track.matchKey, Date().timeIntervalSince(failed.at) < 5 {
                return false // Don't hammer Apple's servers; the timer retries shortly.
            }
            status = .loading
            guard await canPlay() else {
                player.pause()
                lastFailedLoad = (track.matchKey, Date())
                return false
            }
            guard let song = await SongResolver.song(for: track) else {
                planner.unavailableKeys.insert(track.matchKey)
                player.pause()
                status = .unavailable(track)
                return false
            }
            do {
                // Whatever was loaded is gone the moment the queue changes.
                loadedKey = nil
                player.queue = ApplicationMusicPlayer.Queue(for: [song])
                try await player.prepareToPlay()
                player.playbackTime = position
                loadedKey = track.matchKey
                lastFailedLoad = nil
                return true
            } catch {
                lastFailedLoad = (track.matchKey, Date())
                status = .failed("Couldn't load “\(track.title)”. Retrying…")
                return false
            }

        case let .play(seekTo):
            if let seekTo { player.playbackTime = seekTo }
            do {
                try await player.play()
            } catch {
                status = .failed("Couldn't start playback. Retrying…")
            }
            return false

        case let .pause(seekTo):
            player.pause()
            if let seekTo { player.playbackTime = seekTo }
            return false

        case let .seek(to):
            player.playbackTime = to
            return false
        }
    }

    private func canPlay() async -> Bool {
        if !access.isAuthorized {
            guard await access.requestAccess() else {
                status = .needsPermission
                return false
            }
        }
        if access.canPlayCatalog == nil { await access.refreshSubscription() }
        if access.canPlayCatalog == false {
            status = .needsSubscription
            return false
        }
        return true
    }

    /**
     * Shows "In sync"/"Paused" once the host's song is loaded here. Until then
     * the status set while loading (loading, unavailable, failed…) stays put.
     */
    private func refreshStatus() {
        guard let key = target?.track?.matchKey else {
            status = .idle
            return
        }
        guard key == loadedKey else { return }
        status = player.state.playbackStatus == .playing ? .synced : .paused
    }
}
