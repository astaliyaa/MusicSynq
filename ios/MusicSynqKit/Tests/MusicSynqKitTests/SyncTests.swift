import XCTest
@testable import MusicSynqKit

final class ClockSyncTests: XCTestCase {
    func testUsesTheFastestRoundTrip() {
        let clock = ClockSync()
        XCTAssertNil(clock.offset)
        clock.recordRough(serverTime: 10_000, receivedAt: 9_000)
        XCTAssertEqual(clock.offset, 1_000)
        XCTAssertFalse(clock.isSynced)

        // Server is 5s ahead. A slow sample with asymmetric delay is off by 100ms…
        clock.record(sentAt: 1_000, rtt: 400, serverTime: 6_300)
        // …the fast one is nearly exact, and wins.
        clock.record(sentAt: 2_000, rtt: 40, serverTime: 7_020)
        clock.record(sentAt: 3_000, rtt: 300, serverTime: 8_050)
        XCTAssertTrue(clock.isSynced)
        XCTAssertEqual(clock.offset, 5_000)
        XCTAssertEqual(clock.bestRTT, 40)
        XCTAssertEqual(clock.serverNow(localNow: 100), 5_100)
    }

    func testKeepsOnlyRecentSamples() {
        let clock = ClockSync(maxSamples: 2)
        clock.record(sentAt: 0, rtt: 10, serverTime: 1_005) // offset 1000, fastest, but old
        clock.record(sentAt: 0, rtt: 50, serverTime: 2_025)
        clock.record(sentAt: 0, rtt: 60, serverTime: 2_030)
        XCTAssertEqual(clock.offset, 2_000)
    }
}

final class GuestSyncPlannerTests: XCTestCase {
    let song = TrackInfo(catalogId: "1", title: "Song", artist: "Artist", duration: 200)
    let other = TrackInfo(catalogId: "2", title: "Other", artist: "Artist", duration: 180)
    let t0 = 1_000_000.0 // server ms

    func state(_ track: TrackInfo?, playing: Bool, at position: Double, ms: Double? = nil) -> PlaybackState {
        PlaybackState(track: track, isPlaying: playing, position: position, timestamp: Int64(ms ?? t0))
    }

    func local(_ track: TrackInfo?, playing: Bool, at position: Double) -> LocalPlayerSnapshot {
        LocalPlayerSnapshot(loadedKey: track?.matchKey, isPlaying: playing, position: position)
    }

    func testLoadsTheHostsSongThenSeeksOnceLoaded() {
        var planner = GuestSyncPlanner(initialLead: 0.25)
        let target = state(song, playing: true, at: 30)

        // Nothing loaded yet: load at where the host will be.
        let first = planner.plan(for: target, local: local(nil, playing: false, at: 0), serverNow: t0 + 1_000, trigger: .hostUpdate)
        XCTAssertEqual(first, .load(song, position: 31.25, play: true))

        // Loading took 2s. The app plans again: play, seeking to catch up.
        let second = planner.plan(for: target, local: local(song, playing: false, at: 31.25), serverNow: t0 + 3_000, trigger: .hostUpdate)
        XCTAssertEqual(second, .play(seekTo: 33.25))
    }

    func testFollowsPauseResumeAndSeek() {
        var planner = GuestSyncPlanner()
        // Host paused at 50; guest is still playing at 50.4.
        XCTAssertEqual(
            planner.plan(for: state(song, playing: false, at: 50), local: local(song, playing: true, at: 50.4), serverNow: t0 + 100, trigger: .hostUpdate),
            .pause(seekTo: 50)
        )
        // Host scrubbed while paused.
        XCTAssertEqual(
            planner.plan(for: state(song, playing: false, at: 120), local: local(song, playing: false, at: 50), serverNow: t0 + 200, trigger: .hostUpdate),
            .seek(to: 120)
        )
        // Host resumed; guest is at the same spot, so no seek needed.
        XCTAssertEqual(
            planner.plan(for: state(song, playing: true, at: 120), local: local(song, playing: false, at: 120), serverNow: t0 + 300, trigger: .hostUpdate),
            .play(seekTo: nil)
        )
        // Host skipped ahead 30s while playing.
        XCTAssertEqual(
            planner.plan(for: state(song, playing: true, at: 150, ms: t0 + 1_000), local: local(song, playing: true, at: 121), serverNow: t0 + 1_000, trigger: .hostUpdate),
            .seek(to: 150 + planner.lead)
        )
    }

    func testIgnoresSmallDriftAndWaitsForCooldownOnTicks() {
        var planner = GuestSyncPlanner(tolerance: 0.6, cooldown: 4)
        let target = state(song, playing: true, at: 10)
        // 0.3s off: fine.
        XCTAssertEqual(planner.plan(for: target, local: local(song, playing: true, at: 10.3), serverNow: t0, trigger: .tick), .none)
        // 1s behind: correct.
        guard case .seek = planner.plan(for: target, local: local(song, playing: true, at: 9), serverNow: t0, trigger: .tick) else { return XCTFail() }
        // Still behind 2s later (the seek hasn't landed): wait for the cooldown…
        XCTAssertEqual(planner.plan(for: target, local: local(song, playing: true, at: 10), serverNow: t0 + 2_000, trigger: .tick), .none)
        // …but a real change from the host is applied immediately.
        XCTAssertEqual(
            planner.plan(for: state(song, playing: false, at: 12, ms: t0 + 2_000), local: local(song, playing: true, at: 11), serverNow: t0 + 2_000, trigger: .hostUpdate),
            .pause(seekTo: 12)
        )
    }

    func testLearnsHowMuchLeadSeeksNeed() {
        var planner = GuestSyncPlanner(tolerance: 0.6, cooldown: 4, initialLead: 0.2)
        let target = state(song, playing: true, at: 10)
        // Correct a 2s lag.
        XCTAssertEqual(planner.plan(for: target, local: local(song, playing: true, at: 8), serverNow: t0, trigger: .tick), .seek(to: 10.2))
        // After settling we're still 0.4s behind (the seek took longer than 0.2s to take effect).
        _ = planner.plan(for: target, local: local(song, playing: true, at: 14.6), serverNow: t0 + 5_000, trigger: .tick)
        XCTAssertEqual(planner.lead, 0.4, accuracy: 0.0001, "halfway from 0.2 toward the 0.6 that would have been right")
    }

    func testChangesSongAndStopsWhenHostStops() {
        var planner = GuestSyncPlanner()
        guard case .load(other, _, true) = planner.plan(for: state(other, playing: true, at: 0), local: local(song, playing: true, at: 199), serverNow: t0, trigger: .hostUpdate) else { return XCTFail() }
        XCTAssertEqual(planner.plan(for: state(nil, playing: false, at: 0), local: local(song, playing: true, at: 3), serverNow: t0, trigger: .hostUpdate), .stop)
        XCTAssertEqual(planner.plan(for: nil, local: local(nil, playing: false, at: 0), serverNow: t0, trigger: .tick), .none)
    }

    func testStaysQuietForUnavailableSongs() {
        var planner = GuestSyncPlanner()
        planner.unavailableKeys.insert(song.matchKey)
        XCTAssertEqual(planner.plan(for: state(song, playing: true, at: 5), local: local(other, playing: true, at: 5), serverNow: t0, trigger: .hostUpdate), .unavailable(song))
        XCTAssertEqual(planner.plan(for: state(song, playing: true, at: 5), local: local(other, playing: false, at: 5), serverNow: t0, trigger: .tick), .none)
    }

    func testLeavesTheEndOfASongAlone() {
        var planner = GuestSyncPlanner()
        let target = state(song, playing: true, at: 199)
        XCTAssertEqual(planner.plan(for: target, local: local(song, playing: true, at: 196), serverNow: t0, trigger: .tick), .none, "no seek")
        // Our copy already finished; don't restart it while waiting for the host's next song.
        XCTAssertEqual(planner.plan(for: target, local: local(song, playing: false, at: 0), serverNow: t0 + 1_500, trigger: .tick), .none, "no replay")
    }
}

final class HostReportPolicyTests: XCTestCase {
    let song = TrackInfo(catalogId: "1", title: "Song", artist: "Artist", duration: 200)

    func observed(_ track: TrackInfo?, playing: Bool, at position: Double, ms: Int64) -> PlaybackState {
        PlaybackState(track: track, isPlaying: playing, position: position, timestamp: ms)
    }

    func testSendsOnlyWhatGuestsWouldNotice() {
        var policy = HostReportPolicy(playingHeartbeat: 5, pausedHeartbeat: 20, seekThreshold: 1.5)
        XCTAssertTrue(policy.shouldSend(observed(song, playing: true, at: 0, ms: 0)), "first observation")
        XCTAssertFalse(policy.shouldSend(observed(song, playing: true, at: 0.5, ms: 500)), "playing normally")
        XCTAssertFalse(policy.shouldSend(observed(song, playing: true, at: 2.4, ms: 2_000)), "a little jitter")
        XCTAssertTrue(policy.shouldSend(observed(song, playing: true, at: 30, ms: 2_500)), "seek")
        XCTAssertTrue(policy.shouldSend(observed(song, playing: false, at: 30.2, ms: 2_700)), "pause")
        XCTAssertFalse(policy.shouldSend(observed(song, playing: false, at: 30.2, ms: 10_000)), "paused, before heartbeat")
        XCTAssertTrue(policy.shouldSend(observed(song, playing: false, at: 30.2, ms: 22_700)), "paused heartbeat")
        XCTAssertTrue(policy.shouldSend(observed(song, playing: true, at: 30.2, ms: 23_000)), "resume")
        XCTAssertTrue(policy.shouldSend(observed(song, playing: true, at: 35.2, ms: 28_000)), "playing heartbeat")
        let next = TrackInfo(catalogId: "2", title: "Next", artist: "Artist")
        XCTAssertTrue(policy.shouldSend(observed(next, playing: true, at: 0, ms: 28_100)), "new song")
        XCTAssertTrue(policy.shouldSend(observed(nil, playing: false, at: 0, ms: 28_200)), "stopped")
    }
}

final class TrackMatcherTests: XCTestCase {
    func testNormalizesTitles() {
        XCTAssertEqual(TrackMatcher.normalize("Señorita (feat. X) - 2011 Remaster"), "senorita")
        XCTAssertEqual(TrackMatcher.normalize("Rock & Roll [Live]"), "rock and roll")
        XCTAssertEqual(TrackMatcher.normalize("Don't Stop Me Now"), "don t stop me now")
    }

    func testPicksTheRightSearchResult() {
        let track = TrackInfo(title: "Dancing Queen", artist: "ABBA", duration: 230)
        let candidates = [
            TrackMatcher.Candidate(title: "Dancing Queen (Glee Cast Version)", artist: "Glee Cast", duration: 210),
            TrackMatcher.Candidate(title: "Dancing Queen", artist: "ABBA", duration: 231),
            TrackMatcher.Candidate(title: "Dancing Queen", artist: "ABBA", duration: 300),
        ]
        XCTAssertEqual(TrackMatcher.bestMatch(for: track, in: candidates), 1)
        XCTAssertNil(TrackMatcher.bestMatch(for: track, in: [TrackMatcher.Candidate(title: "Waterloo", artist: "ABBA", duration: 230)]))
        XCTAssertEqual(TrackMatcher.searchTerm(for: TrackInfo(title: "Song (Remix)", artist: "A & B")), "song a")
    }
}
