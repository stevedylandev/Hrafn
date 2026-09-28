import Testing
import Foundation
@testable import XMPPCore
import XMPPTestSupport

@Suite struct JIDParsingTests {

    @Test func parsesFullAddress() throws {
        let jid = try JID("juliet@example.com/balcony")
        #expect(jid.localpart == "juliet")
        #expect(jid.domainpart == "example.com")
        #expect(jid.resourcepart == "balcony")
        #expect(jid.description == "juliet@example.com/balcony")
        #expect(jid.isFull)
    }

    @Test func parsesBareAddress() throws {
        let jid = try JID("juliet@example.com")
        #expect(jid.resourcepart == nil)
        #expect(jid.isBare)
        #expect(!jid.isDomainOnly)
    }

    @Test func parsesDomainOnlyAddress() throws {
        let jid = try JID("example.com")
        #expect(jid.localpart == nil)
        #expect(jid.isDomainOnly)
    }

    /// The resourcepart may contain both `@` and `/`; the localpart may contain
    /// neither, so the first `/` wins.
    @Test func resourceMayContainDelimiters() throws {
        let jid = try JID("juliet@example.com/foo@bar/baz")
        #expect(jid.localpart == "juliet")
        #expect(jid.domainpart == "example.com")
        #expect(jid.resourcepart == "foo@bar/baz")
    }

    @Test func resourceMayContainSpaces() throws {
        #expect(try JID("juliet@example.com/foo bar").resourcepart == "foo bar")
    }

    @Test func derivesBareAndDomainAddresses() throws {
        let full = try JID("juliet@example.com/balcony")
        #expect(full.bare.description == "juliet@example.com")
        #expect(full.domain.description == "example.com")
        #expect(full.bare.bare == full.bare)
        #expect(try full.withResource("chamber").description == "juliet@example.com/chamber")
    }

    @Test(arguments: [
        "", "@example.com", "juliet@", "juliet@example.com/", "/resource",
        "jul iet@example.com", "juliet\"@example.com", "juliet:x@example.com",
        "juliet<@example.com", "a@b..c", "a@-example.com", "a@example-.com",
        "a@exa mple.com",
    ])
    func rejectsMalformedAddresses(_ input: String) {
        #expect(throws: (any Error).self) { try JID(input) }
    }

    @Test func enforcesPartLengthLimits() {
        let long = String(repeating: "a", count: 1024)
        #expect(throws: (any Error).self) { try JID("\(long)@example.com") }
        #expect(throws: (any Error).self) { try JID("juliet@example.com/\(long)") }
        #expect(throws: (any Error).self) { try JID(localpart: nil, domainpart: long + ".com") }
    }

    @Test func rejectsOverlongDomainLabel() {
        #expect(throws: (any Error).self) { try JID("a@\(String(repeating: "b", count: 64)).com") }
    }
}

@Suite struct JIDNormalizationTests {

    @Test func lowercasesLocalpartAndDomain() throws {
        let jid = try JID("JULIET@EXAMPLE.COM/Balcony")
        #expect(jid.localpart == "juliet")
        #expect(jid.domainpart == "example.com")
        // The resourcepart is case-sensitive (OpaqueString does not case-map).
        #expect(jid.resourcepart == "Balcony")
    }

    @Test func comparesEqualAfterNormalization() throws {
        #expect(try JID("JULIET@Example.COM") == (try JID("juliet@example.com")))
        #expect(try JID("a@example.com/X") != (try JID("a@example.com/x")))
    }

    @Test func foldsFullwidthFormsInLocalpart() throws {
        // U+FF35 FULLWIDTH LATIN CAPITAL LETTER U …
        #expect(try JID("\u{FF35}\u{FF33}\u{FF25}\u{FF32}@example.com").localpart == "user")
    }

    @Test func normalizesToNFC() throws {
        let decomposed = "e\u{0301}"      // e + combining acute
        let composed = "\u{00E9}"         // é
        #expect(try JID("\(decomposed)@example.com") == (try JID("\(composed)@example.com")))
    }

    @Test func stripsTrailingRootDotFromDomain() throws {
        #expect(try JID("a@example.com.").domainpart == "example.com")
    }

    @Test func keepsIPLiterals() throws {
        #expect(try JID("a@[::1]").domainpart == "[::1]")
        #expect(try JID("a@127.0.0.1").domainpart == "127.0.0.1")
    }

    @Test func exposesALabelsForDNS() throws {
        let jid = try JID("a@münchen.example")
        #expect(jid.domainpart == "münchen.example")
        #expect(jid.domainForDNS == "xn--mnchen-3ya.example")
    }

    @Test func rejectsUndecodableALabel() {
        #expect(throws: (any Error).self) { try JID("a@xn--!!!.example") }
    }

    @Test func codableRoundTrip() throws {
        let jid = try JID("juliet@example.com/balcony")
        let data = try JSONEncoder().encode(jid)
        // JSONEncoder escapes the solidus, so compare after decoding.
        #expect(try JSONDecoder().decode(String.self, from: data) == "juliet@example.com/balcony")
        #expect(try JSONDecoder().decode(JID.self, from: data) == jid)
    }
}

@Suite struct PRECISTests {

    @Test func usernameCaseMappedLowercasesAndKeepsLetters() throws {
        #expect(try PRECIS.usernameCaseMapped("Juliet") == "juliet")
        #expect(try PRECIS.usernameCaseMapped("Σ") == "σ")
        #expect(try PRECIS.usernameCaseMapped("straße") == "straße")
        #expect(try PRECIS.usernameCaseMapped("ユーザ") == "ユーザ")
    }

    @Test(arguments: ["", "a b", "a\u{00A0}b", "a\u{0007}b", "🎉", "a\u{2028}b"])
    func identifierClassRejectsSpacesSymbolsAndControls(_ input: String) {
        #expect(throws: PRECIS.ViolationError.self) { try PRECIS.usernameCaseMapped(input) }
    }

    @Test func opaqueStringPreservesCaseAndAllowsSymbols() throws {
        #expect(try PRECIS.opaqueString("Balcony") == "Balcony")
        #expect(try PRECIS.opaqueString("phone 🎉") == "phone 🎉")
        #expect(try PRECIS.opaqueString("a b") == "a b")
    }

    @Test func opaqueStringFoldsNonASCIISpaces() throws {
        #expect(try PRECIS.opaqueString("a\u{00A0}b") == "a b")
        #expect(try PRECIS.opaqueString("a\u{3000}b") == "a b")
    }

    @Test(arguments: ["", "a\u{0000}b", "a\u{0007}b", "a\u{200B}b"])
    func freeformClassRejectsControlsAndIgnorables(_ input: String) {
        #expect(throws: PRECIS.ViolationError.self) { try PRECIS.opaqueString(input) }
    }
}

@Suite struct PunycodeTests {

    @Test(arguments: [
        ("bücher", "xn--bcher-kva"),
        ("münchen", "xn--mnchen-3ya"),
        ("example", "example"),
    ])
    func encodesKnownVectors(_ input: String, _ expected: String) throws {
        #expect(try Punycode.encode(label: input) == expected)
    }

    @Test(arguments: ["bücher", "münchen", "日本語", "ελληνικά", "ñ", "aünb"])
    func roundTrips(_ input: String) throws {
        let encoded = try Punycode.encode(label: input)
        #expect(try Punycode.decode(label: encoded) == input)
    }

    @Test func encodesEveryLabelOfADomain() throws {
        #expect(try Punycode.encode(domain: "münchen.example.com") == "xn--mnchen-3ya.example.com")
    }

    @Test func rejectsInvalidACEInput() {
        #expect(throws: (any Error).self) { try Punycode.decode(label: "xn--!!!") }
    }

    @Test func rejectsLabelLongerThan63Bytes() {
        #expect(throws: (any Error).self) {
            try Punycode.encode(label: String(repeating: "ü", count: 64))
        }
    }
}

/// Random addresses: a JID either fails to parse or is a fixed point — its
/// string form parses back to the same JID — and the helpers never trap.
@Suite struct JIDFuzzTests {
    private static let pieces: [String] = [
        "@", "/", ".", "..", "a", "Z", "é", "É", "ß", "İ", "ǅ", "\u{0}", "\u{7F}", "\u{200D}", "\u{FEFF}",
        "\u{2126}", "\u{FB01}", "xn--", "xn--bcher-kva", " ", "\u{3000}", "[", "]", "::1", ":", "\\",
        "\u{1F600}", "\u{0301}", "\u{05D0}", "\u{0627}", "\u{E000}", "\u{10FFFF}", "-", "0", "%",
    ]

    @Test func parsedAddressesAreFixedPoints() {
        var generator = Fuzz.generator()
        for _ in 0..<Fuzz.iterations(4000) {
            var input = ""
            for _ in 0..<Int.random(in: 0..<12, using: &generator) {
                if Int.random(in: 0..<4, using: &generator) == 0,
                   let scalar = Unicode.Scalar(UInt32.random(in: 0...0x2FFFF, using: &generator)) {
                    input.unicodeScalars.append(scalar)
                } else {
                    input += Self.pieces.randomElement(using: &generator)!
                }
            }
            guard let jid = try? JID(input) else { continue }
            let again = try? JID(jid.description)
            #expect(again == jid, "\(input.debugDescription) -> \(jid.description.debugDescription)")
            #expect(jid.bare.resourcepart == nil)
            #expect(jid.domain.isDomainOnly)
            _ = jid.domainForDNS
        }
    }

    @Test func punycodeDecodingNeverTraps() {
        var generator = Fuzz.generator()
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789-_!Aé".unicodeScalars)
        for _ in 0..<Fuzz.iterations(4000) {
            var label = "xn--"
            for _ in 0..<Int.random(in: 0..<30, using: &generator) {
                label.unicodeScalars.append(alphabet.randomElement(using: &generator)!)
            }
            if let decoded = try? Punycode.decode(label: label),
               let encoded = try? Punycode.encode(label: decoded),
               encoded != label {
                // Several ACE strings may decode alike; re-encoding must at
                // least be stable.
                #expect((try? Punycode.encode(label: Punycode.decode(label: encoded))) == encoded)
            }
        }
    }
}
