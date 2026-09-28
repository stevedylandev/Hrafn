import Foundation
import GRDB

/// A file shared in a message. Stored as JSON on the message row.
public struct Attachment: Codable, Sendable, Hashable {

    public enum Kind: String, Codable, Sendable, Hashable {
        case image, video, audio, file
    }

    /// Where others fetch it: the upload's GET URL. `nil` until our own
    /// upload has finished.
    public var url: URL?
    public var fileName: String
    public var mimeType: String?
    /// Bytes, when known (our own files; others' once downloaded or asked).
    public var size: Int?
    /// The copy on this device, relative to the media directory.
    public var localPath: String?
    public var width: Int?
    public var height: Int?
    /// Seconds, for audio and video.
    public var duration: Double?
    /// Recorded in the app rather than picked from files.
    public var isVoiceMessage: Bool
    /// The last upload or download failed; the text says why.
    public var error: String?
    /// Automatic download was decided on (done, or left for a tap).
    public var autoDownloadConsidered: Bool
    /// XEP-0300 SHA-256 digest (base64): sent with our files, checked on
    /// others' once downloaded (XEP-0446).
    public var sha256: String?
    /// XEP-0264: a small picture to show before the file is here.
    public var thumbnail: Data?
    /// XEP-0454: the file at `url` is AES-256-GCM ciphertext; this is the
    /// `aesgcm://` link's fragment (hex IV, then key).
    public var encryptionKey: String?

    public init(url: URL? = nil, fileName: String, mimeType: String? = nil, size: Int? = nil,
                localPath: String? = nil, width: Int? = nil, height: Int? = nil, duration: Double? = nil,
                isVoiceMessage: Bool = false, error: String? = nil, autoDownloadConsidered: Bool = false,
                sha256: String? = nil, thumbnail: Data? = nil, encryptionKey: String? = nil) {
        self.url = url
        self.fileName = fileName
        self.mimeType = mimeType
        self.size = size
        self.localPath = localPath
        self.width = width
        self.height = height
        self.duration = duration
        self.isVoiceMessage = isVoiceMessage
        self.error = error
        self.autoDownloadConsidered = autoDownloadConsidered
        self.sha256 = sha256
        self.thumbnail = thumbnail
        self.encryptionKey = encryptionKey
    }

    private enum CodingKeys: String, CodingKey {
        case url, fileName, mimeType, size, localPath, width, height, duration, isVoiceMessage, error
        case autoDownloadConsidered, sha256, thumbnail, encryptionKey
    }

    /// Lenient, so rows written by another version still load.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decodeIfPresent(URL.self, forKey: .url)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName) ?? "file"
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
        size = try c.decodeIfPresent(Int.self, forKey: .size)
        localPath = try c.decodeIfPresent(String.self, forKey: .localPath)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        isVoiceMessage = try c.decodeIfPresent(Bool.self, forKey: .isVoiceMessage) ?? false
        error = try c.decodeIfPresent(String.self, forKey: .error)
        autoDownloadConsidered = try c.decodeIfPresent(Bool.self, forKey: .autoDownloadConsidered) ?? false
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
        thumbnail = try c.decodeIfPresent(Data.self, forKey: .thumbnail)
        encryptionKey = try c.decodeIfPresent(String.self, forKey: .encryptionKey)
    }

    public var kind: Kind {
        switch mimeType?.split(separator: "/").first {
        case "image": .image
        case "video": .video
        case "audio": .audio
        default: .file
        }
    }

    /// Our own file that has not reached the upload service yet.
    public var needsUpload: Bool { url == nil }
    public var isDownloaded: Bool { localPath != nil }
}

/// What a contact (or our own account) publishes about themselves: avatar
/// (XEP-0084, else the vCard photo of XEP-0153) and nickname (XEP-0172).
public struct Profile: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "profile"

    public var accountID: String
    public var jid: String
    public var nickname: String?
    /// Hex SHA-1 of the image; the file is named after it.
    public var avatarHash: String?
    public var avatarType: String?
    /// The avatar came from PEP, which wins over a vCard photo.
    public var avatarFromPEP: Bool
    /// When the PEP avatar was last asked for, to refresh contacts whose
    /// server does not notify.
    public var checkedAt: Date?

    public init(accountID: String, jid: String, nickname: String? = nil, avatarHash: String? = nil,
                avatarType: String? = nil, avatarFromPEP: Bool = false, checkedAt: Date? = nil) {
        self.accountID = accountID
        self.jid = jid
        self.nickname = nickname
        self.avatarHash = avatarHash
        self.avatarType = avatarType
        self.avatarFromPEP = avatarFromPEP
        self.checkedAt = checkedAt
    }
}

// MARK: - Attachments

extension HrafnDatabase {

    /// Records a file the user is sending, before it is uploaded. `nick` for
    /// rooms.
    public func insertOutgoing(accountID: String, peer: String, attachment: Attachment, id: String,
                               nick: String? = nil, timestamp: Date = Date()) throws -> StoredMessage {
        try writer.write { db in
            var row = StoredMessage(accountID: accountID, peer: peer, isOutgoing: true,
                                    body: attachment.url?.absoluteString ?? "", timestamp: timestamp,
                                    originID: id, stanzaID: id, state: .pending, isMarkable: nick == nil,
                                    senderNick: nick, attachment: attachment)
            try row.insert(db)
            try Self.touchConversation(accountID, peer, at: timestamp, db)
            try Self.markRead(accountID, peer, upTo: timestamp, db)
            return row
        }
    }

    /// Changes a message's attachment; returns the updated row.
    @discardableResult
    public func updateAttachment(messageID: Int64, _ change: (inout Attachment) -> Void) throws -> StoredMessage? {
        try writer.write { db in
            guard var row = try StoredMessage.fetchOne(db, key: messageID), var attachment = row.attachment else {
                return nil
            }
            change(&attachment)
            row.attachment = attachment
            try row.update(db)
            return row
        }
    }

    /// Our upload finished: the URL becomes the body, as others will see it.
    @discardableResult
    /// `body` is what the message carries: the URL, or for an encrypted
    /// file its `aesgcm://` link.
    public func completeUpload(messageID: Int64, url: URL, encryptionKey: String? = nil,
                               body: String? = nil) throws -> StoredMessage? {
        try writer.write { db in
            guard var row = try StoredMessage.fetchOne(db, key: messageID), row.attachment != nil else { return nil }
            row.attachment?.url = url
            row.attachment?.encryptionKey = encryptionKey
            row.attachment?.error = nil
            row.body = body ?? url.absoluteString
            try row.update(db)
            return row
        }
    }

    /// Others' files that arrived unread and have not been considered for
    /// automatic download yet — including ones the notification service
    /// extension stored while the app was suspended.
    public func attachmentsAwaitingDownload(accountID: String) throws -> [StoredMessage] {
        try writer.read { db in
            try StoredMessage.fetchAll(db, sql: """
                SELECT * FROM message
                WHERE accountID = ? AND attachment IS NOT NULL AND NOT isRetracted AND state != 'read'
                  AND json_extract(attachment, '$.url') IS NOT NULL
                  AND json_extract(attachment, '$.localPath') IS NULL
                  AND NOT COALESCE(json_extract(attachment, '$.autoDownloadConsidered'), 0)
                ORDER BY timestamp, id
                """, arguments: [accountID])
        }
    }

    /// Every file stored on this device for an account, for clean-up when
    /// history is deleted.
    public func localAttachmentPaths(accountID: String, peer: String? = nil) throws -> [String] {
        try writer.read { db in
            var request = StoredMessage.filter(Column("accountID") == accountID && Column("attachment") != nil)
            if let peer { request = request.filter(Column("peer") == peer) }
            return try request.fetchAll(db).compactMap { $0.attachment?.localPath }
        }
    }
}

// MARK: - Profiles

extension HrafnDatabase {

    public func profile(accountID: String, jid: String) throws -> Profile? {
        try writer.read { db in try Profile.fetchOne(db, key: ["accountID": accountID, "jid": jid]) }
    }

    /// Changes (creating if needed) a profile; returns it.
    @discardableResult
    public func updateProfile(accountID: String, jid: String, _ change: (inout Profile) -> Void) throws -> Profile {
        try writer.write { db in
            var profile = try Profile.fetchOne(db, key: ["accountID": accountID, "jid": jid])
                ?? Profile(accountID: accountID, jid: jid)
            change(&profile)
            try profile.save(db)
            return profile
        }
    }

    /// Profiles for an account, by bare JID.
    public func profiles(accountID: String) -> AsyncThrowingStream<[String: Profile], any Error> {
        observe { db in
            Dictionary(try Profile.filter(Column("accountID") == accountID).fetchAll(db).map { ($0.jid, $0) },
                       uniquingKeysWith: { a, _ in a })
        }
    }

    public func profileStream(accountID: String, jid: String) -> AsyncThrowingStream<Profile?, any Error> {
        observe { db in try Profile.fetchOne(db, key: ["accountID": accountID, "jid": jid]) }
    }

    /// Roster contacts whose PEP avatar was never checked, or not since `before`.
    public func profilesToRefresh(accountID: String, checkedBefore before: Date) throws -> [String] {
        try writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT c.jid FROM contact c LEFT JOIN profile p ON p.accountID = c.accountID AND p.jid = c.jid
                WHERE c.accountID = ? AND c.inRoster AND (p.checkedAt IS NULL OR p.checkedAt < ?)
                """, arguments: [accountID, before])
        }
    }

    /// Every avatar hash still in use, so unused image files can be removed.
    public func avatarHashesInUse() throws -> Set<String> {
        try writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT DISTINCT avatarHash FROM profile WHERE avatarHash IS NOT NULL"))
        }
    }
}
