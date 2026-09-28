import SwiftUI
import XMPPXML

/// Every session's XML, newest last, credentials redacted. Debug builds only.
struct XMLConsoleView: View {
    let lines: XMLConsoleLines
    @State private var filter = ""

    var body: some View {
        let shown = filter.isEmpty ? lines.items : lines.items.filter { $0.xml.localizedCaseInsensitiveContains(filter) }
        ScrollViewReader { proxy in
            List(shown) { line in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(line.direction == .sent ? "» sent" : "« received")
                            .foregroundStyle(line.direction == .sent ? .blue : .green)
                        Spacer()
                        Text(line.date, format: .dateTime.hour().minute().second())
                    }
                    .font(.caption2)
                    Text(line.xml)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                .id(line.id)
            }
            .themed()
            .listStyle(.plain)
            .onChange(of: lines.items.last?.id) { _, id in proxy.scrollTo(id, anchor: .bottom) }
        }
        .searchable(text: $filter, prompt: "Filter")
        .navigationTitle("XML Console")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear") { lines.clear() }
            }
        }
    }
}
