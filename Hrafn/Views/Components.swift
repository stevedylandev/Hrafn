import SwiftUI
import HrafnServices
import HrafnStore
import XMPPIM

/// A contact's or room's picture: their avatar when we have it, else
/// initials on their XEP-0392 colour.
struct Avatar: View {
    let name: String
    var size: CGFloat = 44
    var availability: ContactAvailability?
    /// A room: a group symbol instead of initials.
    var isGroup = false
    /// The avatar image on disk (`AppModel.avatarURL`).
    var image: URL?
    /// What the colour is derived from: the bare JID for contacts, the
    /// nickname for room occupants (XEP-0392 §4). Defaults to `name`.
    var colorKey: String?

    var body: some View {
        Circle()
            .fill(Self.color(for: colorKey ?? name).gradient)
            .frame(width: size, height: size)
            .overlay {
                if let image, let picture = AvatarImages.image(at: image) {
                    Image(uiImage: picture)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(Circle())
                } else if isGroup {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: size * 0.32, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let availability, availability != .offline {
                    Circle()
                        .fill(availability.color)
                        .frame(width: size * 0.28, height: size * 0.28)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                }
            }
            // Only the presence dot says something the name beside it doesn't.
            .accessibilityElement()
            .accessibilityLabel(availability.map { $0 == .offline ? "" : $0.label } ?? "")
            .accessibilityHidden(availability == nil || availability == .offline)
    }

    private var initials: String {
        let letters = name.split(whereSeparator: { $0 == " " || $0 == "@" || $0 == "." })
            .prefix(2).compactMap(\.first)
        return String(letters).uppercased()
    }

    /// XEP-0392: the same colour for the same name in every client.
    static func color(for key: String) -> Color {
        let rgb = ConsistentColor.rgb(for: key)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

/// Decoded avatars, small and few, kept for the life of the process.
@MainActor
enum AvatarImages {
    private static let cache = NSCache<NSURL, UIImage>()

    static func image(at url: URL) -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let image = UIImage(contentsOfFile: url.path)?.preparingThumbnail(of: CGSize(width: 240, height: 240))
        else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

extension ContactAvailability {
    var color: Color {
        switch self {
        case .chat, .online: .green
        case .away, .extendedAway: .orange
        case .doNotDisturb: .red
        case .offline: .gray
        }
    }

    var label: String {
        switch self {
        case .chat: String(localized: "Free to chat")
        case .online: String(localized: "Online")
        case .away: String(localized: "Away")
        case .extendedAway: String(localized: "Extended away")
        case .doNotDisturb: String(localized: "Do not disturb")
        case .offline: String(localized: "Offline")
        }
    }
}

extension RoomNotify {
    var label: String {
        switch self {
        case .always: String(localized: "All messages")
        case .mentions: String(localized: "Mentions only")
        case .never: String(localized: "Never")
        }
    }
}

extension RoomStatus {
    /// For a chat's subtitle.
    var summary: String {
        switch state {
        case .joining: return String(localized: "Joining…")
        case .joined: return String(localized: "\(occupants.count) participants")
        case .notJoined(let reason): return reason ?? String(localized: "Not joined")
        }
    }
}

extension MUCRole {
    var label: String {
        switch self {
        case .moderator: String(localized: "Moderator")
        case .participant: String(localized: "Participant")
        case .visitor: String(localized: "Visitor")
        case .none: String(localized: "None")
        }
    }
}

extension MUCAffiliation {
    var label: String {
        switch self {
        case .owner: String(localized: "Owner")
        case .admin: String(localized: "Admin")
        case .member: String(localized: "Member")
        case .none: String(localized: "None")
        case .outcast: String(localized: "Banned")
        }
    }
}

extension ConnectionStatus {
    var color: Color {
        switch self {
        case .online: .green
        case .connecting, .reconnecting: .orange
        case .waitingForNetwork, .offline: .gray
        case .failed: .red
        }
    }
}

extension Contact.Subscription {
    var summary: String {
        switch self {
        case .both: String(localized: "You see each other's status")
        case .to: String(localized: "You see their status; they don't see yours")
        case .from: String(localized: "They see your status; you don't see theirs")
        case .none: String(localized: "Not sharing status")
        }
    }
}

/// A banner for accounts that are not connected, shown above lists.
struct ConnectionBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let problems = app.manager.accounts.compactMap { account -> (String, ConnectionStatus)? in
            guard account.enabled else { return nil }
            let status = app.manager.status(for: account.id).connection
            return status == .online ? nil : (account.jid, status)
        }
        if !problems.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(problems, id: \.0) { jid, status in
                    Label {
                        Text(app.manager.accounts.count > 1 ? "\(jid): \(status.label)" : "\(status.label)")
                    } icon: {
                        Circle().fill(status.color).frame(width: 8, height: 8)
                    }
                    .font(.footnote)
                    .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}
