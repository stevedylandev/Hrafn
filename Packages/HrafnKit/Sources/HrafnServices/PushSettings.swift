import Foundation
import XMPPCore

/// Where this installation asks servers to send XEP-0357 notifications.
///
/// The app server is fpush (docker/fpush): the node is the APNs device token,
/// and `pushModule` names the fpush module holding the matching APNs
/// certificate (sandbox and production are separate modules).
public struct PushSettings: Sendable, Equatable {
    /// The app server's JID.
    public var service: JID
    /// Passed back to the app server with each notification.
    public var publishOptions: [String: String]

    public init(service: JID, publishOptions: [String: String] = [:]) {
        self.service = service
        self.publishOptions = publishOptions
    }
}

/// One device's registration: the settings and the current APNs token.
public struct PushRegistration: Sendable, Equatable {
    public var settings: PushSettings
    /// Hex APNs device token, the XEP-0357 node.
    public var node: String

    public init(settings: PushSettings, token: Data) {
        self.settings = settings
        node = token.map { String(format: "%02x", $0) }.joined()
    }

    public init(settings: PushSettings, node: String) {
        self.settings = settings
        self.node = node
    }
}

/// Whether the account's server takes push registrations, for the UI.
public enum PushStatus: Sendable, Equatable {
    /// No token yet, or push not configured.
    case unavailable
    /// The server does not implement XEP-0357: no notifications while the app
    /// is closed.
    case unsupported
    case enabled
    case failed(String)
}
