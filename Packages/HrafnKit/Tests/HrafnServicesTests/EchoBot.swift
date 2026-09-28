import Testing
import Foundation
import GRDB
@testable import HrafnServices
import HrafnStore

/// Romeo for the app's UI test: accepts contact requests and echoes every
/// message for a while. Run it while `HrafnUITests` drives the simulator:
///
/// ```sh
/// HRAFN_ECHO_BOT=1 swift test --package-path Packages/HrafnKit --filter EchoBot
/// ```
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HRAFN_ECHO_BOT"] == "1"))
@MainActor
struct EchoBot {
    @Test(.timeLimit(.minutes(10))) func echo() async throws {
        let database = try HrafnDatabase()
        let manager = AccountManager(database: database, credentials: InMemoryCredentialStore())
        let template = try LiveServer.prosody.account("romeo")
        let account = try await manager.addAccount(
            jid: template.jid, password: ProcessInfo.processInfo.environment["HRAFN_DEV_PASSWORD"] ?? "devpassword",
            host: template.host, port: template.port, trustedFingerprint: template.trustedFingerprint)
        let session = try #require(manager.session(for: account.id))
        let seconds = Double(ProcessInfo.processInfo.environment["HRAFN_ECHO_SECONDS"] ?? "") ?? 120
        precondition(seconds < 540, "HRAFN_ECHO_SECONDS must stay under the test's time limit")
        let deadline = Date().addingTimeInterval(seconds)
        var answered = Set<Int64>()
        print("echo bot online as \(template.jid) for \(Int(seconds))s")
        while Date() < deadline {
            for contact in try database.fetchContacts(accountID: account.id) where contact.pendingIn {
                print("accepting \(contact.jid)")
                try? await session.answerSubscription(from: contact.jid, approve: true)
            }
            let incoming = try unread(in: database, accountID: account.id)
            for message in incoming where !answered.contains(message.id!) {
                answered.insert(message.id!)
                await session.markRead(peer: message.peer)
                print("echoing to \(message.peer): \(message.body)")
                _ = try? await session.send("echo: \(message.body)", to: message.peer)
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        await manager.stopAll()
    }
}

private func unread(in database: HrafnDatabase, accountID: String) throws -> [StoredMessage] {
    try database.writer.read { db in
        try StoredMessage.filter(Column("accountID") == accountID && !Column("isOutgoing")
                                 && Column("state") == MessageState.received.rawValue).fetchAll(db)
    }
}
