import Foundation
import XMPPClient
import XMPPCore
import XMPPXML

/// XEP-0313 message archive queries, paged with XEP-0059.
///
/// Results arrive as messages ahead of the IQ that ends the query. They are
/// claimed by an interceptor on the client, so they never reach `events`, and
/// returned together with the page.
public final class MessageArchive: Sendable {

    /// Which way to page.
    public enum Page: Sendable, Equatable {
        /// Oldest first, starting after this archive id (`nil`: from the start
        /// of the time range). Catch-up after being offline.
        case after(String?)
        /// The page ending just before this archive id (`nil`: the newest
        /// page). Scrolling back through history.
        case before(String?)
    }

    public struct Query: Sendable, Equatable {
        public var with: JID?
        public var start: Date?
        public var end: Date?
        public var page: Page
        public var max: Int

        public init(with: JID? = nil, start: Date? = nil, end: Date? = nil,
                    page: Page = .before(nil), max: Int = 50) {
            self.with = with
            self.start = start
            self.end = end
            self.page = page
            self.max = max
        }
    }

    public struct Result: Sendable {
        /// In archive order, oldest first.
        public var messages: [InboundMessage]
        /// There is nothing further in the direction paged.
        public var complete: Bool
        /// Archive ids bounding this page, for the next request.
        public var first: String?
        public var last: String?
    }

    private let collector = Collector()
    public let client: XMPPClient

    /// Installs the result interceptor; create one per client.
    public init(client: XMPPClient) async {
        self.client = client
        let collector = self.collector
        await client.addMessageInterceptor { message in
            collector.claim(message)
        }
    }

    /// Queries the user's own archive (`archive == nil`) or another one, such
    /// as a room's.
    public func query(_ query: Query, archive: JID? = nil, timeout: Duration = .seconds(60)) async throws -> Result {
        guard let account = await client.jid?.bare else { throw ClientError.notConnected }
        let queryID = StanzaID.make()
        collector.begin(queryID, archive: archive ?? account, account: account)
        defer { collector.end(queryID) }

        let reply = try await client.send(IQ(type: .set, to: archive, payload: Self.element(for: query, id: queryID)),
                                          timeout: timeout)
        let fin = reply.payload.flatMap { $0.matches(name: "fin", namespaceURI: Namespaces.mam) ? $0 : nil }
        let set = fin?.firstChild(name: "set", namespaceURI: Namespaces.rsm)
        return Result(
            messages: collector.end(queryID),
            complete: fin?["complete"] == "true",
            first: set?.firstChild(name: "first", namespaceURI: Namespaces.rsm)?.text,
            last: set?.firstChild(name: "last", namespaceURI: Namespaces.rsm)?.text)
    }

    static func element(for query: Query, id: String) -> Element {
        var fields = [DataForm.Field(variable: "FORM_TYPE", type: "hidden", values: [Namespaces.mam])]
        if let with = query.with { fields.append(.init(variable: "with", values: [with.description])) }
        if let start = query.start { fields.append(.init(variable: "start", values: [XMPPDateTime.string(from: start)])) }
        if let end = query.end { fields.append(.init(variable: "end", values: [XMPPDateTime.string(from: end)])) }

        var set = Element(name: "set", namespaceURI: Namespaces.rsm)
        set.addChild(Element(name: "max", namespaceURI: Namespaces.rsm, text: String(query.max)))
        switch query.page {
        case .after(let id):
            if let id { set.addChild(Element(name: "after", namespaceURI: Namespaces.rsm, text: id)) }
        case .before(let id):
            // An empty `<before/>` asks for the last page (XEP-0059 §2.5).
            set.addChild(Element(name: "before", namespaceURI: Namespaces.rsm, text: id ?? ""))
        }

        var element = Element(name: "query", namespaceURI: Namespaces.mam, attributes: ["queryid": id])
        element.addChild(DataForm(type: .submit, fields: fields).element)
        element.addChild(set)
        return element
    }

    /// Lock-protected state shared with the interceptor, which runs on the
    /// client actor.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var queries: [String: (archive: JID, account: JID, messages: [InboundMessage])] = [:]

        func begin(_ id: String, archive: JID, account: JID) {
            lock.withLock { queries[id] = (archive, account, []) }
        }

        @discardableResult
        func end(_ id: String) -> [InboundMessage] {
            lock.withLock { queries.removeValue(forKey: id)?.messages ?? [] }
        }

        func claim(_ message: Message) -> Bool {
            guard let result = message.element.firstChild(name: "result", namespaceURI: Namespaces.mam),
                  let queryID = result["queryid"], let id = result["id"] else { return false }
            return lock.withLock {
                guard let entry = queries[queryID] else { return false }
                // §5.1.2: results come from the archive; for our own, the
                // server may leave `from` off. Anything else is forged.
                let from = message.from
                guard from == entry.archive || (from == nil && entry.archive == entry.account) else { return true }
                guard let forwarded = result.firstChild(name: "forwarded", namespaceURI: Namespaces.forward),
                      let inner = forwarded.firstChild(name: "message", namespaceURI: Namespaces.client)
                        .flatMap(Message.init)
                else { return true }
                let stamp = forwarded.firstChild(name: "delay", namespaceURI: Namespaces.delay)?["stamp"]
                    .flatMap(XMPPDateTime.parse)
                if let parsed = InboundMessage(archived: inner, id: id, timestamp: stamp, account: entry.account) {
                    queries[queryID]?.messages.append(parsed)
                }
                return true
            }
        }
    }
}

/// XEP-0280: copies of messages our other sessions send and receive.
public enum Carbons {
    public static func enable(on client: XMPPClient) async throws {
        _ = try await client.send(IQ(type: .set, payload: Element(name: "enable", namespaceURI: Namespaces.carbons)))
    }

    public static func disable(on client: XMPPClient) async throws {
        _ = try await client.send(IQ(type: .set, payload: Element(name: "disable", namespaceURI: Namespaces.carbons)))
    }
}
