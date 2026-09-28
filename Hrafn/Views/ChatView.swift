import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import HrafnServices
import HrafnStore

struct ChatView: View {
    let route: ChatRoute

    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var messages: [StoredMessage] = []
    @State private var contact: Contact?
    @State private var limit = 200
    @State private var text = ""
    @State private var editing: StoredMessage?
    @State private var replyingTo: StoredMessage?
    @State private var reactions: [String: [ReactionCount]] = [:]
    @State private var isLoadingOlder = false
    @State private var reachedStart = false
    @State private var errorMessage: String?
    /// XEP-0425: the message a moderator is about to remove, and why.
    @State private var moderating: StoredMessage?
    @State private var moderationReason = ""
    @State private var typingTask: Task<Void, Never>?
    @State private var showingContact = false
    @State private var muted = false
    /// OMEMO: `nil` while undecided (encrypted once the contact has devices).
    @State private var encryption: ConversationEncryption?
    /// The contact's OMEMO devices, for the new-device banner.
    @State private var devices: [OMEMODevice] = []
    @State private var room: Room?
    /// For a private conversation with a room occupant, the room.
    @State private var viaRoom: Room?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var pickingPhotos = false
    @State private var importingFiles = false
    @State private var preparing = false
    @State private var recorder = VoiceRecorder()
    /// A message to bring into view (from search), until it has been.
    @State private var pendingFocus: Int64?
    @State private var highlighted: Int64?
    /// Group chat: the nick whose address is being shown.
    @State private var inspectingSender: String?
    @State private var viewingContact: String?
    /// A public room: why it can't be encrypted.
    @State private var explainingEncryption = false
    /// The composer's round buttons follow Dynamic Type.
    @ScaledMetric(relativeTo: .title) private var buttonSize: CGFloat = 32

    private var session: AccountSession? { app.manager.session(for: route.accountID) }
    private var status: AccountStatus { app.manager.status(for: route.accountID) }
    private var title: String {
        if let (roomJID, nick) = occupant { return RoomPrivate.title(nick: nick, room: viaRoom, roomJID: roomJID) }
        return room?.displayName ?? contact?.name ?? route.peer
    }
    /// XEP-0045 §7.5: the room and nickname when talking privately to an occupant.
    private var occupant: (room: String, nick: String)? { RoomPrivate.split(route.peer) }
    private var roomStatus: RoomStatus { status.room(route.peer) }
    private var isRoom: Bool { room != nil }

    var body: some View {
        dialogs(conversation)
    }

    /// Group chat senders' addresses, and why a public room can't be
    /// encrypted. Apart from `conversation` to keep the type checker quick.
    private func dialogs(_ content: some View) -> some View {
        content
            .navigationDestination(item: $viewingContact) { jid in
                ContactDetailView(accountID: route.accountID, jid: jid)
            }
            .confirmationDialog(inspectingSender ?? "", isPresented: Binding(
                get: { inspectingSender != nil }, set: { if !$0 { inspectingSender = nil } }),
                                titleVisibility: .visible, presenting: inspectingSender) { nick in
                if let jid = address(of: nick) {
                    Button("View Contact") { viewingContact = jid }
                    Button("Copy Address") { UIPasteboard.general.string = jid }
                }
                if nick != roomStatus.nick {
                    Button("Message Privately") { app.openChat(accountID: route.accountID, peer: "\(route.peer)/\(nick)") }
                }
            } message: { nick in
                Text(address(of: nick) ?? String(localized: "This room keeps members’ addresses hidden."))
            }
            .alert("Not Encrypted", isPresented: $explainingEncryption) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Only private groups can be encrypted: members only, with members’ addresses visible to each other. An owner can change this in Group Info.")
            }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    if !reachedStart {
                        Button {
                            Task { await loadOlder() }
                        } label: {
                            if isLoadingOlder { ProgressView() } else { Text("Load earlier messages") }
                        }
                        .font(.footnote)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    let byReference = referenceIndex
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        row(index, message, original: message.replyToID.flatMap { byReference[$0] }, proxy: proxy)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)
            .themed()
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.last?.id) { _, id in
                guard pendingFocus == nil else { return }
                withAnimation { proxy.scrollTo(id, anchor: .bottom) }
            }
            // Whichever comes second: the rows, or the request to show one.
            .onChange(of: messages) { bringFocusIntoView(proxy) }
            .onChange(of: pendingFocus) { bringFocusIntoView(proxy) }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .safeAreaInset(edge: .top) {
            let waiting = devices.filter { $0.trust == .undecided && $0.isActive }.count
            if waiting > 0, !isRoom, encryption != .off {
                NewDevicesBanner(count: waiting) { showingContact = true }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .navigationDestination(isPresented: $showingContact) {
            if room != nil {
                RoomDetailView(accountID: route.accountID, jid: route.peer)
            } else if let occupant {
                RoomDetailView(accountID: route.accountID, jid: occupant.room)
            } else {
                ContactDetailView(accountID: route.accountID, jid: route.peer)
            }
        }
        .alert("Remove Message", isPresented: Binding(get: { moderating != nil }, set: { if !$0 { moderating = nil } })) {
            TextField("Reason (optional)", text: $moderationReason)
            Button("Remove", role: .destructive) { moderate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It is removed for everyone in the room, who will see that a moderator removed it.")
        }
        .alert("Couldn't Complete", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .photosPicker(isPresented: $pickingPhotos, selection: $photoItems, maxSelectionCount: 10,
                      matching: .any(of: [.images, .videos]))
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await sendPhotos(items) }
        }
        .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            Task { await sendFiles(result) }
        }
        .observing({ app.database.messages(accountID: route.accountID, peer: route.peer, limit: limit) },
                   id: limit, into: $messages)
        .observing({ app.database.contact(accountID: route.accountID, jid: route.peer) }, id: route, into: $contact)
        .observing({ app.database.isMuted(accountID: route.accountID, peer: route.peer) }, id: route, into: $muted)
        .observing({ app.database.observeConversationEncryption(accountID: route.accountID, peer: route.peer) },
                   id: route, into: $encryption)
        .observing({ app.manager.omemoDevices(accountID: route.accountID, jid: route.peer) }, id: route, into: $devices)
        .observing({ app.database.room(accountID: route.accountID, jid: route.peer) }, id: route, into: $room)
        .observing({ app.database.room(accountID: route.accountID, jid: occupant?.room ?? "") }, id: route, into: $viaRoom)
        .observing({ app.database.reactions(accountID: route.accountID, peer: route.peer) }, id: route, into: $reactions)
        .task(id: route) {
            if let focus = route.focus {
                // Load far enough back to include it.
                let newer = (try? app.database.messagesNewer(than: focus, accountID: route.accountID,
                                                              peer: route.peer)) ?? 0
                pendingFocus = focus
                limit = max(limit, newer + 30)
            }
            text = (try? app.database.conversationDraft(accountID: route.accountID, peer: route.peer)) ?? ""
            await app.manager.setVisibleConversation(accountID: route.accountID, peer: route.peer)
        }
        .onDisappear {
            let (session, manager, accountID, peer, draft) = (self.session, app.manager, route.accountID, route.peer, text)
            try? app.database.setDraft(accountID: accountID, peer: peer, draft)
            Task {
                await session?.sendChatState(.active, to: peer)
                await manager.clearVisibleConversation(accountID: accountID, peer: peer)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            let (manager, accountID, peer) = (app.manager, route.accountID, route.peer)
            Task {
                if phase == .active {
                    await manager.setVisibleConversation(accountID: accountID, peer: peer)
                } else {
                    await manager.clearVisibleConversation(accountID: accountID, peer: peer)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Button { showingContact = true } label: {
                VStack(spacing: 0) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("chat.title")
        }
        ToolbarItem(placement: .topBarTrailing) {
            if let room {
                // Notifications live in Group Info, behind the title.
                if room.isPrivateGroup {
                    encryptionMenu
                } else {
                    Button { explainingEncryption = true } label: {
                        Label("Not Encrypted", systemImage: "lock.open")
                    }
                    .accessibilityIdentifier("encryption")
                }
            } else {
                if occupant == nil { encryptionMenu }
                Button {
                    do { try app.manager.setMuted(accountID: route.accountID, peer: route.peer, !muted) }
                    catch { errorMessage = String(describing: error) }
                } label: {
                    Label(muted ? "Unmute" : "Mute", systemImage: muted ? "bell.slash" : "bell")
                }
                .accessibilityIdentifier("mute")
            }
        }
    }

    /// One message, under a day header when it starts a new day.
    @ViewBuilder
    private func row(_ index: Int, _ message: StoredMessage, original: StoredMessage?,
                     proxy: ScrollViewProxy) -> some View {
        if index == 0 || !Calendar.current.isDate(messages[index - 1].timestamp, inSameDayAs: message.timestamp) {
            Text(message.timestamp, format: .dateTime.weekday(.wide).day().month())
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
        }
        MessageBubble(message: message, accountID: route.accountID,
                      showsSender: room != nil && !message.isOutgoing
                        && (index == 0 || messages[index - 1].senderNick != message.senderNick
                            || messages[index - 1].isOutgoing),
                      showsFooter: endsRun(at: index),
                      inspectSender: room == nil ? nil : { inspectingSender = $0 },
                      quote: quote(for: message, original: original),
                      showOriginal: original.map { original in
                          { withAnimation { proxy.scrollTo(original.id, anchor: .center) } }
                      },
                      author: author(of: message),
                      reactions: message.referenceID(inRoom: isRoom).flatMap { reactions[$0] } ?? [],
                      toggleReaction: { emoji in react(emoji, to: message) })
            .id(message.id)
            .background {
                if highlighted == message.id {
                    RoundedRectangle(cornerRadius: 12).fill(.yellow.opacity(0.25))
                }
            }
            .contextMenu { menu(for: message) }
            .accessibilityActions { accessibilityActions(for: message) }
    }

    /// Scrolls to the message search asked for, once it is loaded, and
    /// highlights it briefly.
    private func bringFocusIntoView(_ proxy: ScrollViewProxy) {
        guard let focus = pendingFocus, messages.contains(where: { $0.id == focus }) else { return }
        pendingFocus = nil
        Task {
            // After the list has laid out the rows it just received.
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation { proxy.scrollTo(focus, anchor: .center) }
            highlighted = focus
            try? await Task.sleep(for: .seconds(2))
            withAnimation { if highlighted == focus { highlighted = nil } }
        }
    }

    /// Whether the message at `index` is the last of a run from one sender
    /// close together in time; only those show the time underneath.
    private func endsRun(at index: Int) -> Bool {
        let message = messages[index]
        guard index + 1 < messages.count else { return true }
        let next = messages[index + 1]
        return next.isOutgoing != message.isOutgoing || next.senderNick != message.senderNick
            || next.timestamp.timeIntervalSince(message.timestamp) > 5 * 60
            || !Calendar.current.isDate(next.timestamp, inSameDayAs: message.timestamp)
    }

    /// A room occupant's real address, when the room reveals it.
    private func address(of nick: String) -> String? {
        if let jid = roomStatus.occupants.first(where: { $0.nick == nick })?.jid { return jid }
        return messages.last { $0.senderNick == nick && $0.senderJID != nil }?.senderJID
            .map { $0.split(separator: "/").first.map(String.init) ?? $0 }
    }

    private var subtitle: String {
        if room != nil {
            guard roomStatus.isJoined else { return roomStatus.summary }
            let summary = room?.subject ?? roomStatus.summary
            return encryption == .omemo ? String(localized: "Encrypted · \(summary)") : summary
        }
        switch status.typing[route.peer] {
        case .composing: return String(localized: "typing…")
        case .paused: return String(localized: "stopped typing")
        default:
            if let occupant {
                return status.room(occupant.room).occupants.contains { $0.nick == occupant.nick }
                    ? String(localized: "Private message · in the room")
                    : String(localized: "Private message · not in the room")
            }
            let presence = status.statusMessages[route.peer] ?? status.availability(of: route.peer).label
            return encryption == .omemo ? String(localized: "Encrypted · \(presence)") : presence
        }
    }

    /// OMEMO for this conversation: automatic (encrypted as soon as the
    /// contact has devices), always, or never.
    private var encryptionMenu: some View {
        Menu {
            Picker("Encryption", selection: Binding(
                get: { encryption },
                set: { choice in
                    do { try app.manager.setEncryption(accountID: route.accountID, peer: route.peer, choice) }
                    catch { errorMessage = String(describing: error) }
                })) {
                Text("Automatic").tag(ConversationEncryption?.none)
                Text("Encrypted (OMEMO)").tag(ConversationEncryption?.some(.omemo))
                Text("Not Encrypted").tag(ConversationEncryption?.some(.off))
            }
        } label: {
            switch encryption {
            case .omemo: Label("Encrypted", systemImage: "lock.fill")
            case .off: Label("Not Encrypted", systemImage: "lock.open")
            case nil: Label("Encryption", systemImage: "lock")
            }
        }
        .accessibilityIdentifier("encryption")
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 0) {
            if room != nil, !roomStatus.canSend {
                HStack {
                    Image(systemName: roomStatus.state == .joining ? "hourglass" : "exclamationmark.circle")
                    Text(roomStatus.isJoined ? String(localized: "You have no voice in this room") : roomStatus.summary).lineLimit(2)
                    Spacer()
                    if case .notJoined = roomStatus.state, let session {
                        Button("Join") {
                            Task {
                                do { try await session.rejoinRoom(route.peer) }
                                catch { errorMessage = String(describing: error) }
                            }
                        }
                        .font(.footnote.bold())
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 8)
                .accessibilityIdentifier("chat.roomState")
            }
            if let replyingTo {
                HStack {
                    Image(systemName: "arrowshape.turn.up.left")
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Replying to \(author(of: replyingTo))").bold()
                        Text(replyingTo.preview).lineLimit(1)
                    }
                    Spacer()
                    Button {
                        self.replyingTo = nil
                    } label: { Image(systemName: "xmark.circle.fill") }
                    .accessibilityLabel("Cancel reply")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 8)
                .accessibilityIdentifier("chat.replyBanner")
            }
            if let editing {
                HStack {
                    Image(systemName: "pencil")
                    Text("Editing: \(editing.body)").lineLimit(1)
                    Spacer()
                    Button {
                        self.editing = nil
                        text = ""
                    } label: { Image(systemName: "xmark.circle.fill") }
                    .accessibilityLabel("Cancel editing")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 8)
            }
            if recorder.isRecording {
                recordingRow
            } else {
                inputRow
            }
        }
        .background(.bar)
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if editing == nil {
                Menu {
                    Button { pickingPhotos = true } label: { Label("Photos & Videos", systemImage: "photo.on.rectangle") }
                    Button { importingFiles = true } label: { Label("File", systemImage: "doc") }
                } label: {
                    if preparing {
                        ProgressView().frame(width: buttonSize, height: buttonSize)
                    } else {
                        Image(systemName: "paperclip.circle.fill").font(.system(size: buttonSize))
                    }
                }
                .disabled(preparing || !canAttach)
                .padding(.bottom, 2)
                .accessibilityLabel("Attach Photo or File")
                .accessibilityIdentifier("chat.attach")
            }
            TextField("Message", text: $text, axis: .vertical)
                .lineLimit(1...6)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 20).fill(Color(.secondarySystemBackground)))
                .onChange(of: text) { old, new in typingChanged(from: old, to: new) }
                .accessibilityIdentifier("chat.composer")
            if editing == nil, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    Task { await startRecording() }
                } label: {
                    Image(systemName: "mic.circle.fill").font(.system(size: buttonSize))
                }
                .disabled(!canAttach)
                .accessibilityLabel("Record voice message")
                .accessibilityIdentifier("chat.record")
            } else {
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: editing == nil ? "arrow.up.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: buttonSize))
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(editing == nil ? "Send" : "Save edit")
                .accessibilityIdentifier("chat.send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var recordingRow: some View {
        HStack(spacing: 12) {
            Button {
                recorder.cancel()
            } label: {
                Image(systemName: "trash.circle.fill").font(.system(size: buttonSize)).foregroundStyle(.red)
            }
            .accessibilityLabel("Discard recording")
            Circle().fill(.red).frame(width: 10, height: 10).accessibilityHidden(true)
            Text(Duration.seconds(recorder.elapsed).formatted(.time(pattern: .minuteSecond)))
                .font(.body.monospacedDigit())
            Text("Recording").foregroundStyle(.secondary)
            Spacer()
            Button {
                Task { await finishRecording() }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: buttonSize))
            }
            .accessibilityLabel("Send voice message")
            .accessibilityIdentifier("chat.sendRecording")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Rooms only take files once joined with voice (the upload needs no
    /// room, but the message does; it would wait in the outbox).
    private var canAttach: Bool { room == nil || roomStatus.canSend || !roomStatus.isJoined }

    // MARK: Files

    private func sendPhotos(_ items: [PhotosPickerItem]) async {
        guard let session else { return }
        preparing = true
        defer { preparing = false }
        for item in items {
            do {
                let file: OutgoingFile
                if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }),
                   let movie = try await item.loadTransferable(type: PickedMovie.self) {
                    file = try await MediaPreparation.video(movie.url, media: app.media)
                    try? FileManager.default.removeItem(at: movie.url)
                } else if let data = try await item.loadTransferable(type: Data.self) {
                    file = try MediaPreparation.image(data, media: app.media)
                } else {
                    continue
                }
                try await session.sendFile(file, to: route.peer)
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }

    private func sendFiles(_ result: Result<[URL], any Error>) async {
        guard let session else { return }
        do {
            for url in try result.get() {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                try await session.sendFile(try MediaPreparation.file(url, media: app.media), to: route.peer)
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func startRecording() async {
        typingTask?.cancel()
        if await !recorder.start() {
            errorMessage = String(localized: "Hrafn can't use the microphone. Allow it in Settings to record voice messages.")
        }
    }

    private func finishRecording() async {
        guard let (url, duration) = recorder.finish(), let session else { return }
        do {
            try await session.sendFile(try MediaPreparation.voice(url, duration: duration, media: app.media),
                                       to: route.peer)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// XEP-0085: composing while typing, paused after five quiet seconds.
    private func typingChanged(from old: String, to new: String) {
        guard editing == nil, let session else { return }
        let peer = route.peer
        typingTask?.cancel()
        if new.isEmpty {
            Task { await session.sendChatState(.active, to: peer) }
            return
        }
        if old.isEmpty { Task { await session.sendChatState(.composing, to: peer) } }
        typingTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await session.sendChatState(.paused, to: peer)
        }
    }

    private func send() async {
        let body = text
        typingTask?.cancel()
        guard let session else { return }
        do {
            if let editing, let id = editing.id {
                try await session.correct(messageID: id, with: body)
                self.editing = nil
            } else {
                try await session.send(body, to: route.peer, replyingTo: replyingTo?.id)
                replyingTo = nil
            }
            text = ""
        } catch {
            errorMessage = String(describing: error)
        }
    }

    // MARK: Actions

    @ViewBuilder
    private func menu(for message: StoredMessage) -> some View {
        if !message.isRetracted, message.referenceID(inRoom: isRoom) != nil {
            ControlGroup {
                ForEach(ReactionBar.quick, id: \.self) { emoji in
                    Button(emoji) { react(emoji, to: message) }
                }
            }
            .controlGroupStyle(.compactMenu)
            Menu {
                ForEach(ReactionBar.more, id: \.self) { emoji in
                    Button(emoji) { react(emoji, to: message) }
                }
            } label: { Label("More Reactions", systemImage: "face.smiling") }
            Button {
                editing = nil
                replyingTo = message
            } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
        }
        if let attachment = message.attachment, !message.isRetracted {
            if let path = attachment.localPath {
                ShareLink(item: app.media.url(for: path)) { Label("Share", systemImage: "square.and.arrow.up") }
            }
            if let url = attachment.url {
                Button { UIPasteboard.general.url = url } label: { Label("Copy Link", systemImage: "link") }
            }
            if message.isOutgoing, message.state == .failed, let id = message.id {
                Button {
                    Task {
                        do { try await session?.retryFile(messageID: id) } catch { errorMessage = String(describing: error) }
                    }
                } label: { Label("Try Again", systemImage: "arrow.clockwise") }
            }
        } else if !message.isRetracted {
            Button { UIPasteboard.general.string = message.body } label: { Label("Copy", systemImage: "doc.on.doc") }
        }
        if message.isOutgoing, !message.isRetracted, message.attachment == nil, let id = message.id {
            Button {
                replyingTo = nil
                editing = message
                text = message.body
            } label: { Label("Edit", systemImage: "pencil") }
            Button(role: .destructive) {
                Task {
                    do { try await session?.retract(messageID: id) } catch { errorMessage = String(describing: error) }
                }
            } label: { Label("Retract", systemImage: "arrow.uturn.backward") }
        } else if message.isOutgoing, !message.isRetracted, let id = message.id {
            Button(role: .destructive) {
                Task {
                    do { try await session?.retract(messageID: id) } catch { errorMessage = String(describing: error) }
                }
            } label: { Label("Retract", systemImage: "arrow.uturn.backward") }
        }
        if canModerate(message) {
            Button(role: .destructive) { startModerating(message) } label: {
                Label("Remove…", systemImage: "trash")
            }
        }
        if message.state == .failed, let text = message.errorText {
            Text("Failed: \(text)")
        }
    }

    /// XEP-0425: a moderator may take down others' messages the room has
    /// confirmed, where the room supports it.
    private func canModerate(_ message: StoredMessage) -> Bool {
        isRoom && roomStatus.canModerate && !message.isOutgoing && !message.isRetracted
            && message.archiveID != nil
    }

    private func startModerating(_ message: StoredMessage) {
        moderationReason = ""
        moderating = message
    }

    private func moderate() {
        guard let id = moderating?.id, let session else { return }
        let reason = moderationReason
        Task {
            do { try await session.moderate(messageID: id, reason: reason) } catch { errorMessage = String(describing: error) }
        }
    }

    /// The context menu's main actions, for VoiceOver's actions rotor.
    @ViewBuilder
    private func accessibilityActions(for message: StoredMessage) -> some View {
        if !message.isRetracted, message.referenceID(inRoom: isRoom) != nil {
            Button("Reply") {
                editing = nil
                replyingTo = message
            }
            ForEach(ReactionBar.quick, id: \.self) { emoji in
                Button("React with \(emoji)") { react(emoji, to: message) }
            }
        }
        if !message.isRetracted, message.attachment == nil {
            Button("Copy") { UIPasteboard.general.string = message.body }
        }
        if message.isOutgoing, !message.isRetracted, let id = message.id {
            if message.attachment == nil {
                Button("Edit") {
                    replyingTo = nil
                    editing = message
                    text = message.body
                }
            }
            Button("Retract") {
                Task {
                    do { try await session?.retract(messageID: id) } catch { errorMessage = String(describing: error) }
                }
            }
        }
        if canModerate(message) {
            Button("Remove") { startModerating(message) }
        }
    }

    // MARK: Reactions and replies

    /// Messages by the id replies and reactions use for them.
    private var referenceIndex: [String: StoredMessage] {
        var index: [String: StoredMessage] = [:]
        for message in messages {
            if let id = message.referenceID(inRoom: isRoom) { index[id] = message }
        }
        return index
    }

    private func react(_ emoji: String, to message: StoredMessage) {
        guard let id = message.id, let session else { return }
        Task {
            do { try await session.toggleReaction(emoji, on: id) } catch { errorMessage = String(describing: error) }
        }
    }

    /// Who wrote `message`, as a reply shows it.
    private func author(of message: StoredMessage) -> String {
        if message.isOutgoing { return String(localized: "You") }
        return message.senderNick ?? title
    }

    /// The quoted original above a reply: the stored message when it is
    /// here, else what the reply quoted.
    private func quote(for message: StoredMessage, original: StoredMessage?) -> (author: String, text: String)? {
        guard message.replyToID != nil, !message.isRetracted else { return nil }
        if let original { return (author(of: original), original.preview) }
        guard let quoted = message.replyQuote else { return nil }
        let author: String
        if isRoom {
            author = message.replyTo.flatMap { $0.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init) }
                ?? String(localized: "Someone")
        } else if let to = message.replyTo, to.split(separator: "/").first.map(String.init) == route.peer {
            author = title
        } else {
            author = message.isOutgoing ? title : String(localized: "You")
        }
        return (author, quoted)
    }

    private func loadOlder() async {
        guard let session, !isLoadingOlder else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            reachedStart = try await session.loadOlder(peer: route.peer)
            limit += 50
        } catch {
            errorMessage = String(describing: error)
        }
    }
}

private struct MessageBubble: View {
    let message: StoredMessage
    let accountID: String
    /// Group chat: the sender's nick above the first of their messages in a run.
    var showsSender = false
    /// The time and state underneath, shown at the end of a run from one
    /// sender; anything that needs attention shows regardless.
    var showsFooter = true
    /// Group chat: shows who the sender is, from their nick.
    var inspectSender: ((String) -> Void)?
    /// XEP-0461: the message this one answers.
    var quote: (author: String, text: String)?
    var showOriginal: (() -> Void)?
    /// Who wrote it, for VoiceOver ("You", a nick, the contact).
    var author: String?
    var reactions: [ReactionCount] = []
    var toggleReaction: (String) -> Void = { _ in }

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 48) }
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
                if showsSender, let nick = message.senderNick {
                    Button { inspectSender?(nick) } label: {
                        Text(nick)
                            .font(.caption.bold())
                            .foregroundStyle(Self.color(for: nick))
                    }
                    .buttonStyle(.plain)
                    .disabled(inspectSender == nil)
                    .padding(.leading, 12)
                    .accessibilityHint("Shows their address")
                }
                if let attachment = message.attachment, !message.isRetracted,
                   attachment.kind == .image || attachment.kind == .video {
                    // Pictures stand on their own, without a bubble.
                    AttachmentView(message: message, attachment: attachment, accountID: accountID)
                        .overlay {
                            if message.mentionsMe { RoundedRectangle(cornerRadius: 16).stroke(.tint, lineWidth: 2) }
                        }
                } else {
                    bubble
                }
                if !reactions.isEmpty, !message.isRetracted {
                    ReactionBar(reactions: reactions, isOutgoing: message.isOutgoing, toggle: toggleReaction)
                }
                if showsFooter || needsAttention { footer }
            }
            if !message.isOutgoing { Spacer(minLength: 48) }
        }
        // Files keep their own controls (play, download, view), and quotes
        // and reactions their buttons.
        .modifier(BubbleAccessibility(isPlain: message.attachment == nil && reactions.isEmpty && quote == nil,
                                      label: accessibilityLabel))
    }

    /// Failures, untrusted or unreadable encryption, and edits.
    private var needsAttention: Bool {
        message.state == .failed || message.state == .pending
            || (message.editedAt != nil && !message.isRetracted)
            || message.encryption == .untrustedSender || message.encryption == .undecryptable
    }

    private var footer: some View {
        HStack(spacing: 4) {
            switch message.encryption {
            case .omemo:
                Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                    .accessibilityLabel("Encrypted")
            case .untrustedSender:
                Image(systemName: "exclamationmark.shield").foregroundStyle(.orange)
                    .accessibilityLabel("From a device you haven’t trusted")
            case .undecryptable:
                Image(systemName: "shield.slash").accessibilityLabel("Can’t be decrypted")
            case nil:
                EmptyView()
            }
            if message.editedAt != nil, !message.isRetracted { Text("edited") }
            Text(message.timestamp, format: .dateTime.hour().minute())
            if message.isOutgoing { stateIcon }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    /// One sentence for a plain text message: who, what, when, and how far
    /// it got.
    private var accessibilityLabel: String {
        var parts: [String] = []
        if let author { parts.append(author) }
        parts.append(message.isRetracted ? message.retractionNotice : message.body)
        if message.mentionsMe, !message.isRetracted { parts.append(String(localized: "Mentions you")) }
        if message.editedAt != nil, !message.isRetracted { parts.append(String(localized: "edited")) }
        switch message.encryption {
        case .omemo: parts.append(String(localized: "Encrypted"))
        case .untrustedSender: parts.append(String(localized: "From a device you haven’t trusted"))
        case .undecryptable, nil: break
        }
        parts.append(message.timestamp.formatted(date: .omitted, time: .shortened))
        if message.isOutgoing, let state = stateLabel { parts.append(state) }
        return parts.joined(separator: ", ")
    }

    private var stateLabel: String? {
        switch message.state {
        case .pending: String(localized: "Waiting to send")
        case .sent: String(localized: "Sent")
        case .delivered: String(localized: "Delivered")
        case .displayed: String(localized: "Read")
        case .failed: String(localized: "Failed")
        case .received, .read: nil
        }
    }

    private var bubble: some View {
        Group {
            if message.isRetracted {
                Text(message.retractionNotice).italic().foregroundStyle(.secondary)
            } else if let attachment = message.attachment {
                AttachmentView(message: message, attachment: attachment, accountID: accountID)
                    .foregroundStyle(message.isOutgoing ? .white : .primary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if let quote {
                        ReplyQuote(author: quote.author, text: quote.text, isOutgoing: message.isOutgoing,
                                   onTap: showOriginal)
                    }
                    if message.encryption == .undecryptable {
                        // Not the sender's words: a placeholder.
                        Text(message.body).italic().foregroundStyle(.secondary)
                    } else {
                        StyledText(text: message.body, isOutgoing: message.isOutgoing, unstyled: message.isUnstyled)
                            .foregroundStyle(message.isOutgoing ? .white : .primary)
                    }
                }
            }
        }
        .textSelection(.enabled)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(message.isOutgoing && !message.isRetracted ? AnyShapeStyle(.tint)
                      : AnyShapeStyle(Color(.secondarySystemBackground)))
        )
        .overlay {
            if message.mentionsMe, !message.isRetracted {
                RoundedRectangle(cornerRadius: 18).stroke(.tint, lineWidth: 2)
            }
        }
    }

    /// XEP-0392, like the avatars.
    static func color(for nick: String) -> Color { Avatar.color(for: nick) }

    @ViewBuilder
    private var stateIcon: some View {
        switch message.state {
        case .pending: Image(systemName: "clock").accessibilityLabel("Waiting to send")
        case .sent: Image(systemName: "checkmark").accessibilityLabel("Sent")
        case .delivered: Image(systemName: "checkmark.circle").accessibilityLabel("Delivered")
        case .displayed: Image(systemName: "checkmark.circle.fill").accessibilityLabel("Read")
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).accessibilityLabel("Failed")
        case .received, .read: EmptyView()
        }
    }
}

/// A plain message reads as one element with a written-out label; anything
/// with controls of its own keeps them reachable.
private struct BubbleAccessibility: ViewModifier {
    let isPlain: Bool
    let label: String

    func body(content: Content) -> some View {
        if isPlain {
            content.accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityIdentifier("chat.message")
        } else {
            content.accessibilityElement(children: .contain)
        }
    }
}

/// A picked video, copied out of the Photos library.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString + "." + received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}
