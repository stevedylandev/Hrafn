import Foundation
import Observation
import XMPPCore
import XMPPTransport
import XMPPXML

/// Opens a stream against a server and records the exchange, so the transport
/// and framing layers can be exercised from the device before there is any chat
/// UI. Debug builds only.
@MainActor
@Observable
final class StreamProbe {

    struct LogLine: Identifiable, Sendable {
        let id = UUID()
        let direction: XMLDirection
        let xml: String
    }

    enum Status: Sendable, Equatable {
        case idle
        case resolving
        case connecting(String)
        case negotiating
        case ready(mechanisms: [String])
        case failed(String)

        var label: String {
            switch self {
            case .idle: "Idle"
            case .resolving: "Resolving SRV records…"
            case .connecting(let endpoint): "Connecting to \(endpoint)…"
            case .negotiating: "Negotiating TLS…"
            case .ready(let mechanisms): "Stream ready · \(mechanisms.joined(separator: ", "))"
            case .failed(let reason): "Failed: \(reason)"
            }
        }
    }

    var domain = "alpha.test"
    /// Overrides DNS. The test servers are reachable on localhost, and their
    /// certificates are issued for the domain rather than the address.
    var hostOverride = "127.0.0.1"
    var portOverride = "5223"
    var useDirectTLS = true
    /// Debug builds only: the Docker servers use a private CA.
    var acceptAnyCertificate = true

    private(set) var status: Status = .idle
    private(set) var log: [LogLine] = []
    private(set) var endpoints: [String] = []

    private var task: Task<Void, Never>?

    func connect() {
        task?.cancel()
        log.removeAll()
        let console = Console(probe: self)
        let domain = domain
        let hostOverride = hostOverride.trimmingCharacters(in: .whitespaces)
        let portOverride = UInt16(portOverride) ?? 5222
        let security: TransportSecurity = useDirectTLS ? .directTLS : .startTLS
        let policy: TLSPolicy = acceptAnyCertificate ? .insecureAcceptAll : .standard()

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let jid = try JID(domain)
                let endpoint: Endpoint
                if hostOverride.isEmpty {
                    status = .resolving
                    let resolved = try await EndpointResolver().endpoints(for: jid)
                    self.endpoints = resolved.map(\.description)
                    guard let first = resolved.first(where: { $0.security == security }) ?? resolved.first
                    else { throw XMLStream.Failure.notOpen }
                    endpoint = first
                } else {
                    endpoint = Endpoint(host: hostOverride, port: portOverride,
                                        security: security, domain: jid.domainpart)
                    self.endpoints = [endpoint.description]
                }

                status = .connecting(endpoint.description)
                let stream = XMLStream(endpoint: endpoint, domain: jid, policy: policy,
                                       console: RedactingXMLConsole(console))
                try await stream.open()
                var features = try await stream.awaitFeatures()

                if !(await stream.isEncrypted) {
                    status = .negotiating
                    if let secured = try await stream.negotiateTLS(features: features) {
                        features = secured
                    }
                }

                let mechanisms = features
                    .firstChild(name: "mechanisms", namespaceURI: Namespaces.sasl)?
                    .childElements(name: "mechanism").map(\.text) ?? []
                status = .ready(mechanisms: mechanisms)
                await stream.close()
            } catch is CancellationError {
                status = .idle
            } catch {
                status = .failed(String(describing: error))
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        status = .idle
    }

    fileprivate func append(_ direction: XMLDirection, _ xml: String) {
        log.append(LogLine(direction: direction, xml: xml))
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    /// Bridges the console protocol onto the main actor. `StreamProbe` is
    /// `@MainActor`-isolated and therefore already `Sendable`.
    fileprivate struct Console: XMLConsole {
        let probe: StreamProbe

        func log(_ direction: XMLDirection, _ xml: String) {
            let probe = probe
            Task { @MainActor in probe.append(direction, xml) }
        }
    }
}
