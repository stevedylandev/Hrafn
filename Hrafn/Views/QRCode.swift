import SwiftUI
import CoreImage.CIFilterBuiltins
import Vision
import VisionKit
import XMPPCore
import XMPPIM

/// An `xmpp:` URI as a QR code, for another device to scan.
struct QRCodeSheet: View {
    let title: String
    let uri: XMPPURI
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let image = Self.image(for: uri.description) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 280)
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 16).fill(.white))
                        .accessibilityLabel("QR code for \(uri.jid.description)")
                }
                Text(uri.jid.description).font(.headline).textSelection(.enabled)
                ShareLink(item: uri.description) { Label("Share Link", systemImage: "square.and.arrow.up") }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .themed()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    static func image(for string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// Scans a QR code with the camera and reports its text once.
struct QRScannerView: View {
    let onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    Scanner(onScan: onScan).ignoresSafeArea()
                } else {
                    ContentUnavailableView("Camera Unavailable", systemImage: "camera",
                                           description: Text("QR scanning needs a camera and permission to use it."))
                }
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private struct Scanner: UIViewControllerRepresentable {
        let onScan: (String) -> Void

        func makeUIViewController(context: Context) -> DataScannerViewController {
            let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                    isHighlightingEnabled: true)
            scanner.delegate = context.coordinator
            try? scanner.startScanning()
            return scanner
        }

        func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

        func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

        final class Coordinator: NSObject, DataScannerViewControllerDelegate {
            let onScan: (String) -> Void
            private var done = false
            init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

            func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem],
                             allItems: [RecognizedItem]) {
                guard !done else { return }
                for case .barcode(let code) in items {
                    if let value = code.payloadStringValue {
                        done = true
                        scanner.stopScanning()
                        onScan(value)
                        return
                    }
                }
            }
        }
    }
}
