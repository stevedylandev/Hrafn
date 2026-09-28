import SwiftUI
import HrafnServices
import XMPPCore
import XMPPIM

/// A contact's OMEMO devices (or our own account's other devices), with
/// their fingerprints and what the user decided about each, and a scanner
/// for the verification code the contact's app shows.
struct EncryptionDevicesSection: View {
    let accountID: String
    let jid: String
    let title: LocalizedStringKey
    /// Our own account's other devices: they can be removed from its list.
    var isOwnAccount = false

    @Environment(AppModel.self) private var app
    @State private var devices: [OMEMODevice] = []
    @State private var scanning = false
    @State private var confirmingVerify: OMEMODevice?
    @State private var confirmingRemove: OMEMODevice?
    @State private var message: String?

    var body: some View {
        Section {
            if devices.isEmpty {
                Text("No encryption devices seen yet.").foregroundStyle(.secondary)
            }
            ForEach(devices) { device in
                DeviceRow(device: device, remove: isOwnAccount && device.isActive ? { confirmingRemove = device } : nil) { trust in
                    if trust == .verified { confirmingVerify = device } else { set(trust, device) }
                }
            }
            Button { scanning = true } label: {
                Label("Scan Verification Code", systemImage: "qrcode.viewfinder")
            }
            .accessibilityIdentifier("encryption.scan")
        } header: {
            Text(title)
        } footer: {
            Text("Compare fingerprints in person, or scan the code their app shows. Once a device is verified, new devices wait for your decision before messages are encrypted for them.")
        }
        .sheet(isPresented: $scanning) {
            QRScannerView { code in
                scanning = false
                verify(code)
            }
        }
        .confirmationDialog("Mark as Verified?", isPresented: Binding(
            get: { confirmingVerify != nil }, set: { if !$0 { confirmingVerify = nil } }), titleVisibility: .visible) {
            Button("Mark as Verified") { if let device = confirmingVerify { set(.verified, device) } }
        } message: {
            Text("Only if the fingerprint matches, character for character, what their device shows.")
        }
        .confirmationDialog("Remove This Device?", isPresented: Binding(
            get: { confirmingRemove != nil }, set: { if !$0 { confirmingRemove = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let device = confirmingRemove { remove(device) } }
        } message: {
            Text("Contacts stop encrypting messages for it. If the device is still in use, it adds itself back the next time it connects.")
        }
        .alert("Verification", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
        .observing({ app.manager.omemoDevices(accountID: accountID, jid: jid) }, id: jid, into: $devices)
    }

    private func remove(_ device: OMEMODevice) {
        Task {
            do {
                guard let session = app.manager.session(for: accountID) else { throw AccountError.notConnected }
                try await session.removeOwnDevices([device.deviceID])
            } catch {
                message = String(describing: error)
            }
        }
    }

    private func set(_ trust: DeviceTrust, _ device: OMEMODevice) {
        do { try app.manager.setTrust(trust, of: device, accountID: accountID) }
        catch { message = String(describing: error) }
    }

    private func verify(_ code: String) {
        guard let uri = XMPPURI(code), !uri.omemoFingerprints.isEmpty else {
            message = String(localized: "That code has no encryption fingerprints.")
            return
        }
        guard uri.jid.bare.description == jid else {
            message = String(localized: "That code is for \(uri.jid.bare.description), not \(jid).")
            return
        }
        do {
            let result = try app.manager.verify(uri, accountID: accountID)
            if !result.mismatched.isEmpty {
                message = String(localized: "The fingerprints don’t match for \(result.mismatched.count) device(s). Nothing was verified for those: the code may be old, or someone may be intercepting your messages.")
            } else if result.verified.isEmpty {
                message = String(localized: "None of the devices in that code has been seen here yet. Try again after exchanging a message.")
            } else {
                message = String(localized: "Verified \(result.verified.count) device(s).")
            }
        } catch {
            message = String(describing: error)
        }
    }
}

private struct DeviceRow: View {
    let device: OMEMODevice
    var remove: (() -> Void)?
    let decide: (DeviceTrust) -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: device.trust.symbol).foregroundStyle(device.trust.color)
                    Text(device.trust.label).font(.subheadline.weight(.semibold))
                    if !device.isActive {
                        Text("Inactive").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(device.fingerprint)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                Text("Device \(String(device.deviceID))").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                if device.trust != .verified {
                    Button { decide(.verified) } label: { Label("Mark as Verified…", systemImage: "checkmark.shield") }
                }
                if device.trust != .blind {
                    Button { decide(.blind) } label: { Label("Trust Without Verifying", systemImage: "shield") }
                }
                if device.trust != .untrusted {
                    Button(role: .destructive) { decide(.untrusted) } label: {
                        Label("Don’t Trust", systemImage: "xmark.shield")
                    }
                }
                if let remove {
                    Button(role: .destructive, action: remove) {
                        Label("Remove from Account…", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle").imageScale(.large)
            }
            .accessibilityLabel("Trust options")
        }
        .accessibilityElement(children: .combine)
    }
}

/// This device's fingerprint, and the code others scan to verify it.
struct OwnEncryptionSection: View {
    let accountID: String
    @Environment(AppModel.self) private var app
    @State private var showingCode = false

    var body: some View {
        if let own = app.manager.ownOMEMODevice(accountID: accountID) {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(own.fingerprint).font(.footnote.monospaced()).textSelection(.enabled)
                    Text("Device \(String(own.deviceID))").font(.caption2).foregroundStyle(.secondary)
                }
                Button { showingCode = true } label: {
                    Label("Show Verification Code", systemImage: "qrcode")
                }
            } header: {
                Text("This Device’s Fingerprint")
            } footer: {
                Text("Contacts scan this code, or compare the fingerprint, to verify your messages come from this device.")
            }
            .sheet(isPresented: $showingCode) {
                if let uri = app.manager.verificationURI(accountID: accountID) {
                    QRCodeSheet(title: String(localized: "Verification Code"), uri: uri)
                }
            }
        }
    }
}

/// Shown in a chat when the contact has devices waiting for a decision.
struct NewDevicesBanner: View {
    let count: Int
    let review: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "questionmark.diamond.fill").foregroundStyle(.orange)
            Text("^[\(count) new device](inflect: true) not trusted yet. Messages aren’t encrypted for it until you decide.")
                .font(.footnote)
            Spacer()
            Button("Review", action: review).font(.footnote.weight(.semibold))
        }
        .padding(10)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("encryption.newDevices")
    }
}

extension DeviceTrust {
    var label: String {
        switch self {
        case .verified: String(localized: "Verified")
        case .blind: String(localized: "Trusted, not verified")
        case .undecided: String(localized: "New, not trusted yet")
        case .untrusted: String(localized: "Not trusted")
        }
    }

    var symbol: String {
        switch self {
        case .verified: "checkmark.shield.fill"
        case .blind: "shield"
        case .undecided: "questionmark.diamond.fill"
        case .untrusted: "xmark.shield.fill"
        }
    }

    var color: Color {
        switch self {
        case .verified: .green
        case .blind: .secondary
        case .undecided: .orange
        case .untrusted: .red
        }
    }
}
