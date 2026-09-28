import CryptoKit
import Foundation
import XMPPIM

public enum TransferError: Error, Sendable, Equatable, CustomStringConvertible {
    case http(status: Int)
    /// Bigger than the caller allowed.
    case tooLarge(Int)
    /// No upload service on the account's server.
    case noUploadService
    case missingFile
    /// XEP-0446: the file's SHA-256 is not the one its sender gave.
    case digestMismatch
    /// XEP-0454: the encrypted file did not open with the key it was shared
    /// with.
    case decryptionFailed

    public var description: String {
        switch self {
        case .http(let status): "the server answered HTTP \(status)"
        case .tooLarge(let size): "the file is too large (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))"
        case .noUploadService: "the server does not accept file uploads"
        case .missingFile: "the file is no longer on this device"
        case .digestMismatch: "the file is not the one that was shared (its checksum differs)"
        case .decryptionFailed: "the encrypted file could not be decrypted"
        }
    }
}

/// HTTP for shared files: the XEP-0363 PUT, and fetching what others share.
/// Trusts what the system trusts, plus the certificate the user pinned for
/// the account (a self-hosted server's upload component usually presents the
/// same one).
public final class HTTPTransfer: NSObject, URLSessionDelegate, Sendable {

    private let pinnedFingerprint: String?
    private let loopback: Bool
    private nonisolated(unsafe) var session: URLSession!

    /// `pinnedFingerprint`: hex SHA-256, as `Account.trustedFingerprint`.
    /// `loopback` sends requests for `.test` hosts to 127.0.0.1 with their
    /// real `Host` header — the Docker test servers, reached from a
    /// development machine or simulator where nothing resolves them.
    public init(pinnedFingerprint: String?, loopback: Bool = false) {
        self.pinnedFingerprint = pinnedFingerprint?.uppercased()
        self.loopback = loopback
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// PUTs `file` to the slot (§5 of XEP-0363), with its headers.
    public func upload(_ file: URL, to slot: HTTPUpload.Slot, contentType: String?,
                       progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        var request = request(for: slot.putURL)
        request.httpMethod = "PUT"
        for (name, value) in slot.putHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(contentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.upload(for: request, fromFile: file,
                                                     delegate: ProgressDelegate(progress))
        try Self.check(response)
    }

    /// The size a server reports for `url`, without fetching it.
    public func contentLength(of url: URL, allowsExpensiveNetwork: Bool = true) async throws -> Int? {
        var request = request(for: url)
        request.httpMethod = "HEAD"
        request.allowsExpensiveNetworkAccess = allowsExpensiveNetwork
        let (_, response) = try await session.data(for: request)
        try Self.check(response)
        let length = response.expectedContentLength
        return length >= 0 ? Int(length) : nil
    }

    /// Fetches `url` into a temporary file the caller must move away.
    /// Stops once more than `maxBytes` arrive.
    public func download(_ url: URL, maxBytes: Int? = nil, allowsExpensiveNetwork: Bool = true,
                         progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        var request = request(for: url)
        request.allowsExpensiveNetworkAccess = allowsExpensiveNetwork
        let delegate = ProgressDelegate(progress, maxBytes: maxBytes)
        let temporary: URL, response: URLResponse
        do {
            (temporary, response) = try await session.download(for: request, delegate: delegate)
        } catch {
            if let size = delegate.exceeded { throw TransferError.tooLarge(size) }
            throw error
        }
        if let size = delegate.exceeded { throw TransferError.tooLarge(size) }
        try Self.check(response)
        // The system removes its temporary file when this returns.
        let kept = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.moveItem(at: temporary, to: kept)
        return kept
    }

    private func request(for url: URL) -> URLRequest {
        guard loopback, let host = url.host, host.hasSuffix(".test"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return URLRequest(url: url) }
        components.host = "127.0.0.1"
        var request = URLRequest(url: components.url ?? url)
        request.setValue(url.port.map { "\(host):\($0)" } ?? host, forHTTPHeaderField: "Host")
        return request
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else { throw TransferError.http(status: http.statusCode) }
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // Loopback requests go to this machine's Docker servers, whose
        // private CA nothing trusts, and name 127.0.0.1, which no
        // certificate does. Development only.
        if loopback, challenge.protectionSpace.host == "127.0.0.1" {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if let pinnedFingerprint, let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first {
            let fingerprint = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
                .map { String(format: "%02X", $0) }.joined()
            if fingerprint == pinnedFingerprint {
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            }
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

/// Reports one task's progress, and cancels a download that grows past its
/// limit.
private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void
    private let maxBytes: Int?
    private var observation: NSKeyValueObservation?
    private let lock = NSLock()
    private var exceededSize: Int?

    init(_ report: @escaping @Sendable (Double) -> Void, maxBytes: Int? = nil) {
        self.report = report
        self.maxBytes = maxBytes
    }

    var exceeded: Int? { lock.withLock { exceededSize } }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let maxBytes = self.maxBytes
        observation = task.progress.observe(\.fractionCompleted) { [weak self, weak task] progress, _ in
            guard let self else { return }
            self.report(progress.fractionCompleted)
            guard let maxBytes, let task else { return }
            let size = max(task.countOfBytesExpectedToReceive, task.countOfBytesReceived)
            if size > maxBytes {
                self.lock.withLock { self.exceededSize = Int(size) }
                task.cancel()
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
