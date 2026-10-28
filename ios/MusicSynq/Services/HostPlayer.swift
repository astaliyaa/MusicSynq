import MediaPlayer
import MusicSynqKit
import UIKit

/**
 * The host side of a party. Watches the system Music app (so the host just
 * uses Apple Music as normal) and streams what it's doing to the server.
 * Also carries out play/pause/seek/skip from the app's controls and from
 * guests, when the host allows it.
 */
@MainActor
@Observable
final class HostPlayer {
    private(set) var track: TrackInfo?
    private(set) var isPlaying = false
    /** Seconds into the current song. */
    private(set) var position: Double = 0
    private(set) var artwork: UIImage?

    var duration: Double { track?.duration ?? 0 }

    private let player = MPMusicPlayerController.systemMusicPlayer
    @ObservationIgnored private var policy = HostReportPolicy()
    @ObservationIgnored private var connection: RealtimeConnection?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var observers: [Task<Void, Never>] = []
    @ObservationIgnored private var details: [String: (isrc: String?, artworkURL: String?)] = [:]
    @ObservationIgnored private var lookingUp: Set<String> = []
    @ObservationIgnored private var lastItemID: MPMediaEntityPersistentID?
    @ObservationIgnored private var lastSample: (position: Double, uptime: TimeInterval)?

    var isRunning: Bool { loop != nil }

    /** Start reporting to the party. Safe to call again with a new connection. */
    func start(connection: RealtimeConnection) {
        self.connection = connection
        policy.reset()
        guard loop == nil else { return }
        player.beginGeneratingPlaybackNotifications()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        // React to changes right away instead of waiting for the next poll.
        for name in [Notification.Name.MPMusicPlayerControllerNowPlayingItemDidChange, .MPMusicPlayerControllerPlaybackStateDidChange] {
            observers.append(Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: name) {
                    self?.poll()
                }
            })
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        observers.forEach { $0.cancel() }
        observers.removeAll()
        player.endGeneratingPlaybackNotifications()
        connection = nil
    }

    /** Send the current state on the next poll, e.g. after reconnecting. */
    func reportSoon() {
        policy.reset()
        poll()
    }

    // MARK: Controls

    func togglePlayPause() {
        if isPlaying { player.pause() } else { player.play() }
        poll()
    }

    func seek(to seconds: Double) {
        let limit = duration > 0 ? max(0, duration - 1) : seconds
        player.currentPlaybackTime = min(max(0, seconds), limit)
        poll()
    }

    func skip(by seconds: Double) {
        seek(to: position + seconds)
    }

    func nextTrack() {
        player.skipToNextItem()
        poll()
    }

    func previousTrack() {
        // Like the Music app: the first press restarts the song.
        if position > 3 { player.skipToBeginning() } else { player.skipToPreviousItem() }
        poll()
    }

    /** A guest pressed a control (the server only forwards it if the host allows guest control). */
    func perform(_ action: ControlAction, position: Double?) {
        switch action {
        case .play: if !isPlaying { player.play() }
        case .pause: if isPlaying { player.pause() }
        case .seek: if let position { seek(to: position) }
        case .next: nextTrack()
        case .previous: previousTrack()
        }
        poll()
    }

    // MARK: Watching the Music app

    private func poll() {
        let item = player.nowPlayingItem
        var position = player.currentPlaybackTime
        if !position.isFinite || position < 0 { position = 0 }

        var playing = player.playbackState == .playing
        // The system player sometimes reports a stale state; a playhead that is
        // clearly moving at normal speed means it's playing, whatever it says.
        let uptime = ProcessInfo.processInfo.systemUptime
        if !playing, item != nil, let last = lastSample, item?.persistentID == lastItemID {
            let elapsed = uptime - last.uptime
            let moved = position - last.position
            if elapsed > 0.2, elapsed < 2, moved > elapsed * 0.7, moved < elapsed * 1.3 { playing = true }
        }
        lastSample = (position, uptime)

        if item?.persistentID != lastItemID {
            lastItemID = item?.persistentID
            artwork = item?.artwork?.image(at: CGSize(width: 600, height: 600))
        }
        let track = item.map(makeTrack)
        if self.track != track { self.track = track }
        if self.isPlaying != playing { self.isPlaying = playing }
        self.position = position

        guard let connection, connection.isConnected else { return }
        let observed = PlaybackState(
            track: track,
            isPlaying: playing && track != nil,
            position: position,
            timestamp: Int64(connection.clock.serverNow())
        )
        if policy.shouldSend(observed) {
            connection.send(.playback(observed))
        }
    }

    private func makeTrack(_ item: MPMediaItem) -> TrackInfo {
        let storeID = item.playbackStoreID
        let catalogID = storeID.isEmpty || storeID == "0" ? nil : storeID
        var track = TrackInfo(
            catalogId: catalogID,
            title: item.title ?? "Unknown song",
            artist: item.artist ?? "",
            album: item.albumTitle,
            duration: item.playbackDuration > 0 ? item.playbackDuration : nil
        )
        if let catalogID {
            if let extra = details[catalogID] {
                track.isrc = extra.isrc
                track.artworkUrl = extra.artworkURL
            } else {
                lookUpDetails(catalogID)
            }
        }
        return track
    }

    private func lookUpDetails(_ catalogID: String) {
        guard !lookingUp.contains(catalogID) else { return }
        lookingUp.insert(catalogID)
        Task { [weak self] in
            let found = await SongResolver.details(forCatalogID: catalogID)
            guard let self else { return }
            self.lookingUp.remove(catalogID)
            self.details[catalogID] = found ?? (nil, nil)
            // Share the artwork and ISRC with guests now rather than at the next heartbeat.
            self.reportSoon()
        }
    }
}
