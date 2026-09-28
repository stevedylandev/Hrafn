import SwiftUI
import HrafnServices

/// Sign in to an existing XMPP account. The login is tried before anything is
/// saved, so a typo never becomes a stored account.
struct AccountSetupView: View {
    var isOnboarding = false

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var password = ""
    @State private var showAdvanced = false
    @State private var host = ""
    @State private var port = ""
    @State private var directTLS = true
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var untrustedFingerprint: String?

    var body: some View {
        Form {
            if isOnboarding {
                Section {
                    VStack(spacing: 12) {
                        Image("Hrafn")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 140, height: 140)
                            .foregroundStyle(.primary)
                            .accessibilityHidden(true)
                        Text("Welcome to Hrafn")
                            .font(.title.bold())
                        Text("Sign in with an account on any XMPP server.")
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
            }

            Section("Account") {
                TextField("you@example.com", text: $address)
                    .accessibilityIdentifier("setup.address")
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .accessibilityIdentifier("setup.password")
                    .textContentType(.password)
            }

            Section {
                DisclosureGroup("Connection settings", isExpanded: $showAdvanced) {
                    TextField("Host (default: DNS lookup)", text: $host)
                        .accessibilityIdentifier("setup.host")
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("setup.port")
                    Toggle("Direct TLS", isOn: $directTLS)
                }
            } footer: {
                Text("Only needed when the server's DNS records are missing or you connect to a local test server.")
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task { await signIn(trusting: nil) }
                } label: {
                    HStack {
                        Text("Sign In")
                        Spacer()
                        if isWorking { ProgressView() }
                    }
                }
                .disabled(!canSubmit || isWorking)
                .accessibilityIdentifier("setup.signIn")
            }
        }
        .themed()
        .navigationTitle(isOnboarding ? "" : "Add Account")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Untrusted Certificate", isPresented: Binding(
            get: { untrustedFingerprint != nil },
            set: { if !$0 { untrustedFingerprint = nil } }
        )) {
            Button("Trust and Continue", role: .destructive) {
                let fingerprint = untrustedFingerprint
                Task { await signIn(trusting: fingerprint) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The server's certificate is not trusted by this device. Only continue if you know the server uses this certificate:\n\n\(formatted(untrustedFingerprint ?? ""))")
        }
    }

    private var canSubmit: Bool {
        address.contains("@") && !password.isEmpty
    }

    private func signIn(trusting fingerprint: String?) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await app.manager.addAccount(
                jid: address, password: password,
                host: host.isEmpty ? nil : host, port: Int(port), directTLS: directTLS,
                trustedFingerprint: fingerprint)
            if !isOnboarding { dismiss() }
        } catch AccountError.untrustedCertificate(let fingerprint) {
            untrustedFingerprint = fingerprint
        } catch {
            errorMessage = String(describing: error)
        }
    }
}

/// `AB:CD:…` for a hex fingerprint, grouped so it can be compared by eye.
func formatted(_ fingerprint: String) -> String {
    var pairs: [String] = []
    var index = fingerprint.startIndex
    while index < fingerprint.endIndex {
        let next = fingerprint.index(index, offsetBy: 2, limitedBy: fingerprint.endIndex) ?? fingerprint.endIndex
        pairs.append(String(fingerprint[index..<next]))
        index = next
    }
    return pairs.joined(separator: ":")
}
