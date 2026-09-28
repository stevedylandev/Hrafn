import PhotosUI
import SwiftUI
import HrafnServices
import HrafnStore
import XMPPCore
import XMPPIM

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showingAddAccount = false
    @State private var availability: ContactAvailability = .online
    @State private var statusText = ""
    /// The account shown beside the list in regular width.
    @State private var selectedAccount: String?
    #if DEBUG
    @State private var showingProbe = false
    #endif

    var body: some View {
        Group {
            if sizeClass == .regular {
                // iPad: the settings beside the selected account.
                NavigationSplitView {
                    List(selection: $selectedAccount) { sections.themedCells() }
                        .themed()
                        .listStyle(.insetGrouped)
                        .navigationTitle("Settings")
                } detail: {
                    if let selectedAccount {
                        NavigationStack {
                            AccountDetailView(accountID: selectedAccount).id(selectedAccount)
                        }
                    } else {
                        ContentUnavailableView("No Account Selected", systemImage: "person.crop.circle",
                                               description: Text("Choose an account to see its settings."))
                    }
                }
            } else {
                NavigationStack {
                    Form { sections.themedCells() }
                        .themed()
                        .navigationTitle("Settings")
                        .navigationDestination(for: String.self) { accountID in
                            AccountDetailView(accountID: accountID)
                        }
                }
            }
        }
        .onChange(of: app.manager.accounts.map(\.id)) { _, ids in
            if let selectedAccount, !ids.contains(selectedAccount) { self.selectedAccount = nil }
        }
        .sheet(isPresented: $showingAddAccount) {
            NavigationStack {
                AccountSetupView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingAddAccount = false } }
                    }
            }
        }
        #if DEBUG
        .sheet(isPresented: $showingProbe) { StreamProbeView() }
        #endif
    }

    @ViewBuilder
    private var sections: some View {
        @Bindable var app = app
        Section("Accounts") {
            ForEach(app.manager.accounts) { account in
                NavigationLink(value: account.id) {
                    AccountRow(account: account)
                }
                .tag(account.id)
            }
            Button { showingAddAccount = true } label: { Label("Add Account", systemImage: "plus") }
        }

        Section {
            Picker("Availability", selection: $availability) {
                ForEach([ContactAvailability.online, .chat, .away, .extendedAway, .doNotDisturb], id: \.self) {
                    Text($0.label).tag($0)
                }
            }
            TextField("Status message", text: $statusText)
                .onSubmit { publishPresence() }
        } header: {
            Text("My Status")
        } footer: {
            Text("Shown to contacts who share status with you, on every account.")
        }
        .onChange(of: availability) { publishPresence() }

        Section {
            Picker("Download automatically", selection: $app.mediaPolicy.autoDownload) {
                Text("Always").tag(MediaPolicy.AutoDownload.always)
                Text("On Wi-Fi").tag(MediaPolicy.AutoDownload.wifi)
                Text("Never").tag(MediaPolicy.AutoDownload.never)
            }
            .accessibilityIdentifier("settings.autoDownload")
            Picker("Up to", selection: $app.mediaPolicy.maxAutoDownloadSize) {
                ForEach([2, 10, 25, 100], id: \.self) { megabytes in
                    Text("\(megabytes) MB").tag(megabytes * 1024 * 1024)
                }
            }
            .disabled(app.mediaPolicy.autoDownload == .never)
        } header: {
            Text("Photos, Videos & Files")
        } footer: {
            Text("Larger files, and everything when automatic download is off, wait for a tap.")
        }

        Section {
            Picker("Appearance", selection: $app.appearance.mode) {
                ForEach(Appearance.Mode.allCases) { Text($0.label).tag($0) }
            }
            .accessibilityIdentifier("settings.appearance")
            Picker("Font", selection: $app.appearance.font) {
                ForEach(Appearance.FontStyle.allCases) { Text($0.label).tag($0) }
            }
            NavigationLink {
                ThemePickerView(colorScheme: .light)
            } label: {
                LabeledContent("Light Theme", value: app.appearance.scheme(id: app.appearance.lightTheme)?.name
                               ?? String(localized: "System"))
            }
            .accessibilityIdentifier("settings.lightTheme")
            NavigationLink {
                ThemePickerView(colorScheme: .dark)
            } label: {
                LabeledContent("Dark Theme", value: app.appearance.scheme(id: app.appearance.darkTheme)?.name
                               ?? String(localized: "System"))
            }
            .accessibilityIdentifier("settings.darkTheme")
            ColorPicker("Accent Color", selection: $app.appearance.accentHex.color(default: palette?.accent ?? .accentColor),
                        supportsOpacity: false)
            if app.appearance.accentHex != nil {
                Button("Use Theme Accent") { app.appearance.accentHex = nil }
            }
            if !app.appearance.isDefault {
                Button("Reset Appearance", role: .destructive) { app.appearance = Appearance() }
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text("Themes are base16 colour schemes, one for light mode and one for dark. The accent colours buttons and your messages.")
        }

        if let error = app.storageError {
            Section("Storage") {
                Text("History could not be opened and is not being saved: \(error)")
                    .foregroundStyle(.red)
            }
        }

        #if DEBUG
        Section("Debug") {
            if let console = app.console {
                NavigationLink("XML Console") { XMLConsoleView(lines: console.lines) }
            }
            Button("Stream Probe") { showingProbe = true }
        }
        #endif

        Section {
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
        }
    }

    private func publishPresence() {
        let (availability, text) = (availability, statusText)
        for account in app.manager.accounts {
            let session = app.manager.session(for: account.id)
            Task { try? await session?.setPresence(availability, status: text.isEmpty ? nil : text) }
        }
    }
}

private struct AccountRow: View {
    let account: Account
    @Environment(AppModel.self) private var app
    @State private var profile: Profile?

    var body: some View {
        let status = app.manager.status(for: account.id)
        HStack(spacing: 12) {
            Avatar(name: profile?.nickname ?? account.jid, size: 40, image: app.avatarURL(profile), colorKey: account.jid)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile?.nickname ?? account.jid)
                if profile?.nickname != nil {
                    Text(account.jid).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Circle().fill(account.enabled ? status.connection.color : .gray).frame(width: 8, height: 8)
                    Text(account.enabled ? status.connection.label : String(localized: "Disabled"))
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .observing({ app.database.profileStream(accountID: account.id, jid: account.jid) }, id: account.id,
                   into: $profile)
    }
}

/// Our own avatar (XEP-0084) and nickname (XEP-0172) on one account.
private struct ProfileSection: View {
    let account: Account

    @Environment(AppModel.self) private var app
    @State private var profile: Profile?
    @State private var nickname = ""
    @State private var photo: PhotosPickerItem?
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var session: AccountSession? { app.manager.session(for: account.id) }

    var body: some View {
        let (name, image, jid) = (profile?.nickname ?? account.jid, app.avatarURL(profile), account.jid)
        Section {
            HStack(spacing: 16) {
                PhotosPicker(selection: $photo, matching: .images) {
                    Avatar(name: name, size: 72, image: image, colorKey: jid)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "pencil.circle.fill")
                                .font(.title2)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .background(Circle().fill(Color(.systemBackground)))
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose avatar")
                .accessibilityIdentifier("profile.avatar")
                VStack(alignment: .leading) {
                    TextField("Nickname", text: $nickname)
                        .onSubmit { Task { await saveNickname() } }
                        .accessibilityIdentifier("profile.nickname")
                    Text("Contacts see this until they name you themselves.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if isWorking { ProgressView() }
            }
            if profile?.avatarHash != nil {
                Button("Remove Avatar", role: .destructive) { Task { await removeAvatar() } }
            }
        } header: {
            Text("Profile")
        }
        .disabled(session == nil || isWorking)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task { await setAvatar(item) }
        }
        .onChange(of: profile?.nickname) { _, nick in nickname = nick ?? "" }
        .observing({ app.database.profileStream(accountID: account.id, jid: account.jid) }, id: account.id,
                   into: $profile)
        .alert("Couldn't Update Profile", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func setAvatar(_ item: PhotosPickerItem) async {
        guard let session else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let (png, side) = try MediaPreparation.avatar(data)
            try await session.setAvatar(png, type: "image/png", width: side, height: side)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func removeAvatar() async {
        isWorking = true
        defer { isWorking = false }
        do { try await session?.removeAvatar() } catch { errorMessage = String(describing: error) }
    }

    private func saveNickname() async {
        guard nickname != (profile?.nickname ?? "") else { return }
        isWorking = true
        defer { isWorking = false }
        do { try await session?.setNickname(nickname) } catch { errorMessage = String(describing: error) }
    }
}

struct AccountDetailView: View {
    let accountID: String

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var blocked: [String] = []
    @State private var host = ""
    @State private var port = ""
    @State private var directTLS = true
    @State private var password = ""
    @State private var confirmingRemove = false
    @State private var showingQR = false
    @State private var errorMessage: String?

    private var account: Account? { app.manager.accounts.first { $0.id == accountID } }

    var body: some View {
        if let account {
            form(account)
        } else {
            ContentUnavailableView("Account Removed", systemImage: "person.crop.circle.badge.xmark")
        }
    }

    private func form(_ account: Account) -> some View {
        let status = app.manager.status(for: accountID)
        return Form {
            Group {
                ProfileSection(account: account)

                Section {
                    LabeledContent("Status") {
                        Text(account.enabled ? status.connection.label : String(localized: "Disabled")).foregroundStyle(status.connection.color)
                    }
                    if let bound = status.boundJID {
                        LabeledContent("Session", value: bound)
                    }
                    if let error = status.lastError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                    LabeledContent("Notifications") {
                        Text(status.push.label).accessibilityIdentifier("account.push")
                    }
                    Toggle("Enabled", isOn: Binding(
                        get: { account.enabled },
                        set: { enabled in Task { await app.manager.setEnabled(accountID, enabled) } }))
                }

                if let fingerprint = status.rejectedCertificate {
                    Section {
                        Text(formatted(fingerprint)).font(.caption.monospaced()).textSelection(.enabled)
                        Button("Trust This Certificate", role: .destructive) {
                            Task { await app.manager.trustCertificate(fingerprint, for: accountID) }
                        }
                    } header: {
                        Text("Untrusted Certificate")
                    } footer: {
                        Text("The server presented a certificate this device does not trust. Only trust it if you know it belongs to your server.")
                    }
                }

                Section {
                    Button { showingQR = true } label: { Label("Show My QR Code", systemImage: "qrcode") }
                }

                OwnEncryptionSection(accountID: accountID)
                EncryptionDevicesSection(accountID: accountID, jid: account.jid, title: "My Other Devices", isOwnAccount: true)

                Section("Connection") {
                    TextField("Host (default: DNS lookup)", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $port).keyboardType(.numberPad)
                    Toggle("Direct TLS", isOn: $directTLS)
                    SecureField("New password", text: $password)
                    Button("Save and Reconnect") { Task { await save(account) } }
                }

                Section("Blocked") {
                    if blocked.isEmpty { Text("Nobody").foregroundStyle(.secondary) }
                    ForEach(blocked, id: \.self) { jid in
                        HStack {
                            Text(jid)
                            Spacer()
                            Button("Unblock") {
                                Task {
                                    do { try await app.manager.session(for: accountID)?.setBlocked(jid, false) }
                                    catch { errorMessage = String(describing: error) }
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                Section {
                    Button("Remove Account", role: .destructive) { confirmingRemove = true }
                } footer: {
                    Text("Signs out and deletes this account's messages from this device. The account itself and its server history are kept.")
                }
            }
            .themedCells()
        }
        .themed()
        .navigationTitle(account.jid)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            host = account.host ?? ""
            port = account.port.map(String.init) ?? ""
            directTLS = account.directTLS
        }
        .confirmationDialog("Remove \(account.jid)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove Account", role: .destructive) {
                Task {
                    dismiss()
                    await app.manager.removeAccount(accountID)
                }
            }
        }
        .sheet(isPresented: $showingQR) {
            if let jid = try? JID(account.jid) {
                QRCodeSheet(title: "My Address", uri: XMPPURI(jid: jid, action: .roster(name: nil)))
            }
        }
        .alert("Couldn't Complete", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        .observing({ app.database.blocked(accountID: accountID) }, id: accountID, into: $blocked)
    }

    private func save(_ account: Account) async {
        var updated = account
        updated.host = host.trimmingCharacters(in: .whitespaces).isEmpty ? nil : host.trimmingCharacters(in: .whitespaces)
        updated.port = Int(port)
        updated.directTLS = directTLS
        do {
            try await app.manager.update(updated, password: password.isEmpty ? nil : password)
            password = ""
        } catch {
            errorMessage = String(describing: error)
        }
    }
}

private extension PushStatus {
    var label: String {
        switch self {
        case .unavailable: String(localized: "Not registered")
        case .unsupported: String(localized: "Server has no push support")
        case .enabled: String(localized: "On")
        case .failed(let reason): String(localized: "Failed: \(reason)")
        }
    }
}
