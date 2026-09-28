import Foundation
import HrafnStore
import XMPPCore
import XMPPIM
import XMPPXML

extension InboundMessage {

    /// What the store should record for this message. Chat states are not
    /// stored; groupchat and headline messages are not one-to-one chat.
    func events(accountID: String, now: Date = Date(), alreadyRead: Bool = false) -> [MessageEvent] {
        let message = self.message
        switch message.type {
        case .groupchat, .headline:
            return []
        case .error:
            guard let id = message.id else { return [] }
            return [event(accountID, .error(stanzaID: id, text: message.error?.text ?? message.error?.condition.rawValue),
                          now: now, alreadyRead: alreadyRead)]
        case .chat, .normal:
            break
        }

        var events: [MessageEvent] = []
        if let target = message.retractedID {
            events.append(event(accountID, .retraction(of: target), now: now, alreadyRead: alreadyRead))
        } else if let reactions = message.reactions {
            events.append(event(accountID, .reactions(to: reactions.id, reactions.emojis), now: now,
                                alreadyRead: alreadyRead))
        } else if let target = message.replacedID, let body = message.displayBody {
            events.append(event(accountID, .correction(of: target, body: body), now: now, alreadyRead: alreadyRead))
        } else if let body = message.displayBody, !body.isEmpty {
            events.append(event(accountID, .body(body, markable: message.isMarkable), now: now, alreadyRead: alreadyRead))
        }
        if let id = message.receiptID {
            events.append(event(accountID, .receipt(for: id), now: now, alreadyRead: alreadyRead))
        }
        if let id = message.displayedID {
            events.append(event(accountID, .displayed(upTo: id), now: now, alreadyRead: alreadyRead))
        }
        return events
    }

    private func event(_ accountID: String, _ content: MessageEvent.Content, now: Date, alreadyRead: Bool) -> MessageEvent {
        // Only a body is the thing the archive id names; a receipt or marker
        // carried alongside must not claim it too, or it would look like a
        // duplicate of the body.
        let ownsArchiveID: Bool
        switch content {
        case .body, .correction, .retraction, .reactions: ownsArchiveID = true
        default: ownsArchiveID = false
        }
        var attachment: Attachment?
        var reply: ReplyReference?
        if case .body = content {
            attachment = message.fileAttachment
            reply = message.replyReference
        }
        return MessageEvent(
            accountID: accountID, peer: peer.description, isOutgoing: isOutgoing, content: content,
            senderID: senderID, stanzaID: message.id, archiveID: ownsArchiveID ? archiveID : nil,
            timestamp: timestamp ?? now, alreadyRead: alreadyRead, attachment: attachment, reply: reply,
            unstyled: message.isUnstyled)
    }
}

/// Who "we" are in a room, to recognise our own messages and mentions.
struct RoomSelf: Sendable {
    /// Our account's bare JID.
    var account: JID
    /// Our current nickname.
    var nick: String?
    /// Our XEP-0421 occupant id, stable for our account in this room.
    var occupantID: String?
}

extension RoomMessage {

    /// What the store should record for a groupchat message. Subjects are
    /// stored on the room, not as messages; receipts and markers are not used
    /// in rooms.
    func events(accountID: String, me: RoomSelf, now: Date = Date(), alreadyRead: Bool = false) -> [MessageEvent] {
        let room = self.room.description
        if message.type == .error {
            guard let id = message.id else { return [] }
            return [MessageEvent(accountID: accountID, peer: room, isOutgoing: true,
                                 content: .error(stanzaID: id, text: message.error?.text ?? message.error?.condition.rawValue),
                                 timestamp: now)]
        }
        // XEP-0425: the room's word that a moderator took a message down;
        // an archive may keep a tombstone in the message's place instead.
        if let moderation = Moderation(message, room: self.room) {
            return [MessageEvent(accountID: accountID, peer: room, isOutgoing: false,
                                 content: .moderation(of: moderation.target, by: moderation.moderator,
                                                      reason: moderation.reason),
                                 senderID: senderID, archiveID: archiveID, timestamp: timestamp ?? now)]
        }
        if nick != nil, let archiveID, let tombstone = Moderation.tombstone(in: message) {
            return [MessageEvent(accountID: accountID, peer: room, isOutgoing: isOwn(me),
                                 content: .moderation(of: archiveID, by: tombstone.moderator, reason: tombstone.reason),
                                 timestamp: timestamp ?? now)]
        }
        guard nick != nil, subject == nil else { return [] }

        let outgoing = isOwn(me)
        let content: MessageEvent.Content
        if let target = message.retractedID {
            content = .retraction(of: target)
        } else if let reactions = message.reactions {
            content = .reactions(to: reactions.id, reactions.emojis)
        } else if let target = message.replacedID, let body = message.displayBody {
            content = .correction(of: target, body: body)
        } else if let body = message.displayBody, !body.isEmpty {
            content = .body(body, markable: false)
        } else {
            return []
        }
        var mentions = false
        var attachment: Attachment?
        var reply: ReplyReference?
        if case .body(let body, _) = content {
            attachment = message.fileAttachment
            reply = message.replyReference
            if !outgoing, attachment == nil, let nick = me.nick {
                // A reply to one of our messages counts as a mention.
                mentions = Self.mentions(body, nick: nick) || reply?.to.flatMap { try? JID($0) }?.resourcepart == nick
                    // XEP-0372: marked up by the sender, as us or as our occupant JID.
                    || message.mentions.contains { $0.jid == me.account.bare || $0.jid == (try? self.room.withResource(nick)) }
            }
        }
        return [MessageEvent(
            accountID: accountID, peer: room, isOutgoing: outgoing, content: content, senderID: senderID,
            stanzaID: message.id, archiveID: archiveID, timestamp: timestamp ?? now, alreadyRead: alreadyRead,
            sender: .init(nick: nick, occupantID: occupantID, realJID: realJID?.bare.description),
            mentionsMe: mentions, attachment: attachment, reply: reply, unstyled: message.isUnstyled)]
    }

    /// Ours if the occupant ids say so; without them, by real JID, then by
    /// nickname (which can only be as good as the nick is unique over time).
    func isOwn(_ me: RoomSelf) -> Bool {
        if let occupantID, let own = me.occupantID { return occupantID == own }
        if let realJID { return realJID.bare == me.account }
        return nick != nil && nick == me.nick
    }

    /// `nick` as a word in `body`, ignoring case: "romeo:" and "@Romeo" count,
    /// "romeos" does not.
    static func mentions(_ body: String, nick: String) -> Bool {
        guard !nick.isEmpty else { return false }
        var searchRange = body.startIndex..<body.endIndex
        while let range = body.range(of: nick, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
            let before = range.lowerBound == body.startIndex ? nil : body[body.index(before: range.lowerBound)]
            let after = range.upperBound == body.endIndex ? nil : body[range.upperBound]
            if !(before?.isLetter == true || before?.isNumber == true)
                && !(after?.isLetter == true || after?.isNumber == true) {
                return true
            }
            searchRange = range.upperBound..<body.endIndex
        }
        return false
    }
}

extension Message {

    /// The body as the conversation shows it: without the quote a reply
    /// carries for clients that do not know replies.
    var displayBody: String? {
        // A XEP-0447 file may come without a body: its URL stands in.
        guard reply != nil else { return body ?? sharedFileByValue?.httpsSource?.absoluteString }
        return body(strippingFallbackFor: Namespaces.reply)?.body
    }

    /// The file this message shares: from its XEP-0447 metadata when it has
    /// some, else by the XEP-0066 convention (the URL as the whole body).
    var fileAttachment: Attachment? {
        // XEP-0454: an encrypted file's link is the whole body.
        if let body, let link = FileEncryption.link(body) {
            var attachment = MediaStore.remoteAttachment(link.url)
            attachment.encryptionKey = link.fragment
            return attachment
        }
        if let shared = sharedFileByValue, let url = shared.httpsSource {
            return MediaStore.remoteAttachment(url, metadata: shared.metadata)
        }
        return sharedFileURL.map(MediaStore.remoteAttachment)
    }

    /// XEP-0461, with the quoted original from the fallback.
    var replyReference: ReplyReference? {
        guard let reply else { return nil }
        let quote = body(strippingFallbackFor: Namespaces.reply).map { Message.unquote($0.fallback) }
        return ReplyReference(id: reply.id, to: reply.to?.description, quote: quote?.isEmpty == false ? quote : nil)
    }
}
