import Foundation
import OMEMOProtocol
import HrafnStore
import XMPPClient
import XMPPCore
import XMPPIM
import XMPPStream
import XMPPXML

/// What the share extension does after storing what the user shared as
/// outgoing messages: log in quietly, upload the files, send the messages,
/// log out. Whatever it cannot send (no connection, the app holds the
/// account's lock, a room that needs joining) stays in the outbox, and the
/// app sends it on its next session.
///
/// Encryption is decided as the app decides it (`AccountSession.encrypts`).
/// Without OMEMO storage, only conversations with encryption turned off are
/// sent from here: the rest wait for the app rather than go in the clear.
public struct ShareDelivery: Sendable {

    public let database: HrafnDatabase
    public let credentials: any CredentialStore
    public let media: MediaStore
    public let lockDirectory: URL
    public var loopbackHTTP: Bool
    public var console: (any XMLConsole)?
    public var omemo: OMEMODatabase?

    public init(database: HrafnDatabase, credentials: any CredentialStore, media: MediaStore, lockDirectory: URL,
                loopbackHTTP: Bool = false, console: (any XMLConsole)? = nil, omemo: OMEMODatabase? = nil) {
        self.omemo = omemo
        self.database = database
        self.credentials = credentials
        self.media = media
        self.lockDirectory = lockDirectory
        self.loopbackHTTP = loopbackHTTP
        self.console = console
    }

    /// Sends `messageIDs` (pending, one-to-one, all of `accountID`) within
    /// `timeout`. Returns how many went out.
    @discardableResult
    public func deliver(messageIDs: [Int64], accountID: String, timeout: Duration = .seconds(20),
                        lockWait: Duration = .seconds(2)) async -> Int {
        guard let account = try? database.account(id: accountID), account.enabled else { return 0 }
        let lock = AccountLock(directory: lockDirectory, accountID: account.id)
        guard await lock.acquire(timeout: lockWait) else { return 0 }
        defer { lock.release() }

        let rejected = RejectedCertificate()
        guard let jid = try? JID(account.jid), jid.localpart != nil,
              let password = try? credentials.password(for: account.id),
              let configuration = try? AccountSession.configuration(for: account, jid: jid, password: password,
                                                                    credentials: credentials, recording: rejected,
                                                                    console: console) else { return 0 }
        let client = XMPPClient(configuration: configuration, identity: hrafnIdentity, resilience: .oneShot)
        let uploader = FileUploader(client: client, transfer: HTTPTransfer(pinnedFingerprint: account.trustedFingerprint,
                                                                           loopback: loopbackHTTP),
                                    database: database, media: media)
        let database = self.database
        let omemo = self.omemo.map {
            OMEMOEngine(account: jid, store: DatabaseOMEMOStore(accountID: account.id, database: $0,
                                                                credentials: credentials),
                        directory: PEPDirectory(client: client))
        }

        let sent = await withTaskGroup(of: Int?.self) { group in
            group.addTask {
                guard (try? await client.connect()) != nil else { return 0 }
                var service: HTTPUpload.Service?
                var count = 0
                for id in messageIDs {
                    guard let row = try? database.message(id: id), row.state == .pending,
                          (try? database.isRoom(accountID: account.id, jid: row.peer)) != true,
                          let to = try? JID(row.peer), to.isBare, let originID = row.originID else { continue }
                    guard let encrypted = await Self.encrypts(to: to, accountID: account.id, database: database,
                                                              omemo: omemo) else { continue }
                    var message: Message
                    if var attachment = row.attachment {
                        if attachment.url != nil, (attachment.encryptionKey != nil) != encrypted {
                            attachment.url = nil
                        }
                        if attachment.needsUpload {
                            do {
                                let (url, found) = try await uploader.upload(attachment, messageID: id, service: service,
                                                                             encrypted: encrypted)
                                service = found
                                attachment.url = url
                                attachment.encryptionKey = try? database.message(id: id)?.attachment?.encryptionKey
                            } catch {
                                FileUploader.recordFailure(error, messageID: id, database: database)
                                continue
                            }
                        }
                        guard let url = attachment.url else { continue }
                        if encrypted {
                            guard let fragment = attachment.encryptionKey,
                                  let link = FileEncryption.link(for: url, fragment: fragment) else { continue }
                            message = .chat(to: to, body: link, id: originID)
                        } else {
                            message = .file(to: to, url: url, id: originID)
                        }
                    } else {
                        message = .chat(to: to, body: row.body, id: originID).replying(to: row.reply)
                    }
                    if encrypted {
                        guard let omemo, let body = message.body else { continue }
                        do {
                            message = message.encrypted(with: try await omemo.encrypt(body, to: [to]).message)
                        } catch let error as OMEMOProtocolError {
                            switch error {
                            case .noDevices, .noTrustedDevices:
                                try? database.setState(messageID: id, .failed,
                                                       errorText: AccountSession.describe(error))
                            default:
                                break
                            }
                            continue
                        } catch {
                            continue
                        }
                    }
                    guard (try? await client.send(message)) != nil else { break }
                    try? database.markSent(messageID: id)
                    if encrypted { try? database.setEncryption(messageID: id, .omemo) }
                    count += 1
                }
                return count
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? 0
        }
        // Flushes the writer and waits for the server's final ack.
        await client.disconnect()
        return sent
    }

    /// Whether a message to `peer` goes encrypted; `nil` when that cannot be
    /// settled here (no OMEMO storage, or the device list is out of reach),
    /// so the message is left for the app.
    static func encrypts(to peer: JID, accountID: String, database: HrafnDatabase,
                         omemo: OMEMOEngine?) async -> Bool? {
        switch try? database.conversationEncryption(accountID: accountID, peer: peer.description) {
        case .off: return false
        case .omemo: return omemo == nil ? nil : true
        case nil:
            guard let omemo, let devices = try? await omemo.deviceIDs(of: peer) else { return nil }
            return !devices.isEmpty
        }
    }
}
