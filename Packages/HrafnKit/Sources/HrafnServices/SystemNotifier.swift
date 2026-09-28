import Foundation
import UserNotifications
import HrafnStore

/// Notification identifiers shared by the app (which handles the actions) and
/// the notification service extension (which builds the content).
public enum MessageNotification {
    public static let category = "MESSAGE"
    public static let replyAction = "REPLY"
    public static let markReadAction = "MARK_READ"
    public static let accountKey = "accountID"
    public static let peerKey = "peer"
    public static let messageKey = "messageID"

    /// The category with inline reply and mark-as-read. Registered by the app.
    public static var categories: Set<UNNotificationCategory> {
        let reply = UNTextInputNotificationAction(identifier: replyAction, title: String(localized: "Reply", bundle: .module), options: [],
                                                  textInputButtonTitle: String(localized: "Send", bundle: .module), textInputPlaceholder: String(localized: "Message", bundle: .module))
        let markRead = UNNotificationAction(identifier: markReadAction, title: String(localized: "Mark as Read", bundle: .module), options: [])
        return [UNNotificationCategory(identifier: category, actions: [reply, markRead], intentIdentifiers: [],
                                       options: [])]
    }

    /// Fills `content` for one message: sender as title, text as body,
    /// threaded per conversation.
    public static func fill(_ content: UNMutableNotificationContent, with notification: PendingNotification,
                            badge: Int?) {
        content.title = notification.title
        if let sender = notification.sender { content.subtitle = sender }
        content.body = notification.message.preview
        content.sound = .default
        content.threadIdentifier = notification.threadID
        content.categoryIdentifier = category
        content.userInfo = [
            accountKey: notification.accountID,
            peerKey: notification.peer,
            messageKey: notification.id,
        ]
        if let badge { content.badge = NSNumber(value: badge) }
    }

    public static func content(for notification: PendingNotification, badge: Int?) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        fill(content, with: notification, badge: badge)
        return content
    }

    /// The request id for a message, so the same message never shows twice.
    public static func identifier(for notification: PendingNotification) -> String {
        "message-\(notification.accountID)-\(notification.id)"
    }

    /// The message a notification announces, if it announces one.
    public static func messageID(of userInfo: [AnyHashable: Any]) -> Int64? {
        (userInfo[messageKey] as? NSNumber)?.int64Value
    }

    /// Of `delivered` (request id, userInfo), the ones announcing a message
    /// that is no longer unread. Banners that name no message stay.
    public static func stale(_ delivered: [(id: String, userInfo: [AnyHashable: Any])],
                             keeping unread: Set<Int64>) -> [String] {
        delivered.compactMap { entry in
            guard let id = messageID(of: entry.userInfo), !unread.contains(id) else { return nil }
            return entry.id
        }
    }

    /// The (accountID, peer) a notification belongs to.
    public static func route(of userInfo: [AnyHashable: Any]) -> (accountID: String, peer: String)? {
        guard let accountID = userInfo[accountKey] as? String, let peer = userInfo[peerKey] as? String else { return nil }
        return (accountID, peer)
    }
}

/// Announces through `UNUserNotificationCenter`.
public struct SystemNotifier: Notifier {

    public init() {}

    public func announce(_ notifications: [PendingNotification]) async {
        let center = UNUserNotificationCenter.current()
        for notification in notifications {
            let request = UNNotificationRequest(identifier: MessageNotification.identifier(for: notification),
                                                content: MessageNotification.content(for: notification, badge: nil),
                                                trigger: nil)
            try? await center.add(request)
        }
    }

    public func withdraw(threadID: String) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let ids = delivered.filter { $0.request.content.threadIdentifier == threadID }.map(\.request.identifier)
        if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
    }

    public func withdraw(keeping unread: Set<Int64>) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let stale = MessageNotification.stale(delivered.map { ($0.request.identifier, $0.request.content.userInfo) },
                                              keeping: unread)
        if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
    }

    public func setBadge(_ count: Int) async {
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
    }
}
