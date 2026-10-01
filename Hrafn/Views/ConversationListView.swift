import SwiftUI
import HrafnServices
import HrafnStore
import XMPPCore

struct ConversationListView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var summaries: [ConversationSummary] = []
    @State private var invitations: [RoomInvitation] = []
    @State private var summariesLoaded = false
    @State private var invitationsLoaded = false
    @State private var showingNewChat = false
    @State private var query = ""
    @State private var found: [StoredMessage] = []
    /// Accounts whose sections are folded, by id, one per line; kept across launches.
    @AppStorage("collapsedAccounts") private var collapsedAccounts = ""

    var body: some View {
        @Bindable var app = app
        Group {
            if sizeClass == .regular {
                // iPad and large iPhones in landscape: the list beside the chat.
                NavigationSplitView {
                    list
                } detail: {
                    if let route = app.chatPath.first {
                        NavigationStack {
                            ChatView(route: route).id(route)
                        }
                    } else {
                        ContentUnavailableView("No Chat Selected", systemImage: "bubble.left.and.bubble.right",
                                               description: Text("Choose a conversation from the list."))
                    }
                }
            } else {
                NavigationStack(path: $app.chatPath) {
                    list.navigationDestination(for: ChatRoute.self) { route in
                        ChatView(route: route)
                    }
                }
            }
        }
        .sheet(isPresented: $showingNewChat) {
            NewChatView()
        }
        .sheet(item: $app.pendingJoin) { link in JoinRoomView(address: link.room) }
        .observing({ app.database.conversations() }, id: app.manager.accounts.count, into: $summaries,
                   isLoaded: $summariesLoaded)
        .observing({ app.database.invitations() }, id: app.manager.accounts.count, into: $invitations,
                   isLoaded: $invitationsLoaded)
        .task(id: query) {
            // Typing: wait for a pause before searching.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            found = (try? app.database.searchMessages(query)) ?? []
        }
    }

    /// The selected chat, for the split view's list. The stack's path holds
    /// the same route, so `openChat` works in either layout.
    private var selection: Binding<ChatRoute?> {
        Binding(get: { app.chatPath.first }, set: { app.chatPath = $0.map { [$0] } ?? [] })
    }

    private var isLoadingThreads: Bool { !summariesLoaded || !invitationsLoaded }

    private var list: some View {
        List(selection: sizeClass == .regular ? selection : nil) {
            if query.isEmpty {
                conversations
            } else {
                searchResults
            }
        }
        .themed()
        .listStyle(.plain)
        .searchable(text: $query, prompt: "Chats and messages")
        .overlay {
            if query.isEmpty && !isLoadingThreads && summaries.isEmpty && invitations.isEmpty {
                ContentUnavailableView {
                    Label("No Conversations", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Start a chat with one of your contacts.")
                } actions: {
                    Button("New Chat") { showingNewChat = true }
                }
            } else if !query.isEmpty && matchingSummaries.isEmpty && found.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .safeAreaInset(edge: .top) { ConnectionBanner() }
        .navigationTitle("Chats")
        .toolbar {
            // One account has no section header to carry its dot.
            if let only = app.manager.accounts.first, app.manager.accounts.count == 1, only.enabled,
               app.manager.status(for: only.id).connection.isConnecting {
                ToolbarItem(placement: .topBarLeading) {
                    ProgressView()
                        .accessibilityLabel(app.manager.status(for: only.id).connection.label)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showingNewChat = true } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
            }
        }
    }

    @ViewBuilder
    private var conversations: some View {
        if isLoadingThreads {
            Section {
                ForEach(0..<4, id: \.self) { _ in ConversationLoadingRow() }
                    .themedRow()
            }
        } else if !invitations.isEmpty {
            Section("Invitations") {
                ForEach(invitations) { InvitationRow(invitation: $0) }
                    .themedRow()
            }
        }
        if !isLoadingThreads && app.manager.accounts.count > 1 {
            // Several accounts: a section each, in the order they were added.
            ForEach(app.manager.accounts) { account in
                let chats = summaries.filter { $0.conversation.accountID == account.id }
                if !chats.isEmpty {
                    let expanded = !collapsed.contains(account.id)
                    Section {
                        if expanded {
                            ForEach(chats) { conversationLink($0, showsAccount: false) }
                                .themedRow()
                        }
                    } header: {
                        AccountSectionHeader(jid: account.jid,
                                             connection: account.enabled ? app.manager.status(for: account.id).connection : nil,
                                             isExpanded: expanded,
                                             unread: chats.reduce(0) { $0 + $1.conversation.unreadCount }) {
                            toggle(account.id)
                        }
                    }
                }
            }
        } else if !isLoadingThreads {
            ForEach(summaries) { conversationLink($0) }
                .themedRow()
        }
    }

    private var collapsed: Set<String> {
        Set(collapsedAccounts.split(separator: "\n").map(String.init))
    }

    private func toggle(_ accountID: String) {
        var ids = collapsed
        if ids.contains(accountID) { ids.remove(accountID) } else { ids.insert(accountID) }
        withAnimation { collapsedAccounts = ids.sorted().joined(separator: "\n") }
    }

    private func conversationLink(_ summary: ConversationSummary, showsAccount: Bool = true) -> some View {
        let route = ChatRoute(accountID: summary.conversation.accountID, peer: summary.conversation.peer)
        return NavigationLink(value: route) {
            ConversationRow(summary: summary, showsAccount: showsAccount)
        }
        .tag(route)
        .swipeActions {
            Button(summary.isRoom ? "Leave" : "Delete", role: .destructive) {
                delete(summary)
            }
        }
    }

    // MARK: Search

    private var matchingSummaries: [ConversationSummary] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return [] }
        return summaries.filter {
            $0.title.localizedStandardContains(text) || $0.conversation.peer.localizedStandardContains(text)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let chats = matchingSummaries
        if !chats.isEmpty {
            Section("Chats") {
                ForEach(chats) { summary in
                    let route = ChatRoute(accountID: summary.conversation.accountID, peer: summary.conversation.peer)
                    NavigationLink(value: route) { ConversationRow(summary: summary) }
                        .tag(route)
                }
                .themedRow()
            }
        }
        if !found.isEmpty {
            Section("Messages") {
                let titles = Dictionary(summaries.map { ("\($0.conversation.accountID) \($0.conversation.peer)", $0) },
                                        uniquingKeysWith: { first, _ in first })
                ForEach(found) { message in
                    let route = ChatRoute(accountID: message.accountID, peer: message.peer, focus: message.id)
                    NavigationLink(value: route) {
                        SearchResultRow(message: message, summary: titles["\(message.accountID) \(message.peer)"])
                    }
                    .tag(route)
                }
                .themedRow()
            }
        }
    }

    /// A room is left (bookmark removed on every device) and forgotten; a
    /// chat just loses its local history.
    private func delete(_ summary: ConversationSummary) {
        let (accountID, peer) = (summary.conversation.accountID, summary.conversation.peer)
        guard summary.isRoom else {
            try? app.manager.deleteConversation(accountID: accountID, peer: peer)
            return
        }
        let session = app.manager.session(for: accountID)
        let database = app.database
        Task {
            try? await session?.leaveRoom(peer)
            try? database.deleteRoom(accountID: accountID, jid: peer)
        }
    }
}

/// An account's section header: tap to fold or unfold its chats. Folded, it
/// still shows how many messages are unread.
private struct AccountSectionHeader: View {
    @Environment(\.onAccent) private var onAccent
    let jid: String
    /// Nil when the account is disabled.
    let connection: ConnectionStatus?
    let isExpanded: Bool
    let unread: Int
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                if let connection { ConnectionDot(status: connection) }
                Text(jid).lineLimit(1)
                Spacer()
                if !isExpanded, unread > 0 {
                    Text("\(unread)")
                        .font(.caption.bold())
                        .foregroundStyle(onAccent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.tint))
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(connection.map { "\(jid), \($0.label)" } ?? jid)
        .accessibilityValue(isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed, \(unread) unread"))
        .accessibilityHint(isExpanded ? String(localized: "Hides this account's chats") : String(localized: "Shows this account's chats"))
    }
}

/// A message found by search: where it is, who wrote it, when.
private struct SearchResultRow: View {
    @Environment(AppModel.self) private var app
    let message: StoredMessage
    let summary: ConversationSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(summary?.title ?? message.peer)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(message.timestamp, format: .dateTime.day().month(.abbreviated).year())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Group {
                if message.isOutgoing {
                    Text("You: ") + Text(message.body)
                } else if let nick = message.senderNick {
                    Text("\(nick): ").bold() + Text(message.body)
                } else {
                    Text(message.body)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            if let label = app.accountLabel(message.accountID) {
                Text(label).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct ConversationRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.onAccent) private var onAccent
    let summary: ConversationSummary
    /// Off when the list is already in sections by account.
    var showsAccount = true

    var body: some View {
        let status = app.manager.status(for: summary.conversation.accountID)
        let peer = summary.conversation.peer
        let isSelf = app.isSelf(accountID: summary.conversation.accountID, peer: peer)
        HStack(spacing: 12) {
            if isSelf {
                Avatar(name: summary.title, symbol: "bookmark.fill", colorKey: peer)
            } else {
                Avatar(name: summary.title, availability: summary.isRoom ? nil : status.availability(of: peer),
                       isGroup: summary.isRoom, image: app.avatarURL(summary.profile), colorKey: peer)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(isSelf ? String(localized: "Note to Self") : summary.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    if let date = summary.lastMessage?.timestamp {
                        Text(date, format: date.formatted)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .top) {
                    preview(status: status, peer: peer)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    if summary.isRoom, summary.conversation.unreadCount > 0, summary.lastMessage?.mentionsMe == true {
                        Text("@").font(.caption.bold()).foregroundStyle(.tint)
                            .accessibilityLabel("Mentions you")
                    }
                    if summary.conversation.unreadCount > 0 {
                        Text("\(summary.conversation.unreadCount)")
                            .font(.caption.bold())
                            .foregroundStyle(onAccent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.tint))
                            .accessibilityLabel("\(summary.conversation.unreadCount) unread")
                    }
                }
                if showsAccount, let label = app.accountLabel(summary.conversation.accountID) {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func preview(status: AccountStatus, peer: String) -> some View {
        if status.typing[peer] == .composing {
            Text("typing…").italic()
        } else if let draft = summary.conversation.draft {
            Text("Draft: ").foregroundStyle(.red) + Text(draft)
        } else if let message = summary.lastMessage {
            if message.isRetracted {
                Text("Message retracted").italic()
            } else if message.isOutgoing {
                Text("You: ") + Text(message.preview)
            } else if let nick = message.senderNick {
                Text("\(nick): ").bold() + Text(message.preview)
            } else {
                Text(message.preview)
            }
        } else {
            Text(verbatim: " ")
        }
    }
}

/// A placeholder while the local conversation and invitation observations
/// produce their first values. Keeps a cold dashboard from looking empty.
private struct ConversationLoadingRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.quaternary)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(width: 132, height: 12)
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(maxWidth: 210)
                    .frame(height: 10)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading conversations")
    }
}

private extension Date {
    /// Time today, weekday this week, date before that.
    var formatted: Date.FormatStyle {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return .dateTime.hour().minute() }
        if let days = calendar.dateComponents([.day], from: self, to: .now).day, days < 7 {
            return .dateTime.weekday(.abbreviated)
        }
        return .dateTime.day().month(.abbreviated)
    }
}

/// Pick a contact, or type an address, to start a conversation.
struct NewChatView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var accountID = ""
    @State private var address = ""
    @State private var contacts: [Contact] = []
    @State private var showingJoin = false
    @State private var showingCreate = false

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        Button { showingCreate = true } label: { Label("New Group", systemImage: "person.3") }
                            .accessibilityIdentifier("newChat.createRoom")
                        Button { showingJoin = true } label: {
                            Label("Join Group Chat", systemImage: "rectangle.stack.badge.person.crop")
                        }
                        .accessibilityIdentifier("newChat.joinRoom")
                    }
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
                            .onSubmit(openTyped)
                            .accessibilityIdentifier("newChat.address")
                        Button("Open Chat", action: openTyped)
                            .accessibilityIdentifier("newChat.open")
                            .disabled(!address.contains("@"))
                    } header: {
                        Text("Address")
                    }
                    Section("Contacts") {
                        ForEach(contacts.filter(\.inRoster), id: \.jid) { contact in
                            Button {
                                open(contact.jid)
                            } label: {
                                HStack {
                                    Avatar(name: contact.displayName, size: 32, colorKey: contact.jid)
                                    VStack(alignment: .leading) {
                                        Text(contact.displayName).foregroundStyle(.primary)
                                        if contact.name != nil {
                                            Text(contact.jid).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .themedCells()
            }
            .themed()
            .navigationTitle("New Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear { if accountID.isEmpty { accountID = app.manager.accounts.first?.id ?? "" } }
            .observing({ app.database.contacts(accountID: accountID) }, id: accountID, into: $contacts)
            .sheet(isPresented: $showingJoin, onDismiss: dismissIfOpened) { JoinRoomView() }
            .sheet(isPresented: $showingCreate, onDismiss: dismissIfOpened) { CreateRoomView() }
        }
    }

    /// The join and create sheets open the new room's chat; close this too.
    private func dismissIfOpened() {
        if !app.chatPath.isEmpty { dismiss() }
    }

    private func openTyped() {
        // PRECIS-normalised, so "Romeo@Example.net" opens the same chat.
        guard let jid = try? JID(address.trimmingCharacters(in: .whitespaces)), jid.localpart != nil else { return }
        open(jid.bare.description)
    }

    private func open(_ peer: String) {
        guard !accountID.isEmpty else { return }
        dismiss()
        app.openChat(accountID: accountID, peer: peer)
    }
}
