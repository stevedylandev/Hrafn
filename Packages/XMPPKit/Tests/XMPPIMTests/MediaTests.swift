import Testing
import Foundation
import XMPPClient
@testable import XMPPIM
import XMPPTestSupport
import XMPPCore
import XMPPXML

@Suite struct HTTPUploadTests {

    @Test func discoversTheServiceAndRequestsASlot() async throws {
        let server = plainServer { xml, t in
            guard let id = Script.attribute("id", in: xml) else { return }
            if xml.contains("disco#items") {
                t.inject("""
                <iq type='result' id='\(id)' from='example.com'><query xmlns='http://jabber.org/protocol/disco#items'>\
                <item jid='conference.example.com'/><item jid='upload.example.com'/></query></iq>
                """)
            } else if xml.contains("disco#info"), xml.contains("to='conference.example.com'") {
                t.inject("""
                <iq type='result' id='\(id)' from='conference.example.com'><query xmlns='http://jabber.org/protocol/disco#info'>\
                <feature var='http://jabber.org/protocol/muc'/></query></iq>
                """)
            } else if xml.contains("disco#info"), xml.contains("to='upload.example.com'") {
                t.inject("""
                <iq type='result' id='\(id)' from='upload.example.com'><query xmlns='http://jabber.org/protocol/disco#info'>\
                <identity category='store' type='file'/><feature var='urn:xmpp:http:upload:0'/>\
                <x xmlns='jabber:x:data' type='result'><field var='FORM_TYPE' type='hidden'>\
                <value>urn:xmpp:http:upload:0</value></field><field var='max-file-size'><value>5242880</value></field></x>\
                </query></iq>
                """)
            } else if xml.contains("urn:xmpp:http:upload:0"), xml.contains("big.mp4") {
                t.inject("""
                <iq type='error' id='\(id)' from='upload.example.com'><error type='modify'>\
                <not-acceptable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>\
                <file-too-large xmlns='urn:xmpp:http:upload:0'><max-file-size>5242880</max-file-size></file-too-large>\
                </error></iq>
                """)
            } else if xml.contains("urn:xmpp:http:upload:0") {
                t.inject("""
                <iq type='result' id='\(id)' from='upload.example.com'><slot xmlns='urn:xmpp:http:upload:0'>\
                <put url='https://upload.example.com/put/abc/photo.jpg'>\
                <header name='Authorization'>Basic Zm9vOmJhcg==</header>\
                <header name='X-Evil'>1</header>\
                <header name='Cookie'>a=1&#10;Host: evil</header>\
                </put><get url='https://upload.example.com/get/abc/photo.jpg'/></slot></iq>
                """)
            }
        }
        let client = try makeClient(server)
        try await client.connect()
        let upload = HTTPUpload(client: client)

        let service = try #require(try await upload.discover())
        #expect(service == HTTPUpload.Service(jid: try JID("upload.example.com"), maxFileSize: 5_242_880))

        let slot = try await upload.requestSlot(filename: "photo.jpg", size: 1234, contentType: "image/jpeg",
                                                service: service.jid)
        let request = try #require(IQ(try parse(try await sent(server) { $0.contains("<request") }))?.payload)
        #expect(request["filename"] == "photo.jpg")
        #expect(request["size"] == "1234")
        #expect(request["content-type"] == "image/jpeg")
        #expect(slot.putURL.absoluteString == "https://upload.example.com/put/abc/photo.jpg")
        #expect(slot.getURL.absoluteString == "https://upload.example.com/get/abc/photo.jpg")
        // Unknown headers and headers with line breaks are dropped (§4).
        #expect(slot.putHeaders == ["Authorization": "Basic Zm9vOmJhcg=="])

        await #expect(throws: HTTPUpload.Failure.fileTooLarge(maxFileSize: 5_242_880)) {
            _ = try await upload.requestSlot(filename: "big.mp4", size: 9_999_999, contentType: nil, service: service.jid)
        }
        await client.disconnect()
    }

    @Test func refusesSlotsThatAreNotHTTPS() throws {
        let slot = try parse("""
        <slot xmlns='urn:xmpp:http:upload:0'><put url='http://upload.example.com/p'/>\
        <get url='https://upload.example.com/g'/></slot>
        """)
        #expect(HTTPUpload.slot(from: slot) == nil)
    }

    @Test func parsesQuotaErrors() throws {
        let error = StanzaError(element: try parse("""
        <error xmlns='jabber:client' type='wait'><resource-constraint xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>\
        <retry xmlns='urn:xmpp:http:upload:0' stamp='2026-09-27T12:00:00Z'/></error>
        """))
        #expect(HTTPUpload.failure(from: error) == .quota(retryAfter: XMPPDateTime.parse("2026-09-27T12:00:00Z")))
        #expect(HTTPUpload.failure(from: StanzaError(.forbidden)) == nil)
    }
}

@Suite struct OOBTests {

    @Test func fileSharesCarryTheURLAsBodyAndOOB() throws {
        let url = try #require(URL(string: "https://upload.example.com/get/abc/photo.jpg"))
        let message = Message.file(to: try JID("romeo@example.net"), url: url, id: "f1")
        #expect(message.body == url.absoluteString)
        #expect(message.oobURL == url)
        #expect(message.sharedFileURL == url)
        #expect(message.originID == "f1")

        let room = Message.groupchatFile(to: try JID("verona@conference.example.com"), url: url)
        #expect(room.type == .groupchat)
        #expect(room.sharedFileURL == url)
    }

    @Test func onlyAURLThatIsTheWholeBodyIsAFileShare() throws {
        let captioned = try message("""
        <message type='chat' from='romeo@example.net/a'><body>look at this https://x.example/a.png</body>\
        <x xmlns='jabber:x:oob'><url>https://x.example/a.png</url></x></message>
        """)
        #expect(captioned.oobURL?.absoluteString == "https://x.example/a.png")
        #expect(captioned.sharedFileURL == nil)

        let unsafe = try message("""
        <message type='chat' from='romeo@example.net/a'><body>javascript:alert(1)</body>\
        <x xmlns='jabber:x:oob'><url>javascript:alert(1)</url></x></message>
        """)
        #expect(unsafe.oobURL == nil)
    }
}

/// XEP-0447 with XEP-0446 metadata and a XEP-0264 thumbnail.
@Suite struct FileSharingTests {

    @Test func readsTheXEPExample() throws {
        let shared = try #require(try message("""
        <message type='chat' from='romeo@example.net/a'><body>https://download.montague.lit/4a771ac1/summit.jpg</body>\
        <file-sharing xmlns='urn:xmpp:sfs:0' disposition='inline'>\
        <file xmlns='urn:xmpp:file:metadata:0'><media-type>image/jpeg</media-type><name>summit.jpg</name>\
        <size>3032449</size><width>4096</width><height>2160</height>\
        <hash xmlns='urn:xmpp:hashes:2' algo='sha-256'>2XarmwTlNxDAMkvymloX3S5+VbylNrJt/l5QyPa+YoU=</hash>\
        <thumbnail xmlns='urn:xmpp:thumbs:1' uri='data:image/png;base64,iVBORw0KGgo=' media-type='image/png' width='16' height='9'/>\
        <thumbnail xmlns='urn:xmpp:thumbs:1' uri='cid:sha1+ffd7c8d28e9c5e82afea41f97108c6b4@bob.xmpp.org'/>\
        <desc>Photo from the summit.</desc></file>\
        <sources><url-data xmlns='http://jabber.org/protocol/url-data' target='aesgcm://x.example/a'/>\
        <url-data xmlns='http://jabber.org/protocol/url-data' target='https://download.montague.lit/4a771ac1/summit.jpg'/>\
        </sources></file-sharing></message>
        """).sharedFileByValue)
        #expect(shared.disposition == "inline")
        #expect(shared.httpsSource?.absoluteString == "https://download.montague.lit/4a771ac1/summit.jpg")
        let file = shared.metadata
        #expect(file.name == "summit.jpg" && file.mediaType == "image/jpeg")
        #expect(file.size == 3032449 && file.width == 4096 && file.height == 2160)
        #expect(file.sha256 == "2XarmwTlNxDAMkvymloX3S5+VbylNrJt/l5QyPa+YoU=")
        #expect(file.description == "Photo from the summit.")
        #expect(file.thumbnails.count == 2)
        #expect(file.thumbnails[0].inlineData == Data(base64Encoded: "iVBORw0KGgo="))
        #expect(file.thumbnails[1].inlineData == nil)
    }

    @Test func roundTripsAndMarksTheBodyAsFallback() throws {
        let url = try #require(URL(string: "https://upload.example.com/get/abc/clip.mp4"))
        let metadata = FileMetadata(mediaType: "video/mp4", name: "clip.mp4", size: 1234, width: 640, height: 360,
                                    length: 2500, hashes: ["sha-256": "abc="],
                                    thumbnails: [FileThumbnail(data: Data([1, 2, 3]), mediaType: "image/jpeg",
                                                               width: 64, height: 36)])
        let sent = Message.file(to: try JID("romeo@example.net"), url: url, id: "f1")
            .sharing(SharedFile(metadata: metadata, sources: [url], disposition: "inline"))
        let parsed = try #require(try message(Serializer.string(for: sent.element, inheritedNamespace: Namespaces.client)).sharedFileByValue)
        #expect(parsed.metadata == metadata)
        #expect(parsed.sources == [url])
        #expect(sent.sharedFileURL == url, "clients without XEP-0447 still get the URL and OOB")
        #expect(sent.element.firstChild(name: "fallback", namespaceURI: Namespaces.fallback)?["for"]
                == Namespaces.fileSharing)
    }
}

@Suite struct AvatarTests {

    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

    @Test func publishesDataThenMetadataAndFetchesVerified() async throws {
        let png = self.png
        let hash = Avatars.sha1(png)
        let server = plainServer { xml, t in
            guard let id = Script.attribute("id", in: xml) else { return }
            if xml.contains("<publish") {
                t.inject("<iq type='result' id='\(id)'/>")
            } else if xml.contains("node='urn:xmpp:avatar:metadata'") {
                t.inject("""
                <iq type='result' id='\(id)' from='romeo@example.net'><pubsub xmlns='http://jabber.org/protocol/pubsub'>\
                <items node='urn:xmpp:avatar:metadata'><item id='\(hash)'><metadata xmlns='urn:xmpp:avatar:metadata'>\
                <info id='\(hash)' bytes='\(png.count)' type='image/webp'/>\
                <info id='\(hash)' bytes='\(png.count)' type='image/png' width='64' height='64'/>\
                <info id='\(hash)' bytes='9' type='image/png' url='https://example.net/a.png'/>\
                </metadata></item></items></pubsub></iq>
                """)
            } else if xml.contains("node='urn:xmpp:avatar:data'") {
                // The second request gets data that does not match its id.
                let data = xml.contains("0000000000") ? Data([9]) : png
                let requested = xml.components(separatedBy: "item id='").dropFirst().first?.prefix(40) ?? ""
                t.inject("""
                <iq type='result' id='\(id)' from='romeo@example.net'><pubsub xmlns='http://jabber.org/protocol/pubsub'>\
                <items node='urn:xmpp:avatar:data'><item id='\(requested)'>\
                <data xmlns='urn:xmpp:avatar:data'>\(data.base64EncodedString())</data></item></items></pubsub></iq>
                """)
            }
        }
        let client = try makeClient(server)
        try await client.connect()
        let avatars = Avatars(client: client)

        let info = try await avatars.publish(png, type: "image/png", width: 64, height: 64)
        #expect(info.id == hash)
        let publishes = server.sent.filter { $0.contains("<publish") }
        #expect(publishes.count == 2)
        #expect(publishes[0].contains("node='urn:xmpp:avatar:data'") && publishes[0].contains(png.base64EncodedString()))
        #expect(publishes[1].contains("node='urn:xmpp:avatar:metadata'") && publishes[1].contains("item id='\(hash)'"))

        let romeo = try JID("romeo@example.net")
        let metadata = try #require(try await avatars.metadata(of: romeo))
        #expect(metadata.type == "image/png" && metadata.width == 64 && metadata.url == nil)
        #expect(try await avatars.data(of: romeo, id: hash) == png)
        await #expect(throws: Avatars.Failure.hashMismatch) {
            _ = try await avatars.data(of: romeo, id: String(repeating: "0", count: 40))
        }
        await client.disconnect()
    }

    @Test func readsMetadataNotifications() throws {
        let account = try JID("juliet@example.com")
        let hash = Avatars.sha1(png)
        let published = try message("""
        <message from='romeo@example.net' to='juliet@example.com/p'><event xmlns='http://jabber.org/protocol/pubsub#event'>\
        <items node='urn:xmpp:avatar:metadata'><item id='\(hash)'><metadata xmlns='urn:xmpp:avatar:metadata'>\
        <info id='\(hash)' bytes='11' type='image/png'/></metadata></item></items></event></message>
        """)
        let change = try #require(Avatars.change(in: published, account: account))
        #expect(change.jid == (try JID("romeo@example.net")))
        #expect(change.avatar?.id == hash)

        let disabled = try message("""
        <message from='romeo@example.net'><event xmlns='http://jabber.org/protocol/pubsub#event'>\
        <items node='urn:xmpp:avatar:metadata'><item id='current'><metadata xmlns='urn:xmpp:avatar:metadata'/></item>\
        </items></event></message>
        """)
        #expect(Avatars.change(in: disabled, account: account) == Avatars.Change(jid: try JID("romeo@example.net"), avatar: nil))

        // Only bare JIDs publish PEP; an occupant or resource cannot.
        let forged = try message("""
        <message from='romeo@example.net/evil'><event xmlns='http://jabber.org/protocol/pubsub#event'>\
        <items node='urn:xmpp:avatar:metadata'><item id='x'><metadata xmlns='urn:xmpp:avatar:metadata'/></item>\
        </items></event></message>
        """)
        #expect(Avatars.change(in: forged, account: account) == nil)
        #expect(Avatars.change(in: try message("<message from='romeo@example.net'><body>hi</body></message>"),
                               account: account) == nil)
    }

    @Test func readsVCardUpdatesAndPhotos() throws {
        func presence(_ xml: String) throws -> Presence { try #require(Presence(try parse(xml))) }
        let hash = Avatars.sha1(png)
        #expect(VCardAvatars.advertised(in: try presence("<presence from='r@e/a'/>")) == .unknown)
        #expect(VCardAvatars.advertised(in: try presence(
            "<presence from='r@e/a'><x xmlns='vcard-temp:x:update'/></presence>")) == .unknown)
        #expect(VCardAvatars.advertised(in: try presence(
            "<presence from='r@e/a'><x xmlns='vcard-temp:x:update'><photo/></x></presence>")) == .none)
        #expect(VCardAvatars.advertised(in: try presence(
            "<presence from='r@e/a'><x xmlns='vcard-temp:x:update'><photo>\(hash.uppercased())</photo></x></presence>"))
                == .photo(sha1: hash))
        #expect(VCardAvatars.advertised(in: try presence(
            "<presence from='r@e/a'><x xmlns='vcard-temp:x:update'><photo>current</photo></x></presence>")) == .unverified)

        let vcard = try parse("""
        <vCard xmlns='vcard-temp'><FN>Romeo</FN><PHOTO><TYPE>image/jpeg</TYPE>\
        <BINVAL>\(png.base64EncodedString(options: .lineLength64Characters))</BINVAL></PHOTO></vCard>
        """)
        let photo = try #require(VCardAvatars.photo(in: vcard))
        #expect(photo.data == png && photo.type == "image/jpeg")
    }

    @Test func setsThePhotoKeepingOtherFields() async throws {
        let png = self.png
        let server = plainServer { xml, t in
            guard let id = Script.attribute("id", in: xml), xml.contains("vcard-temp") else { return }
            if xml.contains("type='get'") {
                t.inject("""
                <iq type='result' id='\(id)'><vCard xmlns='vcard-temp'><FN>Juliet</FN>\
                <PHOTO><TYPE>image/gif</TYPE><BINVAL>R0lG</BINVAL></PHOTO></vCard></iq>
                """)
            } else {
                t.inject("<iq type='result' id='\(id)'/>")
            }
        }
        let client = try makeClient(server)
        try await client.connect()
        try await VCardAvatars(client: client).setPhoto(png, type: "image/png")
        let set = try #require(IQ(try parse(try await sent(server) { $0.contains("type='set'") && $0.contains("vcard-temp") })))
        let vcard = try #require(set.payload)
        #expect(vcard.firstChild(name: "FN", namespaceURI: Namespaces.vcardTemp)?.text == "Juliet")
        #expect(vcard.childElements(name: "PHOTO", namespaceURI: Namespaces.vcardTemp).count == 1)
        #expect(VCardAvatars.photo(in: vcard)?.data == png)
        await client.disconnect()
    }
}

@Suite struct NicknameTests {

    @Test func readsNotificationsFromBareJIDsOnly() throws {
        let account = try JID("juliet@example.com")
        let change = try #require(Nicknames.change(in: try message("""
        <message from='romeo@example.net'><event xmlns='http://jabber.org/protocol/pubsub#event'>\
        <items node='http://jabber.org/protocol/nick'><item id='current'>\
        <nick xmlns='http://jabber.org/protocol/nick'> Romeo M. </nick></item></items></event></message>
        """), account: account))
        #expect(change == Nicknames.Change(jid: try JID("romeo@example.net"), nick: "Romeo M."))

        let own = try #require(Nicknames.change(in: try message("""
        <message><event xmlns='http://jabber.org/protocol/pubsub#event'>\
        <items node='http://jabber.org/protocol/nick'><item id='current'>\
        <nick xmlns='http://jabber.org/protocol/nick'/></item></items></event></message>
        """), account: account))
        #expect(own == Nicknames.Change(jid: account, nick: nil))
    }
}

@Suite struct ConsistentColorTests {

    /// XEP-0392 Appendix A test vectors (hue in degrees, sRGB 0...1).
    @Test(arguments: [
        ("Romeo", 327.255249, (0.865, 0.000, 0.686)),
        ("juliet@capulet.lit", 209.410400, (0.000, 0.515, 0.573)),
        ("😺", 331.199341, (0.872, 0.000, 0.659)),
        ("council", 359.994507, (0.918, 0.000, 0.394)),
    ])
    func matchesTheSpecification(identifier: String, hue: Double, rgb: (Double, Double, Double)) {
        #expect(abs(ConsistentColor.hue(for: identifier) - hue) < 0.0001)
        let color = ConsistentColor.rgb(for: identifier)
        #expect(abs(color.red - rgb.0) < 0.001)
        #expect(abs(color.green - rgb.1) < 0.001)
        #expect(abs(color.blue - rgb.2) < 0.001)
    }
}
