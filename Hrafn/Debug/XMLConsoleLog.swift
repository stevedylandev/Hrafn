import Foundation
import Observation
import XMPPXML

/// Keeps the last few hundred stanzas from every session for the debug console.
/// `log` is called from the sessions' threads; lines are published on the main actor.
nonisolated final class XMLConsoleLog: XMLConsole, @unchecked Sendable {
    let lines: XMLConsoleLines

    @MainActor init() {
        lines = XMLConsoleLines()
    }

    func log(_ direction: XMLDirection, _ xml: String) {
        let line = XMLConsoleLines.Line(direction: direction, xml: xml, date: Date())
        Task { @MainActor [lines] in lines.append(line) }
    }
}

@MainActor
@Observable
final class XMLConsoleLines {
    struct Line: Identifiable, Sendable {
        let id = UUID()
        let direction: XMLDirection
        let xml: String
        let date: Date
    }

    private(set) var items: [Line] = []
    static let limit = 500

    func append(_ line: Line) {
        items.append(line)
        if items.count > Self.limit { items.removeFirst(items.count - Self.limit) }
    }

    func clear() { items.removeAll() }
}
