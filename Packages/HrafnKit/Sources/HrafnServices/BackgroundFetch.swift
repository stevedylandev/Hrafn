import Foundation
import OMEMOProtocol
import HrafnStore
import XMPPClient
import XMPPCore
import XMPPIM
import XMPPStream
import XMPPTransport
import XMPPXML

/// What the notification service extension does with a push (PLAN.md Phase 5):
/// for each account, take its lock, log in, read the archive since the last
/// cursor, store it, log out — then announce what is new.
///
/// The session is deliberately quiet: no presence (so the server does not
/// hand over offline storage or route live messages here), no carbons, no
/// receipts. The app catches up on its next session as usual; deduplication
/// makes the overlap harmless.
public struct BackgroundFetch: Sendable {

    public struct Outcome: Sendable {
        /// New messages to show, oldest first. Muted conversations' messages
        /// are claimed but left out.
        public var notifications: [PendingNotification]
        /// Unread across every account, for the badge.
        public var badge: Int
        /// Accounts skipped because the app held their lock (it is running
        /// and handles its own messages).
        public var busy: [String]
        /// Accounts that failed, and why.
        public var failures: [String: String]
    }

    public let database: HrafnDatabase
    public let credentials: any CredentialStore
    public let lockDirectory: URL
    public var console: (any XMLConsole)?
    /// OMEMO state, to decrypt what the archive holds for this device. The
    /// extension only decrypts (and republishes its bundle when a pre-key
    /// was used); it answers no one, which the app does next time.
    public var omemo: OMEMODatabase?

    public init(database: HrafnDatabase, credentials: any CredentialStore, lockDirectory: URL,
                console: (any XMLConsole)? = nil, omemo: OMEMODatabase? = nil) {
        self.database = database
        self.credentials = credentials
        self.lockDirectory = lockDirectory
        self.console = console
        self.omemo = omemo
    }

    /// Fetches every enabled account in parallel. Each account gets `timeout`
    /// from start to logout; the extension has about 30 seconds in all.
    public func run(timeout: Duration = .seconds(20), lockWait: Duration = .seconds(3)) async -> Outcome {
        let accounts = ((try? database.allAccounts()) ?? []).filter(\.enabled)
        var busy: [String] = []
        var failures: [String: String] = [:]
        await withTaskGroup(of: (String, Result<Bool, AccountError>).self) { group in
            for account in accounts {
                group.addTask {
                    (account.id, await self.fetch(account, timeout: timeout, lockWait: lockWait))
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(true): break
                case .success(false): busy.append(id)
                case .failure(let error): failures[id] = error.description
                }
            }
        }
        let claimed = (try? database.claimPendingNotifications()) ?? []
        return Outcome(notifications: claimed.filter { !$0.muted }, badge: (try? database.unreadTotal()) ?? 0,
                       busy: busy, failures: failures)
    }

    /// `false` when the lock was busy.
    func fetch(_ account: Account, timeout: Duration, lockWait: Duration) async -> Result<Bool, AccountError> {
        let lock = AccountLock(directory: lockDirectory, accountID: account.id)
        guard await lock.acquire(timeout: lockWait) else { return .success(false) }
        defer { lock.release() }

        let rejected = RejectedCertificate()
        let client: XMPPClient
        do {
            guard let jid = try? JID(account.jid), jid.localpart != nil else { throw AccountError.invalidJID(account.jid) }
            guard let password = try credentials.password(for: account.id) else { throw AccountError.missingPassword }
            let configuration = try AccountSession.configuration(for: account, jid: jid, password: password,
                                                                 credentials: credentials, recording: rejected,
                                                                 console: console)
            client = XMPPClient(configuration: configuration, identity: hrafnIdentity, resilience: .oneShot)
        } catch {
            return .failure(AccountSession.describe(error, rejected: nil))
        }

        let result = await withTaskGroup(of: Result<Bool, AccountError>?.self) { group in
            group.addTask {
                do {
                    let archive = await MessageArchive(client: client)
                    try await client.connect()
                    guard let bound = await client.jid else { throw AccountError.notConnected }
                    // Under the account's lock: the app is not using these
                    // ratchets now.
                    let engine = omemo.map {
                        OMEMOEngine(account: bound, store: DatabaseOMEMOStore(accountID: account.id, database: $0,
                                                                              credentials: credentials),
                                    directory: PEPDirectory(client: client))
                    }
                    let inbound = InboundStore(database: database, accountID: account.id, omemo: engine)
                    _ = try await AccountSession.catchUp(archive: archive, inbound: inbound,
                                                         archiveKey: bound.bare.description)
                    return .success(true)
                } catch {
                    return .failure(AccountSession.describe(error, rejected: rejected.value))
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .failure(.connectionFailed("timed out"))
        }
        await client.disconnect()
        return result
    }
}
