import Foundation
import UserNotifications
import HrafnServices
import HrafnStore

/// Turns fpush's content-free "New Message" push into the real thing: logs in
/// to each account, reads the archive since the app last did, and shows what
/// arrived (PLAN.md Phase 5). The app is not involved; the two share the
/// database and take turns through per-account locks.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {

    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var fallback: UNMutableNotificationContent?
    private var work: Task<Void, Never>?

    /// Apple's filtering entitlement lets a push with nothing new show nothing;
    /// without it, something must be shown.
    private var canFilter: Bool {
        Bundle.main.object(forInfoDictionaryKey: "HrafnCanFilterNotifications") as? Bool ?? false
    }

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        lock.withLock {
            self.contentHandler = contentHandler
            self.fallback = Self.fallbackContent()
        }
        let canFilter = self.canFilter
        work = Task { [weak self] in
            let content = await Self.fetch(canFilter: canFilter)
            self?.deliver(content)
        }
    }

    /// Out of time: show whatever is ready.
    override func serviceExtensionTimeWillExpire() {
        work?.cancel()
        deliver(lock.withLock { fallback } ?? UNMutableNotificationContent())
    }

    private func deliver(_ content: UNNotificationContent) {
        let handler = lock.withLock {
            defer { contentHandler = nil }
            return contentHandler
        }
        handler?(content)
    }

    /// What a push says when there is nothing better: fpush sends no content.
    private static func fallbackContent() -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Hrafn"
        content.body = String(localized: "New message")
        content.sound = .default
        return content
    }

    private static func fetch(canFilter: Bool) async -> UNNotificationContent {
        let fallback = fallbackContent()
        let container = SharedContainer(appGroup: SharedContainer.hrafnAppGroup)
        guard container.isShared, let database = try? HrafnDatabase(url: container.databaseURL) else { return fallback }

        // Encrypted messages are decrypted here too; without OMEMO storage
        // they are stored as unreadable, never as their fallback text.
        let fetch = BackgroundFetch(database: database, credentials: KeychainCredentialStore(),
                                    lockDirectory: container.lockDirectory, omemo: try? container.openOMEMODatabase())
        // About 30 seconds in all; leave room to hand the content back.
        let outcome = await fetch.run(timeout: .seconds(22))
        // Banners for messages read on another device or retracted since
        // they were shown come down now; this push may be the only chance.
        if let unread = try? database.fetchUnreadMessageIDs() {
            await SystemNotifier().withdraw(keeping: unread)
        }

        guard let first = outcome.notifications.first else {
            // Nothing new: already read elsewhere, a muted chat, or the app
            // is running and announced it itself.
            if canFilter { return UNNotificationContent() }
            fallback.badge = NSNumber(value: outcome.badge)
            return fallback
        }
        // The push becomes the first message; the rest are added alongside.
        let content = MessageNotification.content(for: first, badge: outcome.badge)
        if outcome.notifications.count > 1 {
            await SystemNotifier().announce(Array(outcome.notifications.dropFirst()))
        }
        return content
    }
}
