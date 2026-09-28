import UIKit
import UserNotifications
import HrafnServices
import HrafnStore

/// APNs registration and notification handling, which SwiftUI has no API for.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Owned here rather than by the SwiftUI scene, so it exists before a
    /// notification action that launched the app is delivered.
    let app = AppModel()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(MessageNotification.categories)
        return true
    }

    /// Asks for permission (once the user has an account, so the prompt makes
    /// sense) and registers with APNs. The token arrives below.
    static func registerForNotifications() async {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        guard granted else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await app.manager.setPushToken(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        // The simulator without a paired device, or no network: the app still
        // works in the foreground; the account screen shows "Not registered".
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// In the foreground the chat list is the notification.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
    async -> UNNotificationPresentationOptions {
        []
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let route = MessageNotification.route(of: response.notification.request.content.userInfo) else {
            return
        }
        switch response.actionIdentifier {
        case MessageNotification.replyAction:
            guard let text = (response as? UNTextInputNotificationResponse)?.userText,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            await app.handleInBackground { manager in
                try? await manager.reply(accountID: route.accountID, peer: route.peer, text: text)
            }
        case MessageNotification.markReadAction:
            await app.handleInBackground { manager in
                await manager.markRead(accountID: route.accountID, peer: route.peer)
            }
        case UNNotificationDefaultActionIdentifier:
            await MainActor.run { app.openChat(accountID: route.accountID, peer: route.peer) }
        default:
            break
        }
    }
}

/// `beginBackgroundTask`, so work started in the background can finish.
@MainActor
final class BackgroundAssertion {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    /// `expired` runs when iOS wants the time back; call `end()` from it.
    func begin(expired: @escaping @MainActor () -> Void) {
        guard identifier == .invalid else { return }
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Hrafn session") {
            MainActor.assumeIsolated { expired() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
