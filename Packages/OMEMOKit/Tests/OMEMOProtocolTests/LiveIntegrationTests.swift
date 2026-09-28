import Foundation
import Testing
import OMEMOCrypto
@testable import OMEMOProtocol
import XMPPClient
import XMPPCore
import XMPPIM
import XMPPStream
import XMPPTestSupport
import XMPPTransport
import XMPPXML

/// OMEMO over the Docker servers: PEP publishing with open access, fetching
/// another account's list and bundle without a subscription, an encrypted
/// message through the server (and between servers), and device list
/// notifications. Off unless `HRAFN_INTEGRATION=1`.
@Suite(.enabled(if: integrationEnabled), .serialized, .timeLimit(.minutes(1)))
struct LiveIntegrationTests {

    static let pairs: [(TestServer, TestServer)] = [(.prosody, .prosody), (.ejabberd, .ejabberd), (.prosody, .ejabberd)]

    /// OMEMO 0.3, and OMEMO 2 with Bob's device out of the 0.3 list (as a
    /// device of an OMEMO 2-only client would be).
    @Test(arguments: 0..<pairs.count, OMEMOVersion.allCases)
    func encryptedMessage(_ index: Int, _ version: OMEMOVersion) async throws {
        let (aliceServer, bobServer) = Self.pairs[index]
        let alice = try JID("rosaline@\(aliceServer.domain)")
        let bob = try JID("balthasar@\(bobServer.domain)")
        let aliceClient = try await online(alice, on: aliceServer)
        let bobClient = try await online(bob, on: bobServer)
        defer { Task { await aliceClient.disconnect(); await bobClient.disconnect() } }

        // Start from empty lists: earlier runs leave devices behind.
        for list in OMEMOVersion.allCases {
            try await PEPDirectory(client: aliceClient).publishDeviceList([], version: list)
            try await PEPDirectory(client: bobClient).publishDeviceList([], version: list)
        }

        let aliceEngine = OMEMOEngine(account: alice, store: InMemoryOMEMOStore(),
                                      directory: PEPDirectory(client: aliceClient))
        let bobEngine = OMEMOEngine(account: bob, store: InMemoryOMEMOStore(),
                                    directory: PEPDirectory(client: bobClient))
        try await aliceEngine.setUp()
        try await bobEngine.setUp()

        // Readable by someone with no subscription (open access model).
        let bobID = await bobEngine.deviceID!
        #expect(try await PEPDirectory(client: aliceClient).deviceList(of: bob, version: version) == [bobID])
        let bundle = try await PEPDirectory(client: aliceClient).bundle(of: bob, deviceID: bobID, version: version)
        #expect(bundle.version == version)
        #expect(bundle.isSignatureValid)
        #expect(bundle.preKeys.count == LocalDevice.preKeyTarget)

        if version == .v2 { try await PEPDirectory(client: bobClient).publishDeviceList([], version: .legacy) }

        let token = UUID().uuidString
        let encrypted = try await aliceEngine.encrypt("secret \(token)", to: [bob])
        let arrival = Task {
            try await next(bobClient) { event -> Message? in
                guard case .message(let m) = event, let e = m.omemoEncrypted, e.senderDeviceID == encrypted.message.senderDeviceID
                else { return nil }
                return m
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(encrypted.message.elements.map(\.version) == [version])
        try await aliceClient.send(Message.omemo(encrypted.message, to: bob))
        let message = try await arrival.value
        #expect(message.body == Message.omemoFallbackBody)
        let decrypted = try await bobEngine.decrypt(try #require(message.omemoEncrypted), from: try #require(message.from),
                                                    conversations: [bob])
        #expect(decrypted.body == "secret \(token)")
        #expect(decrypted.version == version)

        // Bob's used pre-key left his published bundle, which is full again.
        let republished = try await PEPDirectory(client: aliceClient).bundle(of: bob, deviceID: bobID, version: version)
        #expect(republished.preKeys.count == LocalDevice.preKeyTarget)
        #expect(republished.preKeys.keys.sorted() != bundle.preKeys.keys.sorted())
    }

    /// Our other device appears: the server notifies us of our own list,
    /// in either version.
    @Test(arguments: [TestServer.prosody, TestServer.ejabberd], OMEMOVersion.allCases)
    func ownDeviceListNotification(_ server: TestServer, _ version: OMEMOVersion) async throws {
        let account = try JID("sampson@\(server.domain)")
        let phone = try await online(account, on: server)
        let laptop = try await online(account, on: server)
        defer { Task { await phone.disconnect(); await laptop.disconnect() } }
        for list in OMEMOVersion.allCases { try await PEPDirectory(client: phone).publishDeviceList([], version: list) }

        let phoneEngine = OMEMOEngine(account: account, store: InMemoryOMEMOStore(), directory: PEPDirectory(client: phone))
        try await phoneEngine.setUp()
        let phoneID = await phoneEngine.deviceID!

        let laptopEngine = OMEMOEngine(account: account, store: InMemoryOMEMOStore(), directory: PEPDirectory(client: laptop))
        let notified = Task {
            try await next(phone, timeout: .seconds(10)) { event -> [UInt32]? in
                guard case .message(let m) = event,
                      let change = PEPDirectory.deviceListChange(in: m, account: account), change.version == version,
                      // The server also sends the last list on coming
                      // online (possibly a previous run's): wait for ours.
                      change.jid == account, change.deviceIDs.count == 2,
                      change.deviceIDs.contains(phoneID) else { return nil }
                return change.deviceIDs
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        try await laptopEngine.setUp()
        let ids = try await notified.value
        let laptopID = await laptopEngine.deviceID!
        #expect(ids == [phoneID, laptopID], "notified \(ids), phone \(phoneID), laptop \(laptopID)")

        // OMEMO 2 keeps every device's bundle in one node: the laptop's
        // must not have replaced the phone's.
        if version == .v2 {
            for id in [phoneID, laptopID] {
                #expect(try await PEPDirectory(client: phone).bundle(of: account, deviceID: id, version: .v2).isSignatureValid)
            }
        }
    }

    /// Connected and available, advertising the device list `+notify`
    /// feature (XEP-0163 §4: notifications follow caps).
    private func online(_ jid: JID, on server: TestServer) async throws -> XMPPClient {
        let client = try client(jid, on: server)
        await client.addFeature(LegacyOMEMONodes.deviceListNotify)
        await client.addFeature(OMEMO2Nodes.devicesNotify)
        try await client.connect()
        try await client.send(Presence.available(caps: await client.capsElement))
        return client
    }

    private func client(_ jid: JID, on server: TestServer) throws -> XMPPClient {
        let configuration = SessionConfiguration(
            credentials: try Credentials(jid: jid, password: devPassword),
            tlsPolicy: try server.trustPolicy(),
            endpoints: [server.endpoint(.directTLS)],
            allowPlain: false)
        let client = XMPPClient(configuration: configuration,
                                identity: ClientIdentity(name: "Hrafn", node: "https://example.org/hrafn"),
                                resilience: .oneShot)
        return client
    }

    private func next<T: Sendable>(_ client: XMPPClient, timeout: Duration = .seconds(5),
                                   _ match: @escaping @Sendable (XMPPClient.Event) -> T?) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask {
                for await event in client.events { if let value = match(event) { return value } }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() ?? nil else { throw ClientError.timedOut }
            return value
        }
    }
}
