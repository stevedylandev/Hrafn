import SwiftUI
import HrafnServices
import HrafnStore
import XMPPClient
import XMPPCore
import XMPPIM

/// An account picker for forms, shown only with more than one account.
private struct AccountPicker: View {
    @Environment(AppModel.self) private var app
    @Binding var accountID: String

    var body: some View {
        if app.manager.accounts.count > 1 {
            Picker("Account", selection: $accountID) {
                ForEach(app.manager.accounts) { Text($0.jid).tag($0.id) }
            }
        }
    }
}

private extension View {
    func errorAlert(_ message: Binding<String?>) -> some View {
        alert("Couldn't Complete", isPresented: Binding(get: { message.wrappedValue != nil },
                                                        set: { if !$0 { message.wrappedValue = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}

// MARK: - Join

/// Join an existing room by address.
struct JoinRoomView: View {
    var address = ""

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var accountID = ""
    @State private var room = ""
    @State private var nick = ""
    @State private var password = ""
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    AccountPicker(accountID: $accountID)
                    Section {
                        TextField("room@conference.example.com", text: $room)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("joinRoom.address")
                    } header: {
                        Text("Address")
                    }
                    Section {
                        TextField("Nickname (optional)", text: $nick)
                            .textInputAutocapitalization(.never)
                        SecureField("Password (if the room has one)", text: $password)
                    }
                }
                .themedCells()
            }
            .themed()
            .navigationTitle("Join Group Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Join") { Task { await join() } }
                            .disabled(!room.contains("@"))
                            .accessibilityIdentifier("joinRoom.join")
                    }
                }
            }
            .onAppear {
                if accountID.isEmpty { accountID = app.manager.accounts.first?.id ?? "" }
                if room.isEmpty { room = address }
            }
            .errorAlert($errorMessage)
        }
    }

    private func join() async {
        guard let session = app.manager.session(for: accountID) else {
            errorMessage = String(localized: "The account is not connected.")
            return
        }
        working = true
        defer { working = false }
        do {
            let jid = try JID(room.trimmingCharacters(in: .whitespaces)).bare.description
            try await session.joinRoom(jid, nick: nick.isEmpty ? nil : nick, password: password.isEmpty ? nil : password)
            dismiss()
            app.openChat(accountID: accountID, peer: jid)
        } catch {
            errorMessage = String(describing: error)
        }
    }
}

// MARK: - Create

/// A new room: a private group (members only, like a group of contacts) or a
/// public channel.
struct CreateRoomView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var accountID = ""
    @State private var name = ""
    @State private var kind = RoomKind.privateGroup
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    AccountPicker(accountID: $accountID)
                    Section {
                        TextField("Name", text: $name)
                            .accessibilityIdentifier("createRoom.name")
                    }
                    Section {
                        Picker("Kind", selection: $kind) {
                            Text("Private Group").tag(RoomKind.privateGroup)
                            Text("Public Channel").tag(RoomKind.channel)
                        }
                        .pickerStyle(.segmented)
                    } footer: {
                        Text(kind == .privateGroup
                             ? "Only people you invite can join, and members see each other's addresses."
                             : "Anyone can find and join the channel. Addresses are only visible to moderators.")
                    }
                }
                .themedCells()
            }
            .themed()
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Create") { Task { await create() } }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityIdentifier("createRoom.create")
                    }
                }
            }
            .onAppear { if accountID.isEmpty { accountID = app.manager.accounts.first?.id ?? "" } }
            .errorAlert($errorMessage)
        }
    }

    private func create() async {
        guard let session = app.manager.session(for: accountID) else {
            errorMessage = String(localized: "The account is not connected.")
            return
        }
        working = true
        defer { working = false }
        do {
            let room = try await session.createRoom(name: name.trimmingCharacters(in: .whitespaces), kind: kind)
            dismiss()
            app.openChat(accountID: accountID, peer: room)
        } catch {
            errorMessage = String(describing: error)
        }
    }
}

// MARK: - Invitations

/// Pending invitations, above the conversation list.
struct InvitationRow: View {
    let invitation: RoomInvitation

    @Environment(AppModel.self) private var app
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: invitation.room, isGroup: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(invitation.room).font(.headline).lineLimit(1)
                Text(invitation.inviter.map { String(localized: "Invited by \($0)") } ?? String(localized: "Invitation"))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if let reason = invitation.reason {
                    Text(reason).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                if let label = app.accountLabel(invitation.accountID) {
                    Text(label).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if working {
                ProgressView()
            } else {
                Button("Join") { Task { await accept() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("invitation.join")
                Button {
                    try? app.database.deleteInvitation(accountID: invitation.accountID, room: invitation.room)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Decline")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .errorAlert($errorMessage)
    }

    private func accept() async {
        guard let session = app.manager.session(for: invitation.accountID) else {
            errorMessage = String(localized: "The account is not connected.")
            return
        }
        working = true
        defer { working = false }
        do {
            try await session.acceptInvitation(invitation.room)
            app.openChat(accountID: invitation.accountID, peer: invitation.room)
        } catch {
            errorMessage = String(describing: error)
        }
    }
}

// MARK: - Details

struct RoomDetailView: View {
    let accountID: String
    let jid: String

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var room: Room?
    @State private var profiles: [String: Profile] = [:]
    @State private var editingNick = false
    @State private var newNick = ""
    @State private var editingSubject = false
    @State private var newSubject = ""
    @State private var showingInvite = false
    @State private var showingConfig = false
    @State private var confirmingLeave = false
    @State private var confirmingDestroy = false
    @State private var errorMessage: String?
    /// A member whose OMEMO devices are shown (private groups).
    @State private var devicesOf: String?
    /// The participant list starts folded away: a big room's would bury the
    /// actions below it.
    @State private var showingParticipants = false

    private var session: AccountSession? { app.manager.session(for: accountID) }
    private var status: RoomStatus { app.manager.status(for: accountID).room(jid) }

    var body: some View {
        List {
            Group {
                Section {
                    VStack(spacing: 8) {
                        Avatar(name: room?.displayName ?? jid, size: 80, isGroup: true)
                        Text(room?.displayName ?? jid).font(.title2.bold())
                        Text(jid).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(status.summary).font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                Section("Subject") {
                    Text(room?.subject ?? "No subject").foregroundStyle(room?.subject == nil ? .secondary : .primary)
                    if status.isJoined {
                        Button("Change Subject") {
                            newSubject = room?.subject ?? ""
                            editingSubject = true
                        }
                    }
                }

                Section("Notifications") {
                    Picker("Notify", selection: Binding(
                        get: { room?.notify },
                        set: { level in act { try app.manager.setRoomNotify(accountID: accountID, room: jid, level) } })) {
                        Text("Default (\(defaultNotify.label))").tag(RoomNotify?.none)
                        ForEach(RoomNotify.allCases, id: \.self) { Text($0.label).tag(RoomNotify?.some($0)) }
                    }
                    .accessibilityIdentifier("room.notify")
                }

                Section("You") {
                    LabeledContent("Nickname", value: status.nick ?? room?.nick ?? "—")
                    if status.isJoined {
                        LabeledContent("Role", value: status.role.label)
                        LabeledContent("Affiliation", value: status.affiliation.label)
                        Button("Change Nickname") {
                            newNick = status.nick ?? ""
                            editingNick = true
                        }
                    }
                }

                if status.isJoined {
                    Section {
                        if showingParticipants {
                            ForEach(status.occupants) { occupant in
                                OccupantRow(occupant: occupant, image: occupantAvatar(occupant))
                                    .contextMenu { moderation(for: occupant) }
                            }
                        }
                    } header: {
                        HStack {
                            Text("Participants (\(status.occupants.count))")
                            Spacer()
                            Button(showingParticipants ? "Hide" : "Show") {
                                withAnimation { showingParticipants.toggle() }
                            }
                            .font(.footnote)
                            .textCase(nil)
                            .accessibilityIdentifier("room.participants.toggle")
                        }
                    }
                }

                Section {
                    if status.isJoined {
                        Button { showingInvite = true } label: { Label("Invite…", systemImage: "person.badge.plus") }
                    }
                    if status.isOwner {
                        Button { showingConfig = true } label: { Label("Configure…", systemImage: "gearshape") }
                    }
                    if case .notJoined = status.state {
                        Button {
                            act { try await session?.rejoinRoom(jid) }
                        } label: { Label("Join Again", systemImage: "arrow.clockwise") }
                    }
                    Button(role: .destructive) { confirmingLeave = true } label: {
                        Label("Leave", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .accessibilityIdentifier("room.leave")
                    if status.isOwner {
                        Button(role: .destructive) { confirmingDestroy = true } label: {
                            Label("Destroy Room", systemImage: "trash")
                        }
                    }
                }
            }
            .themedCells()
        }
        .themed()
        .navigationTitle("Group Info")
        .navigationBarTitleDisplayMode(.inline)
        .observing({ app.database.room(accountID: accountID, jid: jid) }, id: jid, into: $room)
        .observing({ app.database.profiles(accountID: accountID) }, id: accountID, into: $profiles)
        .alert("Nickname", isPresented: $editingNick) {
            TextField("Nickname", text: $newNick)
            Button("Cancel", role: .cancel) {}
            Button("Change") { act { try await session?.changeNick(in: jid, to: newNick) } }
        }
        .alert("Subject", isPresented: $editingSubject) {
            TextField("Subject", text: $newSubject)
            Button("Cancel", role: .cancel) {}
            Button("Set") { act { try await session?.setSubject(newSubject, in: jid) } }
        }
        .confirmationDialog("Leave \(room?.displayName ?? jid)?", isPresented: $confirmingLeave, titleVisibility: .visible) {
            Button("Leave", role: .destructive) {
                act {
                    try await session?.leaveRoom(jid)
                    dismiss()
                }
            }
            Button("Leave and Delete History", role: .destructive) {
                act {
                    try await session?.leaveRoom(jid)
                    try app.database.deleteRoom(accountID: accountID, jid: jid)
                    app.chatPath.removeAll()
                }
            }
        } message: {
            Text("Your other devices will leave too.")
        }
        .confirmationDialog("Destroy \(room?.displayName ?? jid) for everyone?", isPresented: $confirmingDestroy,
                            titleVisibility: .visible) {
            Button("Destroy", role: .destructive) {
                act {
                    try await session?.destroyRoom(jid)
                    app.chatPath.removeAll()
                }
            }
        } message: {
            Text("Everyone is removed and the room's history is gone.")
        }
        .sheet(isPresented: $showingInvite) { InviteContactView(accountID: accountID, room: jid) }
        .sheet(isPresented: $showingConfig) {
            NavigationStack { RoomConfigView(accountID: accountID, room: jid) }
        }
        .sheet(isPresented: Binding(get: { devicesOf != nil }, set: { if !$0 { devicesOf = nil } })) {
            if let member = devicesOf {
                NavigationStack {
                    List { EncryptionDevicesSection(accountID: accountID, jid: member, title: "Encryption").themedCells() }
                        .themed()
                        .navigationTitle(member)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { devicesOf = nil } } }
                }
            }
        }
        .errorAlert($errorMessage)
    }

    private var defaultNotify: RoomNotify {
        var probe = room ?? Room(accountID: accountID, jid: jid)
        probe.notify = nil
        return probe.effectiveNotify
    }

    @ViewBuilder
    private func moderation(for occupant: RoomOccupantStatus) -> some View {
        if occupant.nick != status.nick {
            Button {
                dismiss()
                app.openChat(accountID: accountID, peer: "\(jid)/\(occupant.nick)")
            } label: { Label("Message Privately", systemImage: "bubble.left") }
            if room?.isPrivateGroup == true, let real = occupant.jid {
                Button { devicesOf = real } label: { Label("Encryption Devices", systemImage: "lock.shield") }
            }
            if status.isModerator, occupant.role != .moderator || status.isAdmin {
                Button(role: .destructive) {
                    act { try await session?.setRole(.none, of: occupant.nick, in: jid) }
                } label: { Label("Kick", systemImage: "figure.walk.departure") }
            }
            if status.isAdmin, let real = occupant.jid {
                if occupant.affiliation == .none {
                    Button {
                        act { try await session?.setAffiliation(.member, of: real, in: jid) }
                    } label: { Label("Make Member", systemImage: "person.crop.circle.badge.checkmark") }
                }
                if occupant.affiliation != .owner {
                    Button(role: .destructive) {
                        act { try await session?.setAffiliation(.outcast, of: real, in: jid) }
                    } label: { Label("Ban", systemImage: "hand.raised") }
                }
            }
        }
    }

    /// The occupant's own avatar when we know who they are, else the photo
    /// their room presence advertised (kept under the occupant JID).
    private func occupantAvatar(_ occupant: RoomOccupantStatus) -> URL? {
        occupant.jid.flatMap { app.avatarURL(profiles[$0]) } ?? app.avatarURL(profiles["\(jid)/\(occupant.nick)"])
    }

    private func act(_ work: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await work() } catch { errorMessage = String(describing: error) }
        }
    }
}

private struct OccupantRow: View {
    let occupant: RoomOccupantStatus
    var image: URL?

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: occupant.nick, size: 32, availability: occupant.availability, image: image)
            VStack(alignment: .leading) {
                Text(occupant.nick)
                if let jid = occupant.jid {
                    Text(jid).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if occupant.affiliation == .owner || occupant.affiliation == .admin {
                Text(occupant.affiliation.label).font(.caption).foregroundStyle(.secondary)
            } else if occupant.role == .moderator || occupant.role == .visitor {
                Text(occupant.role.label).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Invite

struct InviteContactView: View {
    let accountID: String
    let room: String

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var contacts: [Contact] = []
    @State private var address = ""
    @State private var reason = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        TextField("name@example.com", text: $address)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Message (optional)", text: $reason)
                        Button("Invite") { invite(address) }
                            .disabled(!address.contains("@"))
                    } header: {
                        Text("Address")
                    }
                    Section("Contacts") {
                        ForEach(contacts.filter(\.inRoster), id: \.jid) { contact in
                            Button {
                                invite(contact.jid)
                            } label: {
                                HStack {
                                    Avatar(name: contact.displayName, size: 32, colorKey: contact.jid)
                                    Text(contact.displayName).foregroundStyle(.primary)
                                }
                            }
                        }
                    }
                }
                .themedCells()
            }
            .themed()
            .navigationTitle("Invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .observing({ app.database.contacts(accountID: accountID) }, id: accountID, into: $contacts)
            .errorAlert($errorMessage)
        }
    }

    private func invite(_ jid: String) {
        guard let session = app.manager.session(for: accountID) else { return }
        Task {
            do {
                try await session.invite(jid, to: room, reason: reason.isEmpty ? nil : reason)
                dismiss()
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }
}

// MARK: - Configuration

/// The room's XEP-0004 configuration form, rendered field by field.
struct RoomConfigView: View {
    let accountID: String
    let room: String

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var form: DataForm?
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let form {
                Form {
                    Group {
                        if let title = form.title { Section { Text(title).font(.headline) } }
                        ForEach(sections(of: form), id: \.first) { indices in
                            Section {
                                ForEach(indices.dropFirst(indices.first.map { form.fields[$0].type == "fixed" } == true ? 1 : 0),
                                        id: \.self) { index in
                                    FieldView(field: binding(index))
                                }
                            } header: {
                                if let first = indices.first, form.fields[first].type == "fixed" {
                                    Text(form.fields[first].values.first ?? "")
                                }
                            }
                        }
                    }
                    .themedCells()
                }
                .themed()
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Configure")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else { Button("Save") { Task { await save() } }.disabled(form == nil) }
            }
        }
        .task {
            guard form == nil else { return }
            do {
                form = try await app.manager.session(for: accountID)?.roomConfiguration(room)
            } catch {
                errorMessage = String(describing: error)
            }
        }
        .errorAlert($errorMessage)
    }

    /// Field indices grouped at each `fixed` field (servers use them as
    /// section titles); hidden fields left out.
    private func sections(of form: DataForm) -> [[Int]] {
        var sections: [[Int]] = [[]]
        for (index, field) in form.fields.enumerated() where field.type != "hidden" {
            if field.type == "fixed", !(sections.last?.isEmpty ?? true) { sections.append([]) }
            sections[sections.count - 1].append(index)
        }
        return sections.filter { !$0.isEmpty }
    }

    private func binding(_ index: Int) -> Binding<DataForm.Field> {
        Binding(get: { form!.fields[index] }, set: { form!.fields[index] = $0 })
    }

    private func save() async {
        guard let form, let session = app.manager.session(for: accountID) else { return }
        saving = true
        defer { saving = false }
        do {
            try await session.configureRoom(room, form: form)
            dismiss()
        } catch {
            errorMessage = String(describing: error)
        }
    }
}

private struct FieldView: View {
    @Binding var field: DataForm.Field

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            control
            if let description = field.description {
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var label: String { field.label ?? field.variable ?? "" }

    private var single: Binding<String> {
        Binding(get: { field.values.first ?? "" }, set: { field.values = [$0] })
    }

    @ViewBuilder
    private var control: some View {
        switch field.type {
        case "boolean":
            Toggle(label, isOn: $field.boolValue)
        case "text-private":
            SecureField(label, text: single)
        case "text-multi", "jid-multi":
            VStack(alignment: .leading) {
                Text(label).font(.subheadline)
                TextField(label, text: Binding(get: { field.values.joined(separator: "\n") },
                                               set: { field.values = $0.split(separator: "\n").map(String.init) }),
                          axis: .vertical)
                    .lineLimit(2...6)
            }
        case "list-single":
            Picker(label, selection: single) {
                ForEach(field.options, id: \.value) { Text($0.label ?? $0.value).tag($0.value) }
            }
        case "list-multi":
            VStack(alignment: .leading) {
                Text(label).font(.subheadline)
                ForEach(field.options, id: \.value) { option in
                    Toggle(option.label ?? option.value, isOn: Binding(
                        get: { field.values.contains(option.value) },
                        set: { on in
                            field.values.removeAll { $0 == option.value }
                            if on { field.values.append(option.value) }
                        }))
                }
            }
        default:
            // text-single, jid-single and anything unknown.
            LabeledContent(label) {
                TextField(label, text: single)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
            }
        }
    }
}
