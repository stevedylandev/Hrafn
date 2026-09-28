import Testing
import Foundation
@testable import HrafnServices
import HrafnStore
import XMPPCore
import XMPPIM
import XMPPTestSupport
import XMPPXML

@Suite struct AccountLockTests {

    @Test func excludesASecondHolderUntilReleased() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "hrafn-locks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        // Two instances stand in for the app and the extension: flock is per
        // open file, so they exclude each other as two processes would.
        let app = AccountLock(directory: directory, accountID: "a")
        let nse = AccountLock(directory: directory, accountID: "a")
        let other = AccountLock(directory: directory, accountID: "b")

        #expect(app.tryAcquire())
        #expect(app.tryAcquire())   // idempotent for the holder
        #expect(!nse.tryAcquire())
        #expect(other.tryAcquire())
        #expect(await nse.acquire(timeout: .milliseconds(300), poll: .milliseconds(50)) == false)

        Task { try await Task.sleep(for: .milliseconds(100)); app.release() }
        #expect(await nse.acquire(timeout: .seconds(2), poll: .milliseconds(50)))
        #expect(!app.tryAcquire())
        nse.release()
        other.release()
    }
}

/// Records what the manager announces.
final class RecordingNotifier: Notifier, @unchecked Sendable {
    private let lock = NSLock()
    private var _announced: [PendingNotification] = []
    private var _badge: Int?
    private var _kept: Set<Int64>?
    var announced: [PendingNotification] { lock.withLock { _announced } }
    /// The unread messages the last withdrawal kept banners for.
    var kept: Set<Int64>? { lock.withLock { _kept } }
    var badge: Int? { lock.withLock { _badge } }
    func announce(_ notifications: [PendingNotification]) async { lock.withLock { _announced += notifications } }
    func withdraw(threadID: String) async {}
    func withdraw(keeping unread: Set<Int64>) async { lock.withLock { _kept = unread } }
    func setBadge(_ count: Int) async { lock.withLock { _badge = count } }
}

private let integrationEnabled = ProcessInfo.processInfo.environment["HRAFN_INTEGRATION"] == "1"

/// Phase 5 end to end, short of APNs: the app registers for push, goes to the
/// background, a message arrives, the server publishes to the app server
/// (`PushComponent` standing in for fpush), and the notification service
/// extension's `BackgroundFetch` fetches and announces it.
@MainActor
@Suite(.enabled(if: integrationEnabled), .serialized, .timeLimit(.minutes(2)))
struct PushPipelineTests {

    /// (account's server, app server's host); the mixed pair is federated.
    nonisolated static let topologies: [(LiveServer, TestServer)] = [
        (.prosody, .prosody), (.ejabberd, .ejabberd), (.ejabberd, .prosody),
    ]

    private func manager(_ user: String, on server: LiveServer, database: HrafnDatabase,
                         credentials: any CredentialStore, locks: URL?, notifier: (any Notifier)? = nil)
    async throws -> (AccountManager, Account) {
        let manager = AccountManager(database: database, credentials: credentials,
                                     console: ProcessInfo.processInfo.environment["HRAFN_XML"] == "1"
                                        ? RedactingXMLConsole(PrintXMLConsole()) : nil,
                                     lockDirectory: locks, notifier: notifier)
        return (manager, try await add(user, on: server, to: manager))
    }

    private func add(_ user: String, on server: LiveServer, to manager: AccountManager) async throws -> Account {
        let template = try server.account(user)
        let account = try await manager.addAccount(jid: template.jid, password: devPassword, host: template.host,
                                                   port: template.port, trustedFingerprint: template.trustedFingerprint)
        try await eventually("\(account.jid) online") { manager.status(for: account.id).connection == .online }
        try await Task.sleep(for: .milliseconds(500))
        return account
    }

    @Test(arguments: topologies)
    func backgroundMessageIsPushedFetchedAndAnnouncedOnce(_ server: LiveServer, _ pushHost: TestServer) async throws {
        let component = PushComponent(domain: pushHost.pushDomain, port: pushHost.componentPort)
        try await component.start()
        defer { component.stop() }

        let locks = FileManager.default.temporaryDirectory.appending(path: "hrafn-locks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: locks) }
        let database = try HrafnDatabase()
        let credentials = InMemoryCredentialStore()
        let notifier = RecordingNotifier()
        let token = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let node = token.map { String(format: "%02x", $0) }.joined()

        let (app, tybalt) = try await manager("tybalt", on: server, database: database, credentials: credentials,
                                              locks: locks, notifier: notifier)
        await app.setPushSettings(PushSettings(service: try JID(pushHost.pushDomain),
                                               publishOptions: ["pushModule": "test"]))
        await app.setPushToken(token)
        try await eventually("push enabled") { app.status(for: tybalt.id).push == .enabled }

        let (sender, paris) = try await manager("paris", on: server, database: try HrafnDatabase(),
                                                credentials: InMemoryCredentialStore(), locks: nil)
        let parisSession = try #require(sender.session(for: paris.id))

        // The app goes to the background and logs out.
        await app.setActive(false)
        await app.suspend()
        #expect(app.session(for: tybalt.id) == nil)

        let body = "while you slept \(UUID().uuidString.prefix(6))"
        try await parisSession.send(body, to: tybalt.jid)
        let published = try await component.next { stanza in
            IQ(stanza).flatMap(PushNotification.init)?.node == node
        }
        let notification = try #require(IQ(published).flatMap(PushNotification.init))
        #expect(notification.publishOptions["pushModule"] == "test")

        // The extension's turn.
        let fetch = BackgroundFetch(database: database, credentials: credentials, lockDirectory: locks)
        let outcome = await fetch.run()
        #expect(outcome.failures.isEmpty)
        #expect(outcome.busy.isEmpty)
        #expect(outcome.notifications.map(\.message.body) == [body])
        #expect(outcome.notifications.first?.peer == paris.jid)
        #expect(outcome.badge >= 1)
        // Announced once: neither a second push nor the app announces it again.
        #expect(await fetch.run().notifications.isEmpty)

        // Muted: fetched, but not shown.
        try app.setMuted(accountID: tybalt.id, peer: paris.jid, true)
        try await parisSession.send("muted \(body)", to: tybalt.jid)
        try await eventually("second push") {
            component.stanzas.filter { IQ($0).flatMap(PushNotification.init)?.node == node }.count >= 2
        }
        let muted = await fetch.run()
        #expect(muted.notifications.isEmpty)
        #expect(try database.unreadTotal() >= 2)
        try app.setMuted(accountID: tybalt.id, peer: paris.jid, false)

        // Back in the foreground: the app holds the lock, and the extension
        // stands aside rather than log in beside it.
        await app.resume()
        try await eventually("tybalt online again") { app.status(for: tybalt.id).connection == .online }
        let busy = await fetch.run(lockWait: .milliseconds(300))
        #expect(busy.busy == [tybalt.id])

        // Messages arriving while the app is backgrounded but still connected
        // are announced by the app itself; in the foreground, silently.
        await app.setActive(true)
        try await parisSession.send("foreground \(body)", to: tybalt.jid)
        try await eventually("foreground message stored") {
            try database.writer.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message WHERE body = ? AND notified",
                                 arguments: ["foreground \(body)"]) == 1
            }
        }
        await app.setActive(false)
        let background = try await parisSession.send("background \(body)", to: tybalt.jid)
        try await eventually("background message announced") {
            notifier.announced.contains { $0.message.body == "background \(body)" }
        }
        // Retracted by its sender: its banner comes down.
        let announcedID = try #require(notifier.announced.first { $0.message.body == "background \(body)" }?.id)
        #expect(notifier.kept?.contains(announcedID) == true)
        try await parisSession.retract(messageID: background.id!)
        try await eventually("banner withdrawn") { notifier.kept?.contains(announcedID) == false }
        #expect(!notifier.announced.contains { $0.message.body == "foreground \(body)" })
        #expect(!notifier.announced.contains { $0.message.body == body })
        #expect(notifier.badge != nil)

        await app.removeAccount(tybalt.id)
        await sender.stopAll()
    }
}
