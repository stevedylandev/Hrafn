import SwiftUI
import HrafnServices
import HrafnStore
import XMPPCore
import XMPPIM

struct ContactListView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showingAdd = false
    /// The contact shown beside the list in regular width.
    @State private var selection: ContactRoute?

    var body: some View {
        @Bindable var app = app
        Group {
            if sizeClass == .regular {
                // iPad: the list beside the selected contact.
                NavigationSplitView {
                    list
                } detail: {
                    if let selection {
                        NavigationStack {
                            ContactDetailView(accountID: selection.accountID, jid: selection.jid).id(selection)
                        }
                    } else {
                        ContentUnavailableView("No Contact Selected", systemImage: "person.2",
                                               description: Text("Choose a contact from the list."))
                    }
                }
            } else {
                NavigationStack {
                    list.navigationDestination(for: ContactRoute.self) { route in
                        ContactDetailView(accountID: route.accountID, jid: route.jid)
                    }
                }
            }
        }
        .sheet(isPresented: $showingAdd) { AddContactView() }
        .sheet(item: $app.pendingContact) { uri in AddContactView(uri: uri) }
    }

    private var list: some View {
        List(selection: sizeClass == .regular ? $selection : nil) {
            ForEach(app.manager.accounts) { account in
                AccountContactsSection(account: account, showsAccount: app.manager.accounts.count > 1)
            }
        }
        .themed()
        .navigationTitle("Contacts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingAdd = true } label: { Label("Add Contact", systemImage: "person.badge.plus") }
            }
        }
    }
}

struct ContactRoute: Hashable {
    let accountID: String
    let jid: String
}

extension XMPPURI: @retroactive Identifiable {
    public var id: String { description }
}

private struct AccountContactsSection: View {
    let account: Account
    let showsAccount: Bool

    @Environment(AppModel.self) private var app
    @State private var contacts: [Contact] = []
    @State private var profiles: [String: Profile] = [:]
    @State private var errorMessage: String?

    var body: some View {
        let requests = contacts.filter(\.pendingIn)
        let roster = contacts.filter { $0.inRoster && !$0.pendingIn }
        let status = app.manager.status(for: account.id)

        Group {
            if !requests.isEmpty {
                Section(showsAccount ? "Requests · \(account.jid)" : "Requests") {
                    ForEach(requests, id: \.jid) { contact in
                        RequestRow(contact: contact) { approve in
                            await answer(contact, approve: approve)
                        }
                    }
                    .themedRow()
                }
            }
            Section {
                if roster.isEmpty {
                    Text("No contacts yet").foregroundStyle(.secondary).themedRow()
                }
                ForEach(roster.sorted { status.availability(of: $0.jid) < status.availability(of: $1.jid) }, id: \.jid) { contact in
                    let route = ContactRoute(accountID: account.id, jid: contact.jid)
                    NavigationLink(value: route) {
                        ContactRow(contact: contact, status: status, profile: profiles[contact.jid])
                    }
                    .tag(route)
                }
                .themedRow()
            } header: {
                if showsAccount { Text(account.jid) }
            }
        }
        .alert("Couldn't Complete", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        .observing({ app.database.contacts(accountID: account.id) }, id: account.id, into: $contacts)
        .observing({ app.database.profiles(accountID: account.id) }, id: account.id, into: $profiles)
    }

    private func answer(_ contact: Contact, approve: Bool) async {
        do {
            try await app.manager.session(for: account.id)?.answerSubscription(from: contact.jid, approve: approve)
        } catch {
            errorMessage = String(describing: error)
        }
    }
}

private struct ContactRow: View {
    let contact: Contact
    let status: AccountStatus
    let profile: Profile?
    @Environment(AppModel.self) private var app

    var body: some View {
        let name = contact.name ?? profile?.nickname ?? contact.jid
        HStack(spacing: 12) {
            Avatar(name: name, size: 40, availability: status.availability(of: contact.jid),
                   image: app.avatarURL(profile), colorKey: contact.jid)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Group {
                    if contact.pendingOut {
                        Text("Request sent")
                    } else if let message = status.statusMessages[contact.jid] {
                        Text(message)
                    } else if name != contact.jid {
                        Text(contact.jid)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }
}

private struct RequestRow: View {
    let contact: Contact
    let answer: (Bool) async -> Void
    @State private var isWorking = false

    var body: some View {
        HStack {
            Avatar(name: contact.displayName, size: 40, colorKey: contact.jid)
            VStack(alignment: .leading) {
                Text(contact.displayName)
                Text("Wants to see your status").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isWorking {
                ProgressView()
            } else {
                Button { run(false) } label: { Image(systemName: "xmark.circle") }
                    .tint(.red)
                    .accessibilityLabel("Decline")
                Button { run(true) } label: { Image(systemName: "checkmark.circle.fill") }
                    .tint(.green)
                    .accessibilityLabel("Accept")
            }
        }
        .buttonStyle(.borderless)
        .font(.title2)
    }

    private func run(_ approve: Bool) {
        isWorking = true
        Task {
            await answer(approve)
            isWorking = false
        }
    }
}

/// Add by address, `xmpp:` link or QR code.
struct AddContactView: View {
    var uri: XMPPURI?

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var accountID = ""
    @State private var address = ""
    @State private var name = ""
    @State private var showingScanner = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    if app.manager.accounts.count > 1 {
                        Picker("Account", selection: $accountID) {
                            ForEach(app.manager.accounts) { Text($0.jid).tag($0.id) }
                        }
                    }
                    Section {
                        TextField("name@example.com", text: $address)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("addContact.address")
                        TextField("Name (optional)", text: $name)
                            .accessibilityIdentifier("addContact.name")
                        Button { showingScanner = true } label: { Label("Scan QR Code", systemImage: "qrcode.viewfinder") }
                    } footer: {
                        Text("They will be asked to share their status with you, and will see yours.")
                    }
                    if let errorMessage {
                        Section { Text(errorMessage).foregroundStyle(.red) }
                    }
                }
                .themedCells()
            }
            .themed()
            .navigationTitle("Add Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking { ProgressView() } else {
                        Button("Add") { Task { await add() } }.disabled(parsedJID == nil)
                    }
                }
            }
            .sheet(isPresented: $showingScanner) {
                QRScannerView { code in
                    showingScanner = false
                    fill(from: code)
                }
            }
            .onAppear {
                if accountID.isEmpty { accountID = app.manager.accounts.first?.id ?? "" }
                if let uri { fill(from: uri.description) }
            }
        }
    }

    /// The typed text as an address — a bare JID, or an `xmpp:` URI.
    private var parsedJID: JID? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        if let uri = XMPPURI(trimmed) { return uri.jid.bare }
        guard let jid = try? JID(trimmed), jid.localpart != nil else { return nil }
        return jid.bare
    }

    private func fill(from code: String) {
        if let uri = XMPPURI(code) {
            address = uri.jid.bare.description
            if case .roster(let rosterName?) = uri.action { name = rosterName }
        } else {
            address = code
        }
    }

    private func add() async {
        guard let jid = parsedJID, let session = app.manager.session(for: accountID) else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await session.addContact(jid.description, name: name.isEmpty ? nil : name)
            dismiss()
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
