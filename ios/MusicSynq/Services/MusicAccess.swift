import MusicKit
import UIKit

/**
 * Apple Music permission and subscription status. Hosts need permission to
 * read what the Music app is playing; guests also need a subscription to play
 * catalog songs.
 */
@MainActor
@Observable
final class MusicAccess {
    private(set) var authorization: MusicAuthorization.Status = MusicAuthorization.currentStatus
    /** nil until we've asked Apple. */
    private(set) var canPlayCatalog: Bool?
    private(set) var canBecomeSubscriber = false

    @ObservationIgnored private var watcher: Task<Void, Never>?

    var isAuthorized: Bool { authorization == .authorized }

    var statusText: String {
        switch authorization {
        case .authorized:
            switch canPlayCatalog {
            case true?: return "Connected"
            case false?: return "No Apple Music subscription"
            case nil: return "Checking…"
            }
        case .denied: return "Access denied"
        case .restricted: return "Restricted on this device"
        case .notDetermined: return "Not connected yet"
        @unknown default: return "Unknown"
        }
    }

    /** Asks for access if we haven't yet. Returns whether we have it. */
    @discardableResult
    func requestAccess() async -> Bool {
        if authorization == .notDetermined {
            authorization = await MusicAuthorization.request()
        } else {
            authorization = MusicAuthorization.currentStatus
        }
        if isAuthorized {
            await refreshSubscription()
            watchSubscription()
        }
        return isAuthorized
    }

    func refreshSubscription() async {
        guard isAuthorized else { return }
        if let subscription = try? await MusicSubscription.current {
            canPlayCatalog = subscription.canPlayCatalogContent
            canBecomeSubscriber = subscription.canBecomeSubscriber
        }
    }

    private func watchSubscription() {
        guard watcher == nil else { return }
        watcher = Task { [weak self] in
            for await subscription in MusicSubscription.subscriptionUpdates {
                self?.canPlayCatalog = subscription.canPlayCatalogContent
                self?.canBecomeSubscriber = subscription.canBecomeSubscriber
            }
        }
    }

    /** Once denied, only the Settings app can grant access again. */
    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
