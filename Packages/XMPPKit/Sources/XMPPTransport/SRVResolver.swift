import Foundation
import dnssd

/// One `_service._proto.name` SRV record (RFC 2782).
public struct SRVRecord: Sendable, Hashable {
    public let priority: UInt16
    public let weight: UInt16
    public let port: UInt16
    /// Target host as an A-label name, without the trailing dot.
    public let target: String

    public init(priority: UInt16, weight: UInt16, port: UInt16, target: String) {
        self.priority = priority
        self.weight = weight
        self.port = port
        self.target = target
    }

    /// RFC 2782: a single record with target "." means the service is
    /// explicitly not offered at this domain.
    public var isServiceDecidedlyUnavailable: Bool { target == "." || target.isEmpty }
}

public struct DNSError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        case noRecords
        case timedOut
        case malformedRecord
        case serviceError(Int32)
    }
    public let kind: Kind
    public let query: String

    public var description: String { "DNS \(kind) for \(query)" }
}

/// SRV lookups over `dns_sd`.
///
/// Network.framework resolves names but exposes no SRV API, so XEP-0368 and RFC
/// 6120 §3.2 need the lower-level `DNSServiceQueryRecord`. Answers come back on
/// a private serial queue and are bridged into one `async` call.
public enum SRVResolver {

    public static func query(
        _ name: String,
        timeout: Duration = .seconds(5)
    ) async throws -> [SRVRecord] {
        let collector = RecordCollector(query: name)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                collector.start(continuation: continuation, timeout: timeout)
            }
        } onCancel: {
            collector.cancel()
        }
    }

    /// Orders records for connection attempts per RFC 2782: ascending priority,
    /// and within one priority a weighted random shuffle so load spreads.
    public static func ordered(
        _ records: [SRVRecord],
        using generator: inout some RandomNumberGenerator
    ) -> [SRVRecord] {
        var result: [SRVRecord] = []
        let byPriority = Dictionary(grouping: records, by: \.priority)
        for priority in byPriority.keys.sorted() {
            var bucket = byPriority[priority]!
            while !bucket.isEmpty {
                let total = bucket.reduce(0) { $0 + Int($1.weight) }
                if total == 0 {
                    // All weights zero: plain random order.
                    result.append(bucket.remove(at: Int.random(in: 0..<bucket.count, using: &generator)))
                    continue
                }
                var pick = Int.random(in: 0...total, using: &generator)
                var chosen = bucket.count - 1
                for (index, record) in bucket.enumerated() {
                    pick -= Int(record.weight)
                    if pick <= 0 { chosen = index; break }
                }
                result.append(bucket.remove(at: chosen))
            }
        }
        return result
    }

    public static func ordered(_ records: [SRVRecord]) -> [SRVRecord] {
        var generator = SystemRandomNumberGenerator()
        return ordered(records, using: &generator)
    }
}

/// Collects the callbacks of one `DNSServiceQueryRecord` and resumes exactly
/// once. Locked rather than actor-isolated because the dns_sd callback is a bare
/// C function that cannot await.
private final class RecordCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "org.hrafn.xmppkit.srv")
    private let query: String

    private var service: DNSServiceRef?
    private var records: [SRVRecord] = []
    private var continuation: CheckedContinuation<[SRVRecord], any Error>?
    private var timer: DispatchSourceTimer?

    init(query: String) {
        self.query = query
    }

    func start(continuation: CheckedContinuation<[SRVRecord], any Error>, timeout: Duration) {
        lock.lock()
        self.continuation = continuation

        var ref: DNSServiceRef?
        let context = Unmanaged.passRetained(self).toOpaque()
        let status = DNSServiceQueryRecord(
            &ref,
            DNSServiceFlags(kDNSServiceFlagsReturnIntermediates),
            0,                                  // any interface
            query,
            UInt16(kDNSServiceType_SRV),
            UInt16(kDNSServiceClass_IN),
            { _, _, _, error, _, _, _, length, data, _, context in
                guard let context else { return }
                let collector = Unmanaged<RecordCollector>.fromOpaque(context).takeUnretainedValue()
                collector.handle(error: error, length: length, data: data)
            },
            context
        )

        guard status == kDNSServiceErr_NoError, let ref else {
            lock.unlock()
            Unmanaged<RecordCollector>.fromOpaque(context).release()
            continuation.resume(throwing: DNSError(kind: .serviceError(status), query: query))
            return
        }
        service = ref
        DNSServiceSetDispatchQueue(ref, queue)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout.seconds)
        timer.setEventHandler { [weak self] in self?.finishWithTimeout() }
        timer.activate()
        self.timer = timer
        lock.unlock()
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func handle(error: DNSServiceErrorType, length: UInt16, data: UnsafeRawPointer?) {
        if error == kDNSServiceErr_NoSuchRecord {
            // The name exists but has no SRV records: a normal outcome that
            // means "fall back to the next lookup".
            return finish(.success([]))
        }
        if error != kDNSServiceErr_NoError {
            return finish(.failure(DNSError(kind: .serviceError(error), query: query)))
        }
        if let data, length > 0 {
            let bytes = UnsafeRawBufferPointer(start: data, count: Int(length))
            if let record = Self.parse(Array(bytes)) {
                lock.lock()
                records.append(record)
                lock.unlock()
            }
        }
        // mDNSResponder does not reliably clear kDNSServiceFlagsMoreComing for
        // unicast queries, so the timer decides when the answer set is complete;
        // the first record simply shortens that wait.
        lock.lock()
        let collected = records
        lock.unlock()
        if !collected.isEmpty {
            lock.lock()
            timer?.schedule(deadline: .now() + 0.05)
            lock.unlock()
        }
    }

    private func finishWithTimeout() {
        lock.lock()
        let collected = records
        lock.unlock()
        if collected.isEmpty {
            finish(.failure(DNSError(kind: .timedOut, query: query)))
        } else {
            finish(.success(collected))
        }
    }

    private func finish(_ result: Result<[SRVRecord], any Error>) {
        lock.lock()
        guard let continuation else { return lock.unlock() }
        self.continuation = nil
        timer?.cancel()
        timer = nil
        let service = self.service
        self.service = nil
        lock.unlock()

        if let service {
            DNSServiceRefDeallocate(service)
            Unmanaged.passUnretained(self).release()
        }
        continuation.resume(with: result)
    }

    /// SRV RDATA: priority, weight, port (2 bytes each, network order) followed
    /// by the target as length-prefixed DNS labels.
    static func parse(_ bytes: [UInt8]) -> SRVRecord? {
        guard bytes.count >= 7 else { return nil }
        let priority = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        let weight = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        let port = UInt16(bytes[4]) << 8 | UInt16(bytes[5])

        var labels: [String] = []
        var index = 6
        while index < bytes.count {
            let length = Int(bytes[index])
            if length == 0 { break }
            // Name compression is not permitted in SRV RDATA (RFC 2782), and a
            // pointer here would need the whole message to resolve.
            guard length < 0x40, index + length < bytes.count else { return nil }
            let start = index + 1
            labels.append(String(decoding: bytes[start..<(start + length)], as: UTF8.self))
            index = start + length
        }
        let target = labels.isEmpty ? "." : labels.joined(separator: ".")
        return SRVRecord(priority: priority, weight: weight, port: port, target: target)
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// Exposes RDATA parsing to tests without widening the resolver's API.
public enum RecordCollectorTestHook {
    public static func parse(_ bytes: [UInt8]) -> SRVRecord? {
        RecordCollector.parse(bytes)
    }
}
