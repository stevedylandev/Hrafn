import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import GRDB
@testable import HrafnServices
import HrafnStore
import XMPPCore
import XMPPIM

/// Phase 7 end to end: files and avatars through the sessions, the HTTP
/// upload services and the database, against the Docker servers. Off unless
/// `HRAFN_INTEGRATION=1`. Uses its own accounts (friar, nurse).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HRAFN_INTEGRATION"] == "1"),
       .serialized, .timeLimit(.minutes(2)))
@MainActor
struct MediaIntegrationTests {

    /// A real PNG, so image dimensions can be checked.
    private func png(width: Int, height: Int) throws -> URL {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: CGFloat.random(in: 0...1), green: 0.5, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString,
                                                                       1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func outgoing(_ device: Device, _ source: URL, name: String) throws -> OutgoingFile {
        let path = try device.manager.media.importFile(source, named: name, copy: true)
        let size = MediaStore.imageSize(of: device.manager.media.url(for: path))
        return OutgoingFile(localPath: path, fileName: name, mimeType: MediaStore.mimeType(forFileName: name),
                            width: size?.width, height: size?.height)
    }

    private func befriend(_ a: Device, _ b: Device) async throws {
        let aJID = a.account.jid, bJID = b.account.jid
        if try a.contact(bJID)?.subscription == .both, try b.contact(aJID)?.subscription == .both { return }
        try? await a.session.removeContact(bJID)
        try? await b.session.removeContact(aJID)
        try await eventually("roster cleared") { try a.contact(bJID)?.inRoster != true }
        try await a.session.addContact(bJID, name: nil)
        try await eventually("request") { try b.contact(aJID)?.pendingIn == true }
        try await b.session.answerSubscription(from: aJID, approve: true)
        try await eventually("mutual subscription") {
            try a.contact(bJID)?.subscription == .both && b.contact(aJID)?.subscription == .both
        }
    }

    /// Send a picture; it is uploaded, sent, received and fetched by the
    /// other side. Then the same while the sender is offline (outbox), and a
    /// file the receiver's policy leaves for a tap.
    @Test(arguments: [(LiveServer.prosody, LiveServer.prosody), (LiveServer.ejabberd, LiveServer.ejabberd),
                      (LiveServer.prosody, LiveServer.ejabberd)])
    func filesRoundTrip(_ servers: (LiveServer, LiveServer)) async throws {
        let friar = try await Device("friar", on: servers.0)
        let nurse = try await Device("nurse", on: servers.1)
        try await closing([friar, nurse]) {
            try await befriend(friar, nurse)
            let friarJID = friar.account.jid, nurseJID = nurse.account.jid

            let picture = try png(width: 30, height: 20)
            let sent = try await friar.session.sendFile(try outgoing(friar, picture, name: "potion.png"), to: nurseJID)
            #expect(sent.state == .pending && sent.attachment?.needsUpload == true)
            try await eventually("upload and send") {
                try friar.messages(with: nurseJID).first { $0.id == sent.id }.map { $0.state != .pending } == true
            }
            let uploaded = try #require(try friar.messages(with: nurseJID).first { $0.id == sent.id })
            #expect(uploaded.state == .sent || uploaded.state == .delivered)
            let url = try #require(uploaded.attachment?.url)
            #expect(uploaded.body == url.absoluteString)
            #expect(url.host == "upload.\(servers.0.domain)")

            try await eventually("received and downloaded") {
                try nurse.messages(with: friarJID).contains { $0.originID == sent.originID && $0.attachment?.localPath != nil }
            }
            let received = try #require(try nurse.messages(with: friarJID).first { $0.originID == sent.originID })
            let attachment = try #require(received.attachment)
            #expect(attachment.fileName == "potion.png")
            #expect(attachment.kind == .image)
            #expect(attachment.width == 30 && attachment.height == 20)
            let local = nurse.manager.media.url(for: try #require(attachment.localPath))
            #expect(try Data(contentsOf: local) == Data(contentsOf: picture))
            #expect(received.preview == "📷 Photo")
            // XEP-0447/0446/0264: the digest and a thumbnail came with it, and
            // the digest matched (a mismatch would have refused the file).
            let sentAttachment = try #require(try friar.database.message(id: sent.id!)?.attachment)
            #expect(sentAttachment.sha256 != nil && attachment.sha256 == sentAttachment.sha256)
            #expect(attachment.thumbnail != nil)
            #expect(attachment.size == sentAttachment.size)

            // Offline (no session while suspended): the file waits in the
            // outbox, then is uploaded and sent on reconnect.
            await friar.manager.suspend()
            let pendingRow = try friar.database.insertOutgoing(
                accountID: friar.account.id, peer: nurseJID,
                attachment: Attachment(fileName: "later.png", mimeType: "image/png",
                                       localPath: try outgoing(friar, picture, name: "later.png").localPath,
                                       autoDownloadConsidered: true),
                id: StanzaID.make())
            await friar.manager.resume()
            try await friar.waitOnline()
            try await eventually("outbox upload") {
                try friar.database.message(id: pendingRow.id!).map { $0.state != .pending } == true
            }
            try await eventually("outbox delivery") {
                try nurse.messages(with: friarJID).contains { $0.originID == pendingRow.originID }
            }

            // A policy that never downloads: offered, then fetched on request.
            await nurse.manager.setMediaPolicy(MediaPolicy(autoDownload: .never))
            let manual = try await friar.session.sendFile(try outgoing(friar, picture, name: "manual.png"), to: nurseJID)
            try await eventually("manual file arrives") {
                try nurse.messages(with: friarJID).first { $0.originID == manual.originID }?.attachment?
                    .autoDownloadConsidered == true
            }
            let offered = try #require(try nurse.messages(with: friarJID).first { $0.originID == manual.originID })
            #expect(offered.attachment?.localPath == nil)
            try await nurse.session.download(messageID: offered.id!)
            #expect(try nurse.database.message(id: offered.id!)?.attachment?.localPath != nil)
            await nurse.manager.setMediaPolicy(MediaPolicy())
        }
    }

    /// The share extension's path: rows stored while the app is not running,
    /// then a quiet one-shot login uploads and sends them.
    @Test(arguments: [LiveServer.prosody, LiveServer.ejabberd])
    func shareExtensionDelivery(_ server: LiveServer) async throws {
        let friar = try await Device("friar", on: server)
        let nurse = try await Device("nurse", on: server)
        try await closing([friar, nurse]) {
            try await befriend(friar, nurse)
            let nurseJID = nurse.account.jid
            await friar.manager.suspend()

            let file = try outgoing(friar, try png(width: 5, height: 5), name: "shared.png")
            let photo = try friar.database.insertOutgoing(
                accountID: friar.account.id, peer: nurseJID,
                attachment: Attachment(fileName: file.fileName, mimeType: file.mimeType, localPath: file.localPath,
                                       autoDownloadConsidered: true),
                id: StanzaID.make())
            let caption = try friar.database.insertOutgoing(accountID: friar.account.id, peer: nurseJID,
                                                            body: "From the garden", id: StanzaID.make())
            let credentials = InMemoryCredentialStore()
            try credentials.setPassword(devPassword, for: friar.account.id)
            let delivery = ShareDelivery(database: friar.database, credentials: credentials, media: friar.manager.media,
                                         lockDirectory: FileManager.default.temporaryDirectory
                                            .appending(path: "locks-\(UUID().uuidString)"),
                                         loopbackHTTP: true, omemo: try OMEMODatabase())
            let sent = await delivery.deliver(messageIDs: [photo.id!, caption.id!], accountID: friar.account.id)
            #expect(sent == 2)
            #expect(try friar.database.message(id: photo.id!)?.attachment?.url != nil)
            try await eventually("nurse has both") {
                let got = try nurse.messages(with: friar.account.jid)
                return got.contains { $0.originID == photo.originID && $0.attachment != nil }
                    && got.contains { $0.body == "From the garden" }
            }
            await friar.manager.resume()
        }
    }

    /// A self-hosted server's certificate, pinned by the user for the
    /// account, is trusted for its HTTP too — and nothing else is.
    @Test func pinnedCertificateCoversHTTP() async throws {
        let url = try #require(URL(string: "https://127.0.0.1:5281/"))
        let pinned = HTTPTransfer(pinnedFingerprint: try LiveServer.prosody.fingerprint)
        do {
            _ = try await pinned.contentLength(of: url)
        } catch let error as TransferError {
            // Any HTTP answer means TLS was accepted.
            #expect(error != .missingFile)
        }
        let other = HTTPTransfer(pinnedFingerprint: try LiveServer.ejabberd.fingerprint)
        await #expect(throws: URLError.self) { _ = try await other.contentLength(of: url) }
        let none = HTTPTransfer(pinnedFingerprint: nil)
        await #expect(throws: URLError.self) { _ = try await none.contentLength(of: url) }
    }

    /// Occupant avatars: the photo hash in room presence, fetched through
    /// the room and kept under the occupant JID; a removal clears it.
    @Test(arguments: [LiveServer.prosody, LiveServer.ejabberd])
    func occupantAvatars(_ server: LiveServer) async throws {
        let friar = try await Device("friar", on: server)
        let nurse = try await Device("nurse", on: server)
        try await closing([friar, nurse]) {
            let data = try Data(contentsOf: try png(width: 6, height: 6))
            let hash = Avatars.sha1(data)
            try await friar.session.setAvatar(data, type: "image/png", width: 6, height: 6)
            let key = try await friar.session.createRoom(name: "Cell \(UUID().uuidString.prefix(4))", kind: .channel)
            try await eventually("friar joined") { friar.status.room(key).isJoined }
            let occupant = "\(key)/\(try #require(friar.status.room(key).nick))"
            try await nurse.session.joinRoom(key)
            try await eventually("nurse joined") { nurse.status.room(key).isJoined }

            try await eventually("nurse sees friar's avatar in the room") {
                try nurse.database.profile(accountID: nurse.account.id, jid: occupant)?.avatarHash == hash
            }
            #expect(try Data(contentsOf: nurse.manager.media.avatarURL(hash: hash)) == data)

            try await friar.session.removeAvatar()
            try await eventually("avatar removed") {
                try nurse.database.profile(accountID: nurse.account.id, jid: occupant)?.avatarHash == nil
            }
            try await friar.session.destroyRoom(key)
        }
    }

    /// A file in a room: uploaded, reflected (delivered), received.
    @Test(arguments: [LiveServer.prosody, LiveServer.ejabberd])
    func fileInARoom(_ server: LiveServer) async throws {
        let friar = try await Device("friar", on: server)
        let nurse = try await Device("nurse", on: server)
        try await closing([friar, nurse]) {
            let key = try await friar.session.createRoom(name: "Cell \(UUID().uuidString.prefix(4))", kind: .channel)
            try await eventually("friar joined") { friar.status.room(key).isJoined }
            try await nurse.session.joinRoom(key)
            try await eventually("nurse joined") { nurse.status.room(key).isJoined }

            let sent = try await friar.session.sendFile(try outgoing(friar, try png(width: 4, height: 4), name: "map.png"),
                                                        to: key)
            try await eventually("reflection") { try friar.database.message(id: sent.id!)?.state == .delivered }
            try await eventually("nurse has it") {
                try nurse.messages(with: key).contains { $0.attachment?.fileName == "map.png" && $0.attachment?.localPath != nil }
            }
            try await friar.session.destroyRoom(key)
        }
    }

    /// Our avatar and nickname reach a contact, and are shown for us too.
    @Test(arguments: [LiveServer.prosody, LiveServer.ejabberd])
    func avatarsAndNicknames(_ server: LiveServer) async throws {
        let friar = try await Device("friar", on: server)
        let nurse = try await Device("nurse", on: server)
        try await closing([friar, nurse]) {
            try await befriend(friar, nurse)
            let friarJID = friar.account.jid
            let data = try Data(contentsOf: try png(width: 8, height: 8))
            let hash = Avatars.sha1(data)

            try await friar.session.setAvatar(data, type: "image/png", width: 8, height: 8)
            #expect(try friar.database.profile(accountID: friar.account.id, jid: friarJID)?.avatarHash == hash)
            #expect(friar.manager.media.hasAvatar(hash: hash))

            // By PEP notification (Prosody), or by the photo hash in the
            // presence that follows (ejabberd, which does not notify).
            try await eventually("nurse sees the avatar") {
                try nurse.database.profile(accountID: nurse.account.id, jid: friarJID)?.avatarHash == hash
            }
            #expect(nurse.manager.media.hasAvatar(hash: hash))
            #expect(try Data(contentsOf: nurse.manager.media.avatarURL(hash: hash)) == data)

            let nick = "Brother \(UUID().uuidString.prefix(4))"
            try await friar.session.setNickname(nick)
            try await withKnownIssue("ejabberd PEP notifications to contacts", isIntermittent: true) {
                try await eventually("nurse sees the nickname", timeout: .seconds(5)) {
                    try nurse.database.profile(accountID: nurse.account.id, jid: friarJID)?.nickname == nick
                }
            } when: { server.domain == LiveServer.ejabberd.domain }

            try await friar.session.removeAvatar()
            try await withKnownIssue("ejabberd PEP notifications to contacts", isIntermittent: true) {
                try await eventually("avatar removed", timeout: .seconds(5)) {
                    try nurse.database.profile(accountID: nurse.account.id, jid: friarJID)?.avatarHash == nil
                }
            } when: { server.domain == LiveServer.ejabberd.domain }
        }
    }
}
