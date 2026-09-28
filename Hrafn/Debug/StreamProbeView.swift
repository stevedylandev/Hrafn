import SwiftUI
import XMPPXML

/// Debug screen for Phase 1: dial a server, watch the stream negotiate, read the
/// raw XML with credentials redacted.
struct StreamProbeView: View {
    @State private var probe = StreamProbe()

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    LabeledContent("Domain") {
                        TextField("example.com", text: $probe.domain)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Host override") {
                        TextField("SRV lookup", text: $probe.hostOverride)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Port") {
                        TextField("5222", text: $probe.portOverride)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Toggle("Direct TLS (XEP-0368)", isOn: $probe.useDirectTLS)
                    Toggle("Accept any certificate", isOn: $probe.acceptAnyCertificate)
                }

                Section("Status") {
                    Text(probe.status.label)
                        .font(.footnote)
                        .foregroundStyle(isFailed ? .red : .primary)
                    ForEach(probe.endpoints, id: \.self) { endpoint in
                        Text(endpoint).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Button("Open stream") { probe.connect() }
                }

                Section("XML console") {
                    ForEach(probe.log) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Text(line.direction.arrow)
                                .foregroundStyle(line.direction == .sent ? .blue : .green)
                            Text(line.xml)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .themed()
            .navigationTitle("Hrafn · Stream probe")
        }
    }

    private var isFailed: Bool {
        if case .failed = probe.status { return true }
        return false
    }
}

#Preview {
    StreamProbeView()
}
