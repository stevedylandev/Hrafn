import Foundation
import HrafnStore
import XMPPClient
import XMPPCore
import XMPPIM

/// XEP-0363 for one file already in the media store: find the service, ask
/// for a slot, PUT, record the URL. Shared by the session and the share
/// extension's delivery.
struct FileUploader: Sendable {
    let client: XMPPClient
    let transfer: HTTPTransfer
    let database: HrafnDatabase
    let media: MediaStore

    /// Returns the GET URL, and the service (to reuse for the next file).
    /// `encrypted` uploads the file as XEP-0454 ciphertext under a name that
    /// says nothing about it; the key is stored with the attachment.
    func upload(_ attachment: Attachment, messageID: Int64, service known: HTTPUpload.Service?, encrypted: Bool = false,
                progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> (URL, HTTPUpload.Service) {
        guard let localPath = attachment.localPath else { throw TransferError.missingFile }
        var file = media.url(for: localPath)
        guard MediaStore.fileSize(of: file) != nil else { throw TransferError.missingFile }
        var fragment: String?
        if encrypted {
            (file, fragment) = try FileEncryption.encrypt(file)
        }
        defer { if encrypted { try? FileManager.default.removeItem(at: file) } }
        guard let size = MediaStore.fileSize(of: file) else { throw TransferError.missingFile }
        let module = HTTPUpload(client: client)
        var found = known
        if found == nil { found = try await module.discover() }
        guard let service = found else { throw TransferError.noUploadService }
        if let max = service.maxFileSize, size > max { throw HTTPUpload.Failure.fileTooLarge(maxFileSize: max) }

        let fileExtension = (attachment.fileName as NSString).pathExtension
        let name = encrypted ? UUID().uuidString.lowercased() + (fileExtension.isEmpty ? "" : "." + fileExtension)
                             : attachment.fileName
        let type = encrypted ? "application/octet-stream" : attachment.mimeType
        let slot = try await module.requestSlot(filename: name, size: size, contentType: type, service: service.jid)
        try await transfer.upload(file, to: slot, contentType: type, progress: progress)
        let link = fragment.flatMap { FileEncryption.link(for: slot.getURL, fragment: $0) }
        try database.completeUpload(messageID: messageID, url: slot.getURL, encryptionKey: fragment, body: link)
        return (slot.getURL, service)
    }

    /// Refusals are final until the user retries; network trouble leaves the
    /// file in the outbox for the next session.
    static func recordFailure(_ error: any Error, messageID: Int64, database: HrafnDatabase) {
        let text = AccountSession.describeTransfer(error)
        _ = try? database.updateAttachment(messageID: messageID) { $0.error = text }
        switch error {
        case is URLError, ClientError.notConnected, ClientError.disconnected, ClientError.timedOut, is CancellationError:
            break
        default:
            try? database.setState(messageID: messageID, .failed, errorText: text)
        }
    }
}
