import CryptoKit
import Foundation

/// XEP-0454 OMEMO Media Sharing: a file is encrypted with AES-256-GCM under a
/// fresh key before it is uploaded, and shared as an `aesgcm://` link whose
/// fragment carries the IV and the key. The link travels only inside an
/// OMEMO-encrypted body; the upload service sees ciphertext.
enum FileEncryption {

    /// A parsed `aesgcm://` link.
    struct Link: Sendable, Hashable {
        /// Where the ciphertext is: the link with `https` for its scheme and
        /// no fragment.
        var url: URL
        /// Hex IV then key, as in the link.
        var fragment: String
    }

    /// §4: `aesgcm://host/path#<iv><key>`, in hex. The IV is 12 bytes (as
    /// Hrafn sends) or 16 (as older clients send), the key 32.
    static func link(_ text: String) -> Link? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.lowercased().hasPrefix("aesgcm://"), !text.contains(where: \.isWhitespace),
              var components = URLComponents(string: text), let fragment = components.fragment,
              components.host?.isEmpty == false, key(fromFragment: fragment) != nil else { return nil }
        components.scheme = "https"
        components.fragment = nil
        guard let url = components.url else { return nil }
        return Link(url: url, fragment: fragment.lowercased())
    }

    /// The link for a ciphertext uploaded to `url`.
    static func link(for url: URL, fragment: String) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "aesgcm"
        components.fragment = fragment
        return components.string
    }

    /// Encrypts `file` into a new temporary file: ciphertext followed by the
    /// 16-byte tag. Returns it and the fragment for the link.
    static func encrypt(_ file: URL) throws -> (ciphertext: URL, fragment: String) {
        let plaintext = try Data(contentsOf: file, options: .mappedIfSafe)
        let key = SymmetricKey(size: .bits256)
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        let output = FileManager.default.temporaryDirectory.appending(path: "upload-\(UUID().uuidString)")
        try (sealed.ciphertext + sealed.tag).write(to: output)
        let keyData = key.withUnsafeBytes { Data($0) }
        return (output, hex(Data(nonce)) + hex(keyData))
    }

    /// Decrypts a downloaded ciphertext into a new temporary file. Throws if
    /// the tag does not match (wrong key, or the file was changed).
    static func decrypt(_ file: URL, fragment: String) throws -> URL {
        guard let (iv, key) = key(fromFragment: fragment) else { throw TransferError.decryptionFailed }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard data.count >= 16 else { throw TransferError.decryptionFailed }
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: data.dropLast(16),
                                            tag: data.suffix(16))
            plaintext = try AES.GCM.open(box, using: SymmetricKey(data: key))
        } catch {
            throw TransferError.decryptionFailed
        }
        let output = FileManager.default.temporaryDirectory.appending(path: "download-\(UUID().uuidString)")
        try plaintext.write(to: output)
        return output
    }

    /// The IV and key in a fragment: the key is the last 32 bytes.
    static func key(fromFragment fragment: String) -> (iv: Data, key: Data)? {
        guard fragment.count == 88 || fragment.count == 96, let bytes = data(hex: fragment) else { return nil }
        return (bytes.prefix(bytes.count - 32), bytes.suffix(32))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func data(hex: String) -> Data? {
        var bytes = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
