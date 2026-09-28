import Foundation
import Observation
import XMPPIM

/// How reachable a contact is, for the UI.
public enum ContactAvailability: String, Sendable, Hashable, Comparable {
    case chat, online, away, extendedAway, doNotDisturb, offline

    init(_ availability: Availability) {
        switch availability {
        case .chat: self = .chat
        case .online: self = .online
        case .away: self = .away
        case .xa: self = .extendedAway
        case .dnd: self = .doNotDisturb
        case .offline: self = .offline
        }
    }

    var protocolValue: Availability {
        switch self {
        case .chat: .chat
        case .online: .online
        case .away: .away
        case .extendedAway: .xa
        case .doNotDisturb: .dnd
        case .offline: .offline
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.protocolValue < rhs.protocolValue }
}

/// XEP-0085, for the UI.
public enum TypingState: String, Sendable, Hashable {
    case active, composing, paused, inactive, gone

    init(_ state: ChatState) {
        self = TypingState(rawValue: state.rawValue) ?? .active
    }

    var protocolValue: ChatState { ChatState(rawValue: rawValue) ?? .active }
}

public enum ConnectionStatus: Sendable, Equatable {
    case offline
    case connecting
    case online
    case reconnecting(attempt: Int)
    case waitingForNetwork
    /// Stopped for good; the message says why.
    case failed(String)

    public var label: String {
        switch self {
        case .offline: String(localized: "Offline", bundle: .module)
        case .connecting: String(localized: "Connecting…", bundle: .module)
        case .online: String(localized: "Online", bundle: .module)
        case .reconnecting(let attempt):
            attempt > 1 ? String(localized: "Reconnecting (\(attempt))…", bundle: .module)
                : String(localized: "Reconnecting…", bundle: .module)
        case .waitingForNetwork: String(localized: "Waiting for network", bundle: .module)
        case .failed(let reason): String(localized: "Failed: \(reason)", bundle: .module)
        }
    }
}

/// One room occupant, for the UI.
public struct RoomOccupantStatus: Sendable, Hashable, Identifiable {
    public var nick: String
    public var role: MUCRole
    public var affiliation: MUCAffiliation
    /// Real bare JID, when the room reveals it.
    public var jid: String?
    public var availability: ContactAvailability
    public var id: String { nick }
}

/// Where we are with one room this session, for the UI.
public struct RoomStatus: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case joining
        case joined
        /// Not joined; the text says why (kicked, banned, a refused join, …).
        case notJoined(String?)
    }

    public var state: State
    /// Our nickname, once the room confirms it.
    public var nick: String?
    public var role: MUCRole = .none
    public var affiliation: MUCAffiliation = .none
    /// By role, then nick.
    public var occupants: [RoomOccupantStatus] = []
    /// XEP-0425: the room lets moderators remove messages.
    public var supportsModeration = false

    public var isJoined: Bool { state == .joined }
    /// §5.1: visitors have no voice in moderated rooms.
    public var canSend: Bool { isJoined && role != .visitor && role != .none }
    public var isModerator: Bool { role == .moderator }
    public var canModerate: Bool { isJoined && isModerator && supportsModeration }
    public var isOwner: Bool { affiliation == .owner }
    public var isAdmin: Bool { affiliation == .owner || affiliation == .admin }
}

/// What the UI shows about one account that is not in the database because it
/// does not outlive the session: connection state, presence, typing.
@MainActor
@Observable
public final class AccountStatus {
    public internal(set) var connection: ConnectionStatus = .offline
    /// The full JID of the current session.
    public internal(set) var boundJID: String?
    public internal(set) var presence: [String: ContactAvailability] = [:]
    public internal(set) var statusMessages: [String: String] = [:]
    public internal(set) var typing: [String: TypingState] = [:]
    /// The latest non-fatal problem (a failed roster fetch, say).
    public internal(set) var lastError: String?
    /// A certificate the system rejected on the last attempt, awaiting the
    /// user's decision. Hex SHA-256.
    public internal(set) var rejectedCertificate: String?
    /// XEP-0357 registration on the current (or last) session.
    public internal(set) var push: PushStatus = .unavailable
    /// Rooms this session has joined or tried to, by bare JID.
    public internal(set) var rooms: [String: RoomStatus] = [:]
    /// File uploads and downloads in progress: message id → 0...1.
    public internal(set) var transfers: [Int64: Double] = [:]

    public init() {}

    public func availability(of jid: String) -> ContactAvailability {
        presence[jid] ?? .offline
    }

    public func room(_ jid: String) -> RoomStatus {
        rooms[jid] ?? RoomStatus(state: .notJoined(nil))
    }
}
