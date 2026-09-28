import Foundation
import ImageIO
import HrafnStore
import XMPPClient
import XMPPCore
import XMPPIM
import XMPPXML

/// A file ready to send: already in the media store (`MediaStore.importFile`).
public struct OutgoingFile: Sendable, Hashable {
    public var localPath: String
    public var fileName: String
    public var mimeType: String?
    public var width: Int?
    public var height: Int?
    public var duration: Double?
    public var isVoiceMessage: Bool

    public init(localPath: String, fileName: String, mimeType: String?, width: Int? = nil, height: Int? = nil,
                duration: Double? = nil, isVoiceMessage: Bool = false) {
        self.localPath = localPath
        self.fileName = fileName
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.duration = duration
        self.isVoiceMessage = isVoiceMessage
    }
}

extension AccountSession {

    static let mediaFeatures = [Namespaces.oob, Avatars.notifyFeature, Nicknames.notifyFeature]

    /// Contacts' PEP avatars are asked for again after this long, for
    /// servers that do not notify (ejabberd, in testing).
    static let profileRefreshInterval: TimeInterval = 24 * 60 * 60
    /// At most this many contacts are refreshed per session.
    static let profileRefreshLimit = 50

    // MARK: - Sending files

    /// Stores the message with its file, then uploads and sends it. Without a
    /// connection it waits in the outbox like a text message.
    @discardableResult
    public func sendFile(_ file: OutgoingFile, to peer: String) async throws -> StoredMessage {
        guard let to = try? JID(peer) else { throw AccountError.invalidJID(peer) }
        let key = conversationAddress(to).description
        let url = media.url(for: file.localPath)
        let attachment = Attachment(fileName: file.fileName, mimeType: file.mimeType, size: MediaStore.fileSize(of: url),
                                    localPath: file.localPath, width: file.width, height: file.height,
                                    duration: file.duration, isVoiceMessage: file.isVoiceMessage,
                                    autoDownloadConsidered: true)
        let room = isRoom(key)
        let row = try database.insertOutgoing(accountID: account.id, peer: key, attachment: attachment,
                                              id: StanzaID.make(), nick: room ? (rooms[key]?.nick ?? defaultNick) : nil)
        Task { await self.deliverFile(row) }
        return row
    }

    /// Tries a failed file again.
    public func retryFile(messageID: Int64) async throws {
        guard let row = try database.message(id: messageID), row.isOutgoing, row.attachment != nil else {
            throw AccountError.notFound
        }
        try database.setState(messageID: messageID, .pending)
        try database.updateAttachment(messageID: messageID) { $0.error = nil }
        if let row = try database.message(id: messageID) { await deliverFile(row) }
    }

    /// Uploads a pending file if it still needs it, then sends the message
    /// if its conversation can take it. Returns whether the message went out.
    @discardableResult
    func deliverFile(_ row: StoredMessage) async -> Bool {
        guard let id = row.id, row.state == .pending, var attachment = row.attachment else { return false }
        if isRoom(row.peer), rooms[row.peer]?.isJoined != true { return false }
        // In an encrypted conversation the file is uploaded encrypted and its
        // link sent inside an OMEMO body (XEP-0454). A file uploaded the
        // other way before the conversation changed is uploaded again: a
        // plain one must not be linked from an encrypted chat, nor an
        // encrypted one's key sent in the clear.
        let encrypted: Bool
        do {
            encrypted = try await encrypts(to: row.peer)
        } catch let error as RoomEncryptionError {
            try? database.setState(messageID: id, .failed, errorText: error.description)
            return false
        } catch {
            return false
        }
        if attachment.url != nil, (attachment.encryptionKey != nil) != encrypted {
            attachment.url = nil
            attachment.encryptionKey = nil
        }
        if attachment.needsUpload {
            guard !uploading.contains(id), await client.jid != nil else { return false }
            uploading.insert(id)
            defer { uploading.remove(id) }
            if !encrypted, attachment.sha256 == nil, let path = attachment.localPath {
                // XEP-0446: a digest to check the file by, and a thumbnail to
                // show before it is fetched. Worked out once, before upload.
                let local = media.url(for: path)
                attachment.sha256 = MediaPreparation.sha256(of: local)
                attachment.thumbnail = await MediaPreparation.thumbnail(of: local, kind: attachment.kind)?.data
                let (sha256, thumbnail) = (attachment.sha256, attachment.thumbnail)
                _ = try? database.updateAttachment(messageID: id) {
                    $0.sha256 = sha256
                    $0.thumbnail = thumbnail
                }
            }
            do {
                guard let url = try await upload(attachment, messageID: id, encrypted: encrypted) else { return false }
                attachment.url = url
                attachment.encryptionKey = try? database.message(id: id)?.attachment?.encryptionKey
            } catch {
                await uploadFailed(id, error)
                return false
            }
        }
        guard let url = attachment.url, let to = try? JID(row.peer), let originID = row.originID else { return false }
        if encrypted {
            // The link alone, as the body: no OOB or file metadata, which
            // would go in the clear.
            guard let fragment = attachment.encryptionKey, let link = FileEncryption.link(for: url, fragment: fragment),
                  let current = try? database.message(id: id) else { return false }
            let message = isRoom(row.peer) ? Message.groupchat(to: to, body: link, id: originID)
                : addressed(Message.chat(to: to, body: link, id: originID), to: row.peer)
            return await transmit(message, row: current)
        }
        var message: Message
        if isRoom(row.peer) {
            message = .groupchatFile(to: to, url: url, id: originID)
        } else {
            message = addressed(.file(to: to, url: url, id: originID), to: row.peer)
        }
        message = message.sharing(SharedFile(metadata: Self.metadata(of: attachment), sources: [url],
                                             disposition: "inline"))
        guard (try? await client.send(message)) != nil else { return false }
        try? database.markSent(messageID: id)
        return true
    }

    /// XEP-0446 for one of our files.
    static func metadata(of attachment: Attachment) -> FileMetadata {
        var thumbnails: [FileThumbnail] = []
        if let data = attachment.thumbnail, let image = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any] {
            thumbnails.append(FileThumbnail(data: data, mediaType: "image/jpeg",
                                            width: properties[kCGImagePropertyPixelWidth] as? Int,
                                            height: properties[kCGImagePropertyPixelHeight] as? Int))
        }
        return FileMetadata(mediaType: attachment.mimeType, name: attachment.fileName, size: attachment.size,
                            width: attachment.width, height: attachment.height,
                            length: attachment.duration.map { Int(($0 * 1000).rounded()) },
                            hashes: attachment.sha256.map { ["sha-256": $0] } ?? [:], thumbnails: thumbnails)
    }

    /// XEP-0363: slot, then PUT, with progress in `status`.
    private func upload(_ attachment: Attachment, messageID: Int64, encrypted: Bool) async throws -> URL? {
        let status = self.status
        await MainActor.run { status.transfers[messageID] = 0 }
        defer { Task { @MainActor in status.transfers[messageID] = nil } }
        let uploader = FileUploader(client: client, transfer: transfer, database: database, media: media)
        let (url, service) = try await uploader.upload(attachment, messageID: messageID, service: uploadService,
                                                       encrypted: encrypted) { fraction in
            Task { @MainActor in if status.transfers[messageID] != nil { status.transfers[messageID] = fraction } }
        }
        uploadService = service
        return url
    }

    /// Refusals are final until the user retries; network trouble leaves the
    /// file in the outbox for the next session.
    private func uploadFailed(_ messageID: Int64, _ error: any Error) async {
        FileUploader.recordFailure(error, messageID: messageID, database: database)
    }

    static func describeTransfer(_ error: any Error) -> String {
        switch error {
        case let error as HTTPUpload.Failure:
            switch error {
            case .fileTooLarge(let max):
                return max.map { String(localized: "The file is larger than the server allows (\(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)))", bundle: .module) }
                    ?? String(localized: "The file is larger than the server allows", bundle: .module)
            case .quota: return String(localized: "Upload quota reached; try again later", bundle: .module)
            case .unavailable: return TransferError.noUploadService.description
            case .invalidSlot: return String(localized: "The upload service gave an unusable address", bundle: .module)
            }
        case let error as TransferError: return error.description
        case let error as URLError: return error.localizedDescription
        case let error as StanzaError: return error.text ?? error.condition.rawValue
        default: return String(describing: error)
        }
    }

    // MARK: - Downloading

    /// Fetches a shared file now, whatever its size or the network.
    public func download(messageID: Int64) async throws {
        guard let row = try database.message(id: messageID), row.attachment?.url != nil else { throw AccountError.notFound }
        try await fetch(row, maxBytes: nil, allowsExpensiveNetwork: true)
    }

    /// Downloads what the policy allows among newly arrived files.
    func processNewAttachments() async {
        guard !processingAttachments, let rows = try? database.attachmentsAwaitingDownload(accountID: account.id),
              !rows.isEmpty else { return }
        processingAttachments = true
        defer { processingAttachments = false }
        let policy = mediaPolicy
        for row in rows {
            guard let id = row.id, let url = row.attachment?.url else { continue }
            _ = try? database.updateAttachment(messageID: id) { $0.autoDownloadConsidered = true }
            guard policy.autoDownload != .never else { continue }
            let expensive = policy.autoDownload == .always
            do {
                if let size = try await transfer.contentLength(of: url, allowsExpensiveNetwork: expensive) {
                    _ = try? database.updateAttachment(messageID: id) { $0.size = size }
                    guard size <= policy.maxAutoDownloadSize else { continue }
                }
                try await fetch(row, maxBytes: policy.maxAutoDownloadSize, allowsExpensiveNetwork: expensive)
            } catch {
                // Left for a tap; the chat shows the file as not downloaded.
                continue
            }
        }
    }

    private func fetch(_ row: StoredMessage, maxBytes: Int?, allowsExpensiveNetwork: Bool) async throws {
        guard let id = row.id, let attachment = row.attachment, let url = attachment.url,
              !downloading.contains(id) else { return }
        downloading.insert(id)
        defer { downloading.remove(id) }
        let status = self.status
        await MainActor.run { status.transfers[id] = 0 }
        defer { Task { @MainActor in status.transfers[id] = nil } }
        do {
            var temporary = try await transfer.download(url, maxBytes: maxBytes,
                                                        allowsExpensiveNetwork: allowsExpensiveNetwork) { fraction in
                Task { @MainActor in if status.transfers[id] != nil { status.transfers[id] = fraction } }
            }
            if let fragment = attachment.encryptionKey {
                let ciphertext = temporary
                defer { try? FileManager.default.removeItem(at: ciphertext) }
                temporary = try FileEncryption.decrypt(ciphertext, fragment: fragment)
            }
            if let expected = attachment.sha256, MediaPreparation.sha256(of: temporary) != expected {
                try? FileManager.default.removeItem(at: temporary)
                throw TransferError.digestMismatch
            }
            let path = try media.importFile(temporary, named: attachment.fileName)
            let stored = media.url(for: path)
            let size = MediaStore.fileSize(of: stored)
            let dimensions = attachment.kind == .image ? MediaStore.imageSize(of: stored) : nil
            try database.updateAttachment(messageID: id) {
                $0.localPath = path
                $0.size = size ?? $0.size
                $0.width = dimensions?.width ?? $0.width
                $0.height = dimensions?.height ?? $0.height
                $0.error = nil
            }
        } catch {
            if maxBytes == nil {
                _ = try? database.updateAttachment(messageID: id) { $0.error = Self.describeTransfer(error) }
            }
            throw error
        }
    }

    // MARK: - Profiles

    /// A fresh session: our own profile, then contacts not checked lately.
    func refreshProfiles() async {
        await refreshProfile(of: jid, includeNick: true)
        let due = (try? database.profilesToRefresh(accountID: account.id,
                                                    checkedBefore: Date().addingTimeInterval(-Self.profileRefreshInterval))) ?? []
        let contacts = (try? database.fetchContacts(accountID: account.id)) ?? []
        for peer in due.prefix(Self.profileRefreshLimit) {
            guard let address = try? JID(peer) else { continue }
            let named = contacts.first { $0.jid == peer }?.name != nil
            await refreshProfile(of: address, includeNick: !named)
        }
    }

    private func refreshProfile(of address: JID, includeNick: Bool) async {
        let key = address.bare.description
        guard let metadata = try? await Avatars(client: client).metadata(of: address.bare) else {
            // No PEP avatar (or no answer): keep a vCard photo if there is one.
            _ = try? database.updateProfile(accountID: account.id, jid: key) { profile in
                if profile.avatarFromPEP {
                    profile.avatarHash = nil
                    profile.avatarFromPEP = false
                }
                profile.checkedAt = Date()
            }
            return
        }
        await applyAvatar(metadata, of: address.bare)
        if includeNick, let nick = try? await Nicknames(client: client).fetch(of: address.bare) {
            _ = try? database.updateProfile(accountID: account.id, jid: key) { $0.nickname = nick }
        }
    }

    /// A PEP metadata notification or fetch: the new avatar, or none.
    func applyAvatar(_ info: AvatarInfo?, of address: JID) async {
        let key = address.bare.description
        guard let info else {
            _ = try? database.updateProfile(accountID: account.id, jid: key) {
                $0.avatarHash = nil
                $0.avatarType = nil
                $0.avatarFromPEP = false
                $0.checkedAt = Date()
            }
            return
        }
        if !media.hasAvatar(hash: info.id) {
            guard let data = try? await Avatars(client: client).data(of: address.bare, id: info.id),
                  (try? media.saveAvatar(data, hash: info.id)) != nil else { return }
        }
        _ = try? database.updateProfile(accountID: account.id, jid: key) {
            $0.avatarHash = info.id
            $0.avatarType = info.type
            $0.avatarFromPEP = true
            $0.checkedAt = Date()
        }
    }

    /// XEP-0153: a presence advertising a vCard photo. For contacts with a
    /// PEP avatar, which is the newer protocol, a different hash only means
    /// "look again": servers that convert (XEP-0398) put the PEP avatar's
    /// hash here, and those that do not notify contacts of PEP changes
    /// still pass presence on.
    func receivedPhotoHash(_ advertised: VCardAvatars.Advertised, from address: JID) async {
        let key = address.bare.description
        let profile = try? database.profile(accountID: account.id, jid: key)
        if profile?.avatarFromPEP == true {
            if case .photo(let hash) = advertised, hash != profile?.avatarHash, !vcardFetches.contains(key) {
                vcardFetches.insert(key)
                defer { vcardFetches.remove(key) }
                await refreshProfile(of: address.bare, includeNick: false)
                // Still not it: the photo is only in the vCard.
                guard (try? database.profile(accountID: account.id, jid: key))?.avatarHash != hash else { return }
                _ = try? database.updateProfile(accountID: account.id, jid: key) { $0.avatarFromPEP = false }
            } else {
                return
            }
        }
        await applyVCardPhoto(advertised, profile: profile, of: address.bare)
    }

    /// XEP-0153 in rooms: an occupant's photo hash, kept under their
    /// occupant JID (`room@service/nick`) — we may not know who they are —
    /// and fetched through the room, which passes the request on to them.
    func receivedOccupantPhotoHash(_ advertised: VCardAvatars.Advertised, from occupant: JID) async {
        let profile = try? database.profile(accountID: account.id, jid: occupant.description)
        await applyVCardPhoto(advertised, profile: profile, of: occupant)
    }

    /// Records the vCard photo `advertised` for `address` (a bare JID, or an
    /// occupant JID), fetching it unless we already have that picture.
    private func applyVCardPhoto(_ advertised: VCardAvatars.Advertised, profile: Profile?, of address: JID) async {
        let key = address.description
        switch advertised {
        case .unknown:
            return
        case .none:
            guard profile?.avatarHash != nil else { return }
            _ = try? database.updateProfile(accountID: account.id, jid: key) {
                $0.avatarHash = nil
                $0.avatarType = nil
            }
        case .unverified:
            // Look once a day at most: the same presence comes with every join.
            if let checked = profile?.checkedAt, checked > Date().addingTimeInterval(-Self.profileRefreshInterval),
               profile?.avatarHash == nil { return }
            guard !vcardFetches.contains(key) else { return }
            vcardFetches.insert(key)
            defer { vcardFetches.remove(key) }
            guard let photo = try? await VCardAvatars(client: client).photo(of: address) else {
                _ = try? database.updateProfile(accountID: account.id, jid: key) {
                    $0.avatarHash = nil
                    $0.avatarType = nil
                    $0.checkedAt = Date()
                }
                return
            }
            let hash = Avatars.sha1(photo.data)
            if !media.hasAvatar(hash: hash) {
                guard (try? media.saveAvatar(photo.data, hash: hash)) != nil else { return }
            }
            _ = try? database.updateProfile(accountID: account.id, jid: key) {
                $0.avatarHash = hash
                $0.avatarFromPEP = false
                $0.checkedAt = Date()
            }
        case .photo(let hash):
            guard profile?.avatarHash != hash, !vcardFetches.contains(key) else { return }
            vcardFetches.insert(key)
            defer { vcardFetches.remove(key) }
            if !media.hasAvatar(hash: hash) {
                guard let photo = try? await VCardAvatars(client: client).photo(of: address),
                      Avatars.sha1(photo.data) == hash,
                      (try? media.saveAvatar(photo.data, hash: hash)) != nil else { return }
            }
            _ = try? database.updateProfile(accountID: account.id, jid: key) {
                $0.avatarHash = hash
                $0.avatarFromPEP = false
            }
        }
    }

    func applyNickname(_ change: Nicknames.Change) {
        _ = try? database.updateProfile(accountID: account.id, jid: change.jid.bare.description) { $0.nickname = change.nick }
    }

    // MARK: - Own profile

    /// Publishes our avatar (PNG or JPEG bytes). Servers without XEP-0398
    /// also get it in the vCard, for clients that only read that.
    public func setAvatar(_ data: Data, type: String, width: Int?, height: Int?) async throws {
        guard await client.jid != nil else { throw AccountError.notConnected }
        let info = try await Avatars(client: client).publish(data, type: type, width: width, height: height)
        if try await !serverConvertsVCard() {
            try? await VCardAvatars(client: client).setPhoto(data, type: type)
        }
        try media.saveAvatar(data, hash: info.id)
        try database.updateProfile(accountID: account.id, jid: jid.description) {
            $0.avatarHash = info.id
            $0.avatarType = type
            $0.avatarFromPEP = true
            $0.checkedAt = Date()
        }
        await resendPresence()
    }

    public func removeAvatar() async throws {
        guard await client.jid != nil else { throw AccountError.notConnected }
        try await Avatars(client: client).disable()
        if try await !serverConvertsVCard() {
            try? await VCardAvatars(client: client).setPhoto(nil, type: "image/png")
        }
        try database.updateProfile(accountID: account.id, jid: jid.description) {
            $0.avatarHash = nil
            $0.avatarType = nil
            $0.avatarFromPEP = false
        }
        await resendPresence()
    }

    /// XEP-0172: the name contacts see until they choose one for us.
    public func setNickname(_ nick: String?) async throws {
        guard await client.jid != nil else { throw AccountError.notConnected }
        let nick = nick?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await Nicknames(client: client).publish(nick)
        try database.updateProfile(accountID: account.id, jid: jid.description) {
            $0.nickname = nick?.isEmpty == false ? nick : nil
        }
    }

    private func serverConvertsVCard() async throws -> Bool {
        try await client.discoInfo(jid).supports(Namespaces.pepVCardConversion)
    }
}
