import XMPPXML

extension Namespaces {
    /// RFC 6121 §2.
    public static let roster = "jabber:iq:roster"
    /// RFC 6121 §2.6: the stream feature advertising roster versioning.
    public static let rosterVersioning = "urn:xmpp:features:rosterver"
    /// XEP-0184.
    public static let receipts = "urn:xmpp:receipts"
    /// XEP-0085.
    public static let chatStates = "http://jabber.org/protocol/chatstates"
    /// XEP-0333.
    public static let chatMarkers = "urn:xmpp:chat-markers:0"
    /// XEP-0280.
    public static let carbons = "urn:xmpp:carbons:2"
    /// XEP-0297.
    public static let forward = "urn:xmpp:forward:0"
    /// XEP-0203.
    public static let delay = "urn:xmpp:delay"
    /// XEP-0313.
    public static let mam = "urn:xmpp:mam:2"
    /// XEP-0059.
    public static let rsm = "http://jabber.org/protocol/rsm"
    /// XEP-0359.
    public static let stableIDs = "urn:xmpp:sid:0"
    /// XEP-0308.
    public static let correction = "urn:xmpp:message-correct:0"
    /// XEP-0424.
    public static let retraction = "urn:xmpp:message-retract:1"
    /// XEP-0428.
    public static let fallback = "urn:xmpp:fallback:0"
    /// XEP-0334.
    public static let hints = "urn:xmpp:hints"
    /// XEP-0191.
    public static let blocking = "urn:xmpp:blocking"
}

/// The features a client implementing this module advertises in disco, so
/// peers know to send receipts, markers, corrections, retractions,
/// reactions and replies, and that we render message styling.
public enum IMFeatures {
    public static let all = [
        Namespaces.receipts,
        Namespaces.chatStates,
        Namespaces.chatMarkers,
        Namespaces.correction,
        Namespaces.retraction,
        Namespaces.reactions,
        Namespaces.reply,
        Namespaces.styling,
    ]
}
