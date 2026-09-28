import Testing
import Foundation
@testable import XMPPTransport
import XMPPCore

@Suite struct SRVRecordParsingTests {

    /// priority 10, weight 5, port 5222, target "xmpp.example.com"
    private let wireFormat: [UInt8] = [
        0x00, 0x0A, 0x00, 0x05, 0x14, 0x66,
        0x04, 0x78, 0x6D, 0x70, 0x70,                                  // "xmpp"
        0x07, 0x65, 0x78, 0x61, 0x6D, 0x70, 0x6C, 0x65,                // "example"
        0x03, 0x63, 0x6F, 0x6D,                                        // "com"
        0x00,
    ]

    @Test func parsesWireFormat() throws {
        let record = try #require(RecordCollectorTestHook.parse(wireFormat))
        #expect(record.priority == 10)
        #expect(record.weight == 5)
        #expect(record.port == 5222)
        #expect(record.target == "xmpp.example.com")
    }

    @Test func recognizesRootTargetAsServiceUnavailable() throws {
        let bytes: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let record = try #require(RecordCollectorTestHook.parse(bytes))
        #expect(record.isServiceDecidedlyUnavailable)
    }

    @Test func rejectsTruncatedRecord() {
        #expect(RecordCollectorTestHook.parse([0x00, 0x0A, 0x00]) == nil)
    }

    @Test func rejectsCompressionPointerInTarget() {
        // 0xC0 0x0C is a name-compression pointer, illegal in SRV RDATA.
        let bytes: [UInt8] = [0x00, 0x0A, 0x00, 0x05, 0x14, 0x66, 0xC0, 0x0C]
        #expect(RecordCollectorTestHook.parse(bytes) == nil)
    }

    @Test func rejectsLabelRunningPastTheBuffer() {
        let bytes: [UInt8] = [0x00, 0x0A, 0x00, 0x05, 0x14, 0x66, 0x3F, 0x61]
        #expect(RecordCollectorTestHook.parse(bytes) == nil)
    }
}

@Suite struct SRVOrderingTests {

    @Test func sortsByAscendingPriority() {
        let records = [
            SRVRecord(priority: 20, weight: 0, port: 5222, target: "c"),
            SRVRecord(priority: 5, weight: 0, port: 5222, target: "a"),
            SRVRecord(priority: 10, weight: 0, port: 5222, target: "b"),
        ]
        #expect(SRVResolver.ordered(records).map(\.target) == ["a", "b", "c"])
    }

    @Test func distributesWithinAPriorityAccordingToWeight() {
        let records = [
            SRVRecord(priority: 10, weight: 99, port: 5222, target: "heavy"),
            SRVRecord(priority: 10, weight: 1, port: 5222, target: "light"),
        ]
        var generator = SystemRandomNumberGenerator()
        var heavyFirst = 0
        for _ in 0..<400 {
            if SRVResolver.ordered(records, using: &generator).first?.target == "heavy" { heavyFirst += 1 }
        }
        // Heavily biased but never exclusive; both must remain reachable.
        #expect(heavyFirst > 300)
        #expect(heavyFirst < 400)
    }

    @Test func keepsEveryRecordExactlyOnce() {
        let records = (0..<10).map {
            SRVRecord(priority: UInt16($0 % 3), weight: UInt16($0), port: 5222, target: "t\($0)")
        }
        let ordered = SRVResolver.ordered(records)
        #expect(Set(ordered) == Set(records))
        #expect(ordered.count == records.count)
    }
}

@Suite struct EndpointResolverTests {

    private func resolver(_ answers: [String: [SRVRecord]]) -> EndpointResolver {
        EndpointResolver { name in
            guard let records = answers[name] else { throw DNSError(kind: .noRecords, query: name) }
            return records
        }
    }

    @Test func prefersDirectTLSOverStartTLS() async throws {
        let resolver = resolver([
            "_xmpps-client._tcp.example.com": [
                SRVRecord(priority: 10, weight: 0, port: 5223, target: "tls.example.com")],
            "_xmpp-client._tcp.example.com": [
                SRVRecord(priority: 10, weight: 0, port: 5222, target: "plain.example.com")],
        ])
        let endpoints = try await resolver.endpoints(for: try JID("example.com"))
        #expect(endpoints.map(\.security) == [.directTLS, .startTLS])
        #expect(endpoints[0].host == "tls.example.com")
        #expect(endpoints[0].port == 5223)
        // Certificates are checked against the domain, never the SRV target.
        #expect(endpoints.allSatisfy { $0.domain == "example.com" })
    }

    @Test func fallsBackToTheDomainWhenNoSRVRecordsExist() async throws {
        let endpoints = try await resolver([:]).endpoints(for: try JID("example.com"))
        #expect(endpoints.map(\.host) == ["example.com", "example.com"])
        #expect(endpoints.map(\.port) == [5222, 5223])
        #expect(endpoints.map(\.security) == [.startTLS, .directTLS])
    }

    @Test func honoursExplicitRefusalOfBothServices() async throws {
        let refused = [SRVRecord(priority: 0, weight: 0, port: 0, target: ".")]
        let endpoints = try await resolver([
            "_xmpps-client._tcp.example.com": refused,
            "_xmpp-client._tcp.example.com": refused,
        ]).endpoints(for: try JID("example.com"))
        #expect(endpoints.isEmpty)
    }

    @Test func skipsSRVForIPLiterals() async throws {
        let v4 = try await resolver([:]).endpoints(forDomain: "127.0.0.1")
        #expect(v4.map(\.host) == ["127.0.0.1", "127.0.0.1"])
        let v6 = try await resolver([:]).endpoints(forDomain: "[::1]")
        #expect(v6.allSatisfy { $0.host == "[::1]" })
    }

    @Test func queriesALabelsButValidatesAgainstTheUnicodeDomain() async throws {
        let resolver = resolver([
            "_xmpps-client._tcp.xn--mnchen-3ya.example": [
                SRVRecord(priority: 0, weight: 0, port: 5223, target: "tls.example")],
        ])
        let endpoints = try await resolver.endpoints(for: try JID("münchen.example"))
        #expect(endpoints.first?.host == "tls.example")
        #expect(endpoints.first?.domain == "münchen.example")
    }
}
