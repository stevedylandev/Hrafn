import CryptoKit
import Foundation
import Testing
@testable import HrafnServices
import HrafnStore
import XMPPCore
import XMPPIM

/// XEP-0454: `aesgcm://` links and the file cipher.
struct FileEncryptionTests {

    private func temporaryFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "plain-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }

    @Test func roundTrip() throws {
        let plaintext = Data((0..<10_000).map { UInt8($0 % 251) })
        let source = try temporaryFile(plaintext)
        defer { try? FileManager.default.removeItem(at: source) }
        let (ciphertext, fragment) = try FileEncryption.encrypt(source)
        defer { try? FileManager.default.removeItem(at: ciphertext) }
        #expect(fragment.count == 88)
        let sealed = try Data(contentsOf: ciphertext)
        #expect(sealed.count == plaintext.count + 16)
        #expect(sealed.prefix(100) != plaintext.prefix(100))

        let opened = try FileEncryption.decrypt(ciphertext, fragment: fragment)
        defer { try? FileManager.default.removeItem(at: opened) }
        #expect(try Data(contentsOf: opened) == plaintext)
    }

    @Test func tamperingAndWrongKeysAreRefused() throws {
        let source = try temporaryFile(Data("attack at dawn".utf8))
        let (ciphertext, fragment) = try FileEncryption.encrypt(source)
        var data = try Data(contentsOf: ciphertext)
        data[0] ^= 1
        try data.write(to: ciphertext)
        #expect(throws: TransferError.decryptionFailed) { try FileEncryption.decrypt(ciphertext, fragment: fragment) }

        let other = try FileEncryption.encrypt(source)
        #expect(throws: TransferError.decryptionFailed) {
            try FileEncryption.decrypt(other.ciphertext, fragment: String(fragment.reversed()))
        }
    }

    /// Older clients send a 16-byte IV (96 hex characters).
    @Test func sixteenByteIV() throws {
        let key = Data((0..<32).map { UInt8($0) }), iv = Data((0..<16).map { UInt8(100 + $0) })
        let plaintext = Data("from an older client".utf8)
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: iv))
        let file = try temporaryFile(sealed.ciphertext + sealed.tag)
        let fragment = (iv + key).map { String(format: "%02x", $0) }.joined()
        let link = try #require(FileEncryption.link("aesgcm://upload.example.org/abc/photo.jpg#" + fragment))
        let opened = try FileEncryption.decrypt(file, fragment: link.fragment)
        #expect(try Data(contentsOf: opened) == plaintext)
    }

    @Test func links() throws {
        let fragment = String(repeating: "ab", count: 44)
        let link = try #require(FileEncryption.link("aesgcm://upload.example.org:5281/x/y%20z.jpg#" + fragment))
        #expect(link.url.absoluteString == "https://upload.example.org:5281/x/y%20z.jpg")
        #expect(FileEncryption.link(for: link.url, fragment: fragment)
                == "aesgcm://upload.example.org:5281/x/y%20z.jpg#" + fragment)
        // Not a link: other text, a short fragment, no fragment, whitespace.
        #expect(FileEncryption.link("see aesgcm://upload.example.org/a#" + fragment) == nil)
        #expect(FileEncryption.link("aesgcm://upload.example.org/a#abcd") == nil)
        #expect(FileEncryption.link("aesgcm://upload.example.org/a") == nil)
        #expect(FileEncryption.link("https://upload.example.org/a#" + fragment) == nil)
    }

    /// A decrypted body that is a link becomes an encrypted attachment.
    @Test func receivedLinkIsAnAttachment() throws {
        let fragment = String(repeating: "0f", count: 44)
        let message = Message.chat(to: try JID("juliet@capulet.example"),
                                   body: "aesgcm://upload.example.org/abc/balcony.jpg#" + fragment)
        let attachment = try #require(message.fileAttachment)
        #expect(attachment.url?.absoluteString == "https://upload.example.org/abc/balcony.jpg")
        #expect(attachment.encryptionKey == fragment)
        #expect(attachment.kind == .image)
    }
}
