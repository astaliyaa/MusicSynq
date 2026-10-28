import SwiftUI
import UIKit
import UserNotifications

@main
struct MusicSynqApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    private var model: AppModel { AppModel.shared }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.appBecameActive() }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    private let notifications = NotificationHandler()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = notifications
        NotificationHandler.registerCategories()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        AppModel.shared.didRegisterForPush(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Expected in the simulator and without the Push Notifications capability.
        print("[Push] registration failed: \(error.localizedDescription)")
    }
}

/** What a tapped notification was about, pulled out of its payload. */
struct PushPayload: Sendable {
    /** The server's "type": join_request, join_approved, party_started, friend_request, friend_accepted. */
    var type: String
    /** Which button was pressed, or the default action for a plain tap. */
    var action: String
    var partyID: String?
    var requestID: String?
}

/**
 * Handles notifications: join requests get "Let them in" / "Decline" buttons
 * that work right from the lock screen.
 */
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    static let joinRequestCategory = "JOIN_REQUEST"
    static let approveAction = "APPROVE"
    static let declineAction = "DECLINE"

    static func registerCategories() {
        let approve = UNNotificationAction(identifier: approveAction, title: "Let them in", options: [])
        let decline = UNNotificationAction(identifier: declineAction, title: "Decline", options: [.destructive])
        let joinRequest = UNNotificationCategory(identifier: joinRequestCategory, actions: [approve, decline], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([joinRequest])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // While the app is open, join requests appear as an in-app prompt instead.
        let type = notification.request.content.userInfo["type"] as? String
        completionHandler(type == "join_request" ? [] : [.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let payload = PushPayload(
            type: info["type"] as? String ?? "",
            action: response.actionIdentifier,
            partyID: info["partyId"] as? String,
            requestID: info["requestId"] as? String
        )
        Task { @MainActor in
            await AppModel.shared.handle(payload)
            completionHandler()
        }
    }
}
