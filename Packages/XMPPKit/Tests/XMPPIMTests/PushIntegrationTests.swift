import Testing
import Foundation
import XMPPClient
import XMPPIM
import XMPPStream
import XMPPTransport
import XMPPTestSupport
import XMPPCore
import XMPPXML

/// XEP-0357 against the live servers, with `PushComponent` standing in for the
/// app server. Off unless `HRAFN_INTEGRATION=1`; see `TestServers.swift`.
///
/// Uses its own users (`tybalt`, `paris`): the account being pushed to must
/// have no session, which no other suite could promise for a shared user.
@Suite(.enabled(if: integrationEnabled), .serialized, .timeLimit(.minutes(1)))
struct PushIntegrationTests {

    private func client(_ user: String, on server: TestServer) throws -> XMPPClient {
        let configuration = SessionConfiguration(
            credentials: try Credentials(jid: try JID("\(user)@\(server.domain)"), password: devPassword),
            tlsPolicy: try server.trustPolicy(),
            endpoints: [server.endpoint(.directTLS)],
            allowPlain: false,
            console: ProcessInfo.processInfo.environment["HRAFN_XML"] == "1"
                ? RedactingXMLConsole(PrintXMLConsole()) : nil)
        return XMPPClient(configuration: configuration, identity: identity, resilience: .oneShot)
    }

    /// (account's server, app server's host). The mixed pairs are the real
    /// topology: the app server lives on Hrafn's domain, and any federated
    /// server publishes to it over s2s.
    static let topologies: [(TestServer, TestServer)] = [
        (.prosody, .prosody), (.ejabberd, .ejabberd), (.ejabberd, .prosody), (.prosody, .ejabberd),
    ]

    @Test(arguments: topologies)
    func offlineMessageIsPushedUntilDisabled(_ server: TestServer, _ pushHost: TestServer) async throws {
        let component = PushComponent(domain: pushHost.pushDomain, port: pushHost.componentPort)
        try await component.start()
        defer { component.stop() }
        let service = try JID(pushHost.pushDomain)
        let node = "node-\(UUID().uuidString.prefix(8).lowercased())"
        let secret = UUID().uuidString

        let tybalt = try client("tybalt", on: server)
        try await tybalt.connect()
        let push = PushNotifications(client: tybalt)
        #expect(try await push.isSupported())
        try await push.enable(service: service, node: node, publishOptions: ["secret": secret])
        await tybalt.disconnect()

        let paris = try client("paris", on: server)
        try await paris.connect()
        let to = try JID("tybalt@\(server.domain)")
        try await paris.send(Message.chat(to: to, body: "push me \(node)", id: StanzaID.make()))

        let published = try await component.next { stanza in
            guard let iq = IQ(stanza) else { return false }
            return PushNotification(iq)?.node == node
        }
        let iq = try #require(IQ(published))
        let notification = try #require(PushNotification(iq))
        // The publish comes from the account (or its server), and carries back
        // the options we registered: that is how an app server authenticates it.
        #expect(published["from"].map { $0.hasSuffix(server.domain) } == true)
        #expect(notification.publishOptions["secret"] == secret)
        if let count = notification.messageCount { #expect(count >= 1) }

        // Disabled: the next message is not pushed.
        try await tybalt.connect()
        try await push.disable(service: service, node: node)
        await tybalt.disconnect()
        let before = component.stanzas.count
        try await paris.send(Message.chat(to: to, body: "quiet \(node)", id: StanzaID.make()))
        try await Task.sleep(for: .seconds(2))
        let after = component.stanzas.dropFirst(before).compactMap { IQ($0).flatMap(PushNotification.init) }
        #expect(!after.contains { $0.node == node })
        await paris.disconnect()
    }
}
