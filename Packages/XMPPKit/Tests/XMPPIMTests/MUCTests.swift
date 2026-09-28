import Testing
import Foundation
import XMPPClient
@testable import XMPPIM
import XMPPTestSupport
import XMPPCore
import XMPPXML

private let room = try! JID("verona@conference.example.com")

private func presence(_ xml: String) throws -> Presence {
    try #require(Presence(try parse(xml)))
}

private func occupant(_ xml: String) throws -> OccupantPresence {
    try #require(OccupantPresence(try presence(xml)))
}

private let allFeatures = RoomInfo(features: [Namespaces.muc, Namespaces.stableIDs, Namespaces.occupantID, Namespaces.mam])

@Suite struct OccupantTests {

    @Test func joinsRenamesAndIsKicked() throws {
        var occupants = RoomOccupants()
        let other = try occupant("""
        <presence from='verona@conference.example.com/Romeo'><x xmlns='http://jabber.org/protocol/muc#user'>\
        <item affiliation='member' role='participant' jid='romeo@example.net/phone'/></x></presence>
        """)
        #expect(occupants.apply(other) == .occupants)
        #expect(occupants.occupants["Romeo"]?.realJID == (try JID("romeo@example.net/phone")))

        let own = try occupant("""
        <presence from='verona@conference.example.com/Juliet'><occupant-id xmlns='urn:xmpp:occupant-id:0' id='oj'/>\
        <x xmlns='http://jabber.org/protocol/muc#user'><item affiliation='owner' role='moderator'/>\
        <status code='110'/><status code='210'/></x></presence>
        """)
        #expect(own.isSelf)
        #expect(own.statusCodes == [110, 210])
        #expect(own.occupantID == "oj")
        guard case .joined(let joined) = occupants.apply(own) else { Issue.record("not joined"); return }
        #expect(joined.affiliation == .owner && joined.role == .moderator)
        #expect(occupants.ownNick == "Juliet")

        // §7.6.3: unavailable with 303 under the old nick, then the new one.
        let leaving = try occupant("""
        <presence type='unavailable' from='verona@conference.example.com/Juliet'>\
        <x xmlns='http://jabber.org/protocol/muc#user'><item affiliation='owner' role='moderator' nick='Jules'/>\
        <status code='303'/><status code='110'/></x></presence>
        """)
        #expect(occupants.apply(leaving) == .none)
        #expect(occupants.isJoined)
        let renamed = try occupant("""
        <presence from='verona@conference.example.com/Jules'><x xmlns='http://jabber.org/protocol/muc#user'>\
        <item affiliation='owner' role='moderator'/><status code='110'/></x></presence>
        """)
        guard case .updatedSelf(let updated) = occupants.apply(renamed) else { Issue.record("no update"); return }
        #expect(updated.nick == "Jules")
        #expect(occupants.occupants.keys.sorted() == ["Jules", "Romeo"])

        let kicked = try occupant("""
        <presence type='unavailable' from='verona@conference.example.com/Jules'>\
        <x xmlns='http://jabber.org/protocol/muc#user'><item affiliation='owner' role='none'><reason>Hush</reason></item>\
        <status code='307'/><status code='110'/></x></presence>
        """)
        #expect(occupants.apply(kicked) == .exited(.kicked(reason: "Hush")))
        #expect(!occupants.isJoined)
        #expect(occupants.occupants.isEmpty)
    }

    @Test func destructionWithoutSelfCodeStillEndsTheJoin() throws {
        var occupants = RoomOccupants()
        _ = occupants.apply(try occupant("""
        <presence from='verona@conference.example.com/Juliet'><x xmlns='http://jabber.org/protocol/muc#user'>\
        <item affiliation='owner' role='moderator'/><status code='110'/></x></presence>
        """))
        let destroyed = try presence("""
        <presence type='unavailable' from='verona@conference.example.com/Juliet'>\
        <x xmlns='http://jabber.org/protocol/muc#user'><item affiliation='none' role='none'/>\
        <destroy jid='mantua@conference.example.com'/></x></presence>
        """)
        #expect(RoomOccupants.isDestroyed(destroyed))
        #expect(occupants.apply(try #require(OccupantPresence(destroyed))) == .exited(.shutdown))
    }

    @Test func bannedAndRemovedCodes() throws {
        for (code, exit) in [(301, RoomOccupants.Exit.banned(reason: nil)), (321, .removed), (322, .removed),
                             (332, .shutdown), (333, .technical)] {
            var occupants = RoomOccupants()
            _ = occupants.apply(try occupant("""
            <presence from='verona@conference.example.com/J'><x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant'/><status code='110'/></x></presence>
            """))
            let out = try occupant("""
            <presence type='unavailable' from='verona@conference.example.com/J'>\
            <x xmlns='http://jabber.org/protocol/muc#user'><item role='none'/><status code='\(code)'/><status code='110'/></x></presence>
            """)
            #expect(occupants.apply(out) == .exited(exit))
        }
    }

    @Test func ignoresPresenceThatIsNotFromAnOccupant() throws {
        #expect(OccupantPresence(try presence("<presence from='verona@conference.example.com'/>")) == nil)
        #expect(OccupantPresence(try presence("<presence from='romeo@example.net/phone'/>")) == nil)
    }
}

@Suite struct RoomMessageTests {

    @Test func trustsIDsOnlyFromRoomsThatVouchForThem() throws {
        let raw = try message("""
        <message type='groupchat' from='verona@conference.example.com/Romeo' id='m1'><body>hi</body>\
        <origin-id xmlns='urn:xmpp:sid:0' id='o1'/><stanza-id xmlns='urn:xmpp:sid:0' by='verona@conference.example.com' id='S1'/>\
        <occupant-id xmlns='urn:xmpp:occupant-id:0' id='oR'/></message>
        """)
        let trusted = try #require(RoomMessage(live: raw, info: allFeatures))
        #expect(trusted.room == room)
        #expect(trusted.nick == "Romeo")
        #expect(trusted.senderID == "o1")
        #expect(trusted.archiveID == "S1")
        #expect(trusted.occupantID == "oR")

        let untrusted = try #require(RoomMessage(live: raw, info: RoomInfo(features: [Namespaces.muc])))
        #expect(untrusted.archiveID == nil)
        #expect(untrusted.occupantID == nil)
        #expect(try #require(RoomMessage(live: raw, info: nil)).archiveID == nil)
    }

    @Test func subjectsAndChat() throws {
        let subject = try #require(RoomMessage(live: try message("""
        <message type='groupchat' from='verona@conference.example.com/Romeo'><subject>Two households</subject></message>
        """), info: nil))
        #expect(subject.subject == "Two households")
        let cleared = try #require(RoomMessage(live: try message("""
        <message type='groupchat' from='verona@conference.example.com'><subject/></message>
        """), info: nil))
        #expect(cleared.subject == "")
        #expect(cleared.nick == nil)
        // A body with a subject is a message, not a subject change (§8.1).
        #expect(RoomMessage(live: try message("""
        <message type='groupchat' from='verona@conference.example.com/R'><subject>x</subject><body>b</body></message>
        """), info: nil)?.subject == nil)
        #expect(RoomMessage(live: try message("<message type='chat' from='verona@conference.example.com/R'><body>pm</body></message>"),
                            info: nil) == nil)
    }

    @Test func buildsRoomMessages() throws {
        let sent = Message.groupchat(to: room, body: "hi", id: "x1")
        #expect(sent.type == .groupchat)
        #expect(sent.originID == "x1")
        #expect(!sent.requestsReceipt)
        #expect(Message.groupchatRetraction(of: "S1", to: room).retractedID == "S1")
        #expect(Message.groupchatRetraction(of: "S1", to: room).type == .groupchat)
        #expect(Message.groupchatCorrection(of: "x1", to: room, body: "hey").replacedID == "x1")
    }

    @Test func roomInfoFromDisco() throws {
        let query = try parse("""
        <iq type='result' id='1'><query xmlns='http://jabber.org/protocol/disco#info'>\
        <identity category='conference' type='text' name='Verona'/>\
        <feature var='http://jabber.org/protocol/muc'/><feature var='muc_membersonly'/><feature var='muc_nonanonymous'/>\
        <feature var='urn:xmpp:mam:2'/><x xmlns='jabber:x:data' type='result'>\
        <field var='FORM_TYPE' type='hidden'><value>http://jabber.org/protocol/muc#roominfo</value></field>\
        <field var='muc#roominfo_occupants'><value>3</value></field>\
        <field var='muc#roominfo_description'><value/></field></x></query></iq>
        """).elements[0]
        let info = try #require(RoomInfo(DiscoInfo(query: query)))
        #expect(info.name == "Verona")
        #expect(info.isPrivateGroup)
        #expect(info.supportsArchive)
        #expect(!info.supportsStableIDs)
        #expect(info.occupantCount == 3)
        #expect(info.description == nil)
        #expect(RoomInfo(DiscoInfo(identities: [.init(category: "client", type: "pc")], features: [])) == nil)
    }
}

@Suite struct InviteTests {

    @Test func mediatedInvitesWinOverTheirDirectCopy() throws {
        // Rooms add a XEP-0249 element to the invitations they forward.
        let invite = try #require(RoomInvite(try message("""
        <message from='verona@conference.example.com' to='romeo@example.net'>\
        <x xmlns='http://jabber.org/protocol/muc#user'><invite from='juliet@example.com/phone'><reason>Supper</reason></invite>\
        <password>secret</password></x><x xmlns='jabber:x:conference' jid='verona@conference.example.com'/></message>
        """)))
        #expect(invite.kind == .mediated)
        #expect(invite.room == room)
        #expect(invite.inviter == (try JID("juliet@example.com")))
        #expect(invite.reason == "Supper")
        #expect(invite.password == "secret")
    }

    @Test func directInvites() throws {
        let invite = try #require(RoomInvite(try message("""
        <message from='juliet@example.com/phone'><x xmlns='jabber:x:conference' jid='verona@conference.example.com' \
        reason='Come' password='p'/></message>
        """)))
        #expect(invite.kind == .direct)
        #expect(invite.inviter == (try JID("juliet@example.com")))
        #expect(invite.reason == "Come")
        #expect(invite.password == "p")
        let built = Message.directInvite(to: try JID("romeo@example.net"), room: room, reason: "r")
        #expect(RoomInvite(Message(try parse(built.element.xmlString.replacingOccurrences(
            of: "<message", with: "<message from='juliet@example.com/x'")))!)?.room == room)
        #expect(RoomInvite(try message("<message from='juliet@example.com' type='error'><x xmlns='jabber:x:conference' jid='a@b'/></message>")) == nil)
    }
}

@Suite struct BookmarkTests {

    @Test func roundTripsAndKeepsExtensions() throws {
        let item = try parse("""
        <iq type='result' id='1'><item xmlns='http://jabber.org/protocol/pubsub' id='verona@conference.example.com'>\
        <conference xmlns='urn:xmpp:bookmarks:1' name='Verona' autojoin='1'><nick>Jules</nick>\
        <extensions><state xmlns='urn:example:other' x='1'/></extensions></conference></item></iq>
        """).elements[0]
        let bookmark = try #require(Bookmark(item: item))
        #expect(bookmark.room == room && bookmark.name == "Verona" && bookmark.autojoin && bookmark.nick == "Jules")
        let extensions = try #require(bookmark.extensions)
        #expect(extensions.firstChild(name: "state", namespaceURI: "urn:example:other")?["x"] == "1")
        // Stored as XML and read back unchanged.
        #expect(try Element(xmlFragment: extensions.xmlString) == extensions)
        #expect(bookmark.conference.firstChild(name: "extensions", namespaceURI: Namespaces.bookmarks) == extensions)

        let publish = Bookmarks.publish(bookmark)
        let options = try #require(publish.firstChild(name: "publish-options", namespaceURI: Namespaces.pubsub)?
            .firstChild(name: "x", namespaceURI: Namespaces.dataForms).flatMap(DataForm.init(element:)))
        #expect(options["pubsub#access_model"] == ["whitelist"])
        #expect(options["pubsub#max_items"] == ["max"])
    }

    @Test func notificationsOnlyFromOurOwnAccount() throws {
        let xml = """
        <message from='%@'><event xmlns='http://jabber.org/protocol/pubsub#event'><items node='urn:xmpp:bookmarks:1'>\
        <item id='verona@conference.example.com'><conference xmlns='urn:xmpp:bookmarks:1' autojoin='true'/></item>\
        <retract id='mantua@conference.example.com'/></items></event></message>
        """
        let own = Bookmarks.changes(in: try message(String(format: xml, "juliet@example.com")), account: juliet)
        #expect(own == [.published(Bookmark(room: room)), .retracted(try JID("mantua@conference.example.com"))])
        #expect(Bookmarks.changes(in: try message(String(format: xml, "tybalt@example.com")), account: juliet) == [])
        #expect(Bookmarks.changes(in: try message("<message from='juliet@example.com'><body>x</body></message>"),
                                  account: juliet) == nil)
    }

    @Test func legacyBookmarks() throws {
        let conference = try parse("""
        <iq type='result' id='1'><conference xmlns='storage:bookmarks' jid='Verona@conference.example.com/x' \
        autojoin='true' name='V'><nick>J</nick></conference></iq>
        """).elements[0]
        let bookmark = try #require(Bookmark(legacy: conference))
        #expect(bookmark.room == room)
        #expect(bookmark.autojoin && bookmark.nick == "J" && bookmark.name == "V")
    }
}

@Suite struct DataFormTests {

    @Test func optionsAndConstraintsRoundTripAndSubmissionsCarryValuesOnly() throws {
        let x = try parse("""
        <iq type='result' id='1'><x xmlns='jabber:x:data' type='form'><title>Config</title>\
        <field type='fixed'><value>Section</value></field>\
        <field var='whois' type='list-single' label='Who'><desc>Who sees JIDs</desc><required/>\
        <value>moderators</value><option label='Moderators'><value>moderators</value></option>\
        <option label='Anyone'><value>anyone</value></option></field>\
        <field var='persistent' type='boolean'/></x></iq>
        """).elements[0]
        var form = try #require(DataForm(element: x))
        #expect(DataForm(element: form.element) == form)
        let whois = try #require(form.fields.first { $0.variable == "whois" })
        #expect(whois.isRequired)
        #expect(whois.description == "Who sees JIDs")
        #expect(whois.options.map(\.value) == ["moderators", "anyone"])
        #expect(!form.fields[2].boolValue)
        let setExisting = form.set("whois", ["anyone"])
        let setMissing = form.set("nonexistent", ["1"])
        #expect(setExisting && !setMissing)

        let submission = form.submission()
        #expect(submission.type == .submit)
        #expect(submission.fields.map(\.variable) == ["whois", "persistent"])
        #expect(submission.fields[0].values == ["anyone"])
        #expect(submission.fields[0].options.isEmpty && submission.fields[0].label == nil)
    }
}

@Suite struct MultiUserChatTests {

    @Test func joinWaitsForTheSelfPresenceWithTheAssignedNick() async throws {
        let transport = plainServer { xml, t in
            guard xml.hasPrefix("<presence"), xml.contains("verona@conference.example.com/Juliet") else { return }
            // Someone else first, then us under the nick the room chose.
            t.inject("""
            <presence from='verona@conference.example.com/Romeo'><x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='none' role='participant'/></x></presence>\
            <presence from='verona@conference.example.com/Jules'><x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='none' role='participant'/><status code='110'/><status code='210'/></x></presence>
            """)
        }
        let client = try makeClient(transport)
        let muc = await MultiUserChat(client: client)
        try await client.connect()
        let own = try await muc.join(room, nick: "Juliet", history: .maxStanzas(5), timeout: .seconds(2))
        #expect(own.nick == "Jules")
        #expect(own.statusCodes.contains(MUCStatus.nickAssigned))
        let sent = try await sent(transport) { $0.hasPrefix("<presence") }
        #expect(sent.contains("maxstanzas='5'"))
        // The presences still reach `events` for the session to track.
        #expect(await nextPresences(client).count == 2)
        await client.disconnect()
    }

    @Test func joinErrorsAreThrown() async throws {
        let transport = plainServer { xml, t in
            guard xml.hasPrefix("<presence") else { return }
            t.inject("""
            <presence type='error' from='verona@conference.example.com/Juliet'><error type='cancel'>\
            <conflict xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></presence>
            """)
        }
        let client = try makeClient(transport)
        let muc = await MultiUserChat(client: client)
        try await client.connect()
        do {
            try await muc.join(room, nick: "Juliet", timeout: .seconds(2))
            Issue.record("joined despite the error")
        } catch let error as StanzaError {
            #expect(error.condition == .conflict)
        }
        await #expect(throws: ClientError.timedOut) {
            try await muc.join(try JID("silent@conference.example.com"), nick: "J", timeout: .milliseconds(200))
        }
        await client.disconnect()
    }

    @Test(arguments: [
        ("", MultiUserChat.SelfPing.joined),
        ("<service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>", .joined),
        ("<item-not-found xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>", .joined),
        ("<not-acceptable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>", .notJoined),
        ("<remote-server-not-found xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>", .unreachable),
    ])
    func selfPingOutcomes(_ condition: String, _ expected: MultiUserChat.SelfPing) async throws {
        let transport = plainServer { xml, t in
            guard xml.contains("urn:xmpp:ping"), let id = Script.attribute("id", in: xml) else { return }
            let from = "verona@conference.example.com/Juliet"
            t.inject(condition.isEmpty
                ? "<iq type='result' id='\(id)' from='\(from)'/>"
                : "<iq type='error' id='\(id)' from='\(from)'><error type='cancel'>\(condition)</error></iq>")
        }
        let client = try makeClient(transport)
        let muc = await MultiUserChat(client: client)
        try await client.connect()
        #expect(await muc.selfPing(room, nick: "Juliet", timeout: .seconds(2)) == expected)
        await client.disconnect()
    }
}

/// Presences delivered on `events` for a short while.
private func nextPresences(_ client: XMPPClient) async -> [Presence] {
    await withTaskGroup(of: [Presence].self) { group in
        group.addTask {
            var out: [Presence] = []
            for await event in client.events { if case .presence(let p) = event { out.append(p) } }
            return out
        }
        try? await Task.sleep(for: .milliseconds(200))
        group.cancelAll()
        return await group.next() ?? []
    }
}
