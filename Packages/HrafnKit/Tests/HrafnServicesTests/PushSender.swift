import Testing
import Foundation
@testable import HrafnServices
import HrafnStore
import XMPPCore
import XMPPIM
import XMPPTestSupport

/// Paris and the push app server for the app's push UI test
/// (`HrafnPushUITests`). Connects as `push.alpha.test` in place of fpush, waits
/// for the app (as tybalt) to sign in and then to log out in the background,
/// sends a message, and — when Prosody publishes the notification to the
/// app's APNs device token — does what fpush would: delivers fpush's
/// content-free push, here with `simctl push`.
///
/// ```sh
/// HRAFN_PUSH_SENDER=1 swift test --package-path Packages/HrafnKit --filter PushSender &
/// TEST_RUNNER_HRAFN_INTEGRATION=1 xcodebuild test -project Hrafn.xcodeproj -scheme Hrafn \
///   -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:HrafnUITests/HrafnPushUITests
/// ```
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HRAFN_PUSH_SENDER"] == "1"))
@MainActor
struct PushSender {

    @Test(.timeLimit(.minutes(10))) func sendWhileSuspended() async throws {
        let component = PushComponent(domain: TestServer.prosody.pushDomain, port: TestServer.prosody.componentPort)
        try await component.start()
        defer { component.stop() }
        let manager = AccountManager(database: try HrafnDatabase(), credentials: InMemoryCredentialStore())
        let template = try LiveServer.prosody.account("paris")
        let account = try await manager.addAccount(
            jid: template.jid, password: ProcessInfo.processInfo.environment["HRAFN_DEV_PASSWORD"] ?? "devpassword",
            host: template.host, port: template.port, trustedFingerprint: template.trustedFingerprint)
        let session = try #require(manager.session(for: account.id))
        let target = "tybalt@alpha.test"

        print("push sender: waiting for \(target) to sign in")
        try await waitUntil(minutes: 8) { try sessions().contains(target) }
        print("push sender: waiting for \(target) to log out in the background")
        try await waitUntil(minutes: 3) { try !sessions().contains(target) }

        let body = ProcessInfo.processInfo.environment["HRAFN_PUSH_BODY"] ?? "ping from paris"
        _ = try await session.send(body, to: target)
        // The app registered its APNs token as the node: 32 bytes of hex.
        let published = try await component.next(timeout: .seconds(30)) { stanza in
            guard let node = IQ(stanza).flatMap(PushNotification.init)?.node else { return false }
            return node.count == 64 && node.allSatisfy(\.isHexDigit)
        }
        let notification = try #require(IQ(published).flatMap(PushNotification.init))
        print("push sender: server published to device token \(notification.node.prefix(12))…, "
              + "options \(notification.publishOptions)")
        // What fpush sends (fpush-apns push.rs): a fixed alert, mutable-content.
        let payload = FileManager.default.temporaryDirectory.appending(path: "hrafn-push-\(UUID().uuidString).apns")
        try Data("""
            {"Simulator Target Bundle": "com.stevedylandev.Hrafn",
             "aps": {"alert": {"title": "New Message", "body": "New Message?"}, "mutable-content": 1, "sound": "default"}}
            """.utf8).write(to: payload)
        let output = try run("/usr/bin/xcrun", ["simctl", "push", "booted", "com.stevedylandev.Hrafn", payload.path])
        print("push sender: sent \"\(body)\" and pushed: \(output)")
        try await Task.sleep(for: .seconds(60))
        await manager.stopAll()
    }

    private func sessions() throws -> String {
        try run("/usr/local/bin/docker", ["exec", "hrafn-prosody", "prosodyctl", "shell", "c2s:show('alpha.test')"])
    }

    private func waitUntil(minutes: Double, _ condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(minutes * 60)
        while Date() < deadline {
            if try condition() { return }
            try await Task.sleep(for: .seconds(1))
        }
        Issue.record("timed out")
        throw AccountError.notConnected
    }

    private func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
