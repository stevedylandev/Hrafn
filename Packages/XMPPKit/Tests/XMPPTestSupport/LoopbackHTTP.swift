import CryptoKit
import Foundation

/// HTTP to the Docker servers from the development machine: `.test` names
/// do not resolve here, so requests go to 127.0.0.1 with the original `Host`
/// header (both servers route by it), and the servers' certificates are
/// trusted by fingerprint.
public final class LoopbackHTTP: NSObject, URLSessionDelegate, Sendable {

    private let fingerprints: Set<Data>
    public nonisolated(unsafe) private(set) var session: URLSession!

    public init(servers: [TestServer] = [.prosody, .ejabberd]) throws {
        fingerprints = Set(try servers.map { try $0.certificateFingerprint() })
        super.init()
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    }

    /// `url` with its host replaced by 127.0.0.1.
    public static func rewrite(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.hasSuffix(".test") == true else { return url }
        components.host = "127.0.0.1"
        return components.url ?? url
    }

    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: rewrite(url))
        if let host = url.host { request.setValue(url.port.map { "\(host):\($0)" } ?? host, forHTTPHeaderField: "Host") }
        return request
    }

    public func put(_ data: Data, to url: URL, headers: [String: String], contentType: String?) async throws -> Int {
        var request = Self.request(url)
        request.httpMethod = "PUT"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let (_, response) = try await session.upload(for: request, from: data)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    public func get(_ url: URL) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: Self.request(url))
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              fingerprints.contains(Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data))) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

extension TestServer {
    /// SHA-256 of the certificate the server presents.
    public func certificateFingerprint() throws -> Data {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let pem = try String(contentsOf: root.appending(path: certificatePath), encoding: .utf8)
        let base64 = pem
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .filter { !$0.isWhitespace }
        guard let der = Data(base64Encoded: base64) else { throw CocoaError(.fileReadCorruptFile) }
        return Data(SHA256.hash(data: der))
    }
}
