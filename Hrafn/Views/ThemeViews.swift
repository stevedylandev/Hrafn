import SwiftUI
import UIKit

/// The base16 theme for light or dark mode: the system's, a preset, or one
/// of the user's own.
struct ThemePickerView: View {
    let colorScheme: ColorScheme

    @Environment(AppModel.self) private var app
    @State private var editing: Base16Scheme?
    @State private var importFailed = false

    private var selection: String? {
        colorScheme == .dark ? app.appearance.darkTheme : app.appearance.lightTheme
    }

    private func select(_ id: String?) {
        if colorScheme == .dark { app.appearance.darkTheme = id } else { app.appearance.lightTheme = id }
    }

    var body: some View {
        let presets = Base16Scheme.presets.filter { $0.isDark == (colorScheme == .dark) }
        let custom = app.appearance.customSchemes ?? []
        List {
            Group {
                Section {
                    row(name: String(localized: "System"), scheme: nil)
                }
                Section("Themes") {
                    ForEach(presets) { row(name: $0.name, scheme: $0) }
                }
                Section {
                    ForEach(custom) { scheme in
                        row(name: scheme.name, scheme: scheme)
                            .swipeActions {
                                Button("Delete", role: .destructive) { delete(scheme) }
                                Button("Edit") { editing = scheme }
                            }
                            .contextMenu {
                                Button { editing = scheme } label: { Label("Edit", systemImage: "pencil") }
                                Button {
                                    UIPasteboard.general.string = scheme.yaml
                                } label: { Label("Copy as base16 YAML", systemImage: "doc.on.doc") }
                                Button(role: .destructive) { delete(scheme) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                    Button {
                        let base = app.appearance.scheme(id: selection) ?? presets.first ?? Base16Scheme.presets[0]
                        editing = Base16Scheme(id: "custom-" + UUID().uuidString,
                                               name: String(localized: "\(base.name) Copy"), colors: base.colors)
                    } label: {
                        Label("New Theme", systemImage: "plus")
                    }
                    Button(action: importFromClipboard) {
                        Label("Paste base16 YAML", systemImage: "doc.on.clipboard")
                    }
                } header: {
                    Text("Custom")
                } footer: {
                    Text("Any base16 scheme works: copy its YAML file, then paste it here. Custom themes can be used in light and dark mode.")
                }
            }
            .themedCells()
        }
        .themed()
        .navigationTitle(colorScheme == .dark ? "Dark Theme" : "Light Theme")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { scheme in
            ThemeEditorView(scheme: scheme) { saved in
                save(saved)
                select(saved.id)
            }
        }
        .alert("Couldn't Read Theme", isPresented: $importFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The clipboard needs a base16 scheme: base00 to base0F, each a hex colour.")
        }
    }

    private func row(name: String, scheme: Base16Scheme?) -> some View {
        Button {
            select(scheme?.id)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(name).foregroundStyle(scheme.map { $0[5] } ?? .primary)
                    if let scheme { Swatches(scheme: scheme) }
                }
                Spacer()
                if selection == scheme?.id {
                    Image(systemName: "checkmark").foregroundStyle(scheme.map { $0[13] } ?? .accentColor)
                        .accessibilityLabel("Selected")
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Each theme on its own background, so it can be seen before choosing.
        .listRowBackground(scheme.map { $0[0] })
    }

    private func importFromClipboard() {
        guard let text = UIPasteboard.general.string, let scheme = Base16Scheme.parse(yaml: text) else {
            importFailed = true
            return
        }
        editing = scheme
    }

    private func save(_ scheme: Base16Scheme) {
        var custom = app.appearance.customSchemes ?? []
        if let index = custom.firstIndex(where: { $0.id == scheme.id }) {
            custom[index] = scheme
        } else {
            custom.append(scheme)
        }
        app.appearance.customSchemes = custom
    }

    private func delete(_ scheme: Base16Scheme) {
        if app.appearance.lightTheme == scheme.id { app.appearance.lightTheme = nil }
        if app.appearance.darkTheme == scheme.id { app.appearance.darkTheme = nil }
        app.appearance.customSchemes?.removeAll { $0.id == scheme.id }
    }
}

/// A scheme's colours in a strip: the background tones, then the accents.
struct Swatches: View {
    let scheme: Base16Scheme
    var size: CGFloat = 14

    var body: some View {
        HStack(spacing: 3) {
            ForEach([1, 2, 3, 5, 8, 9, 10, 11, 12, 13, 14], id: \.self) { index in
                RoundedRectangle(cornerRadius: 3)
                    .fill(scheme[index])
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Edit a custom theme's name and sixteen colours.
struct ThemeEditorView: View {
    let onSave: (Base16Scheme) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scheme: Base16Scheme
    @State private var importFailed = false

    init(scheme: Base16Scheme, onSave: @escaping (Base16Scheme) -> Void) {
        _scheme = State(initialValue: scheme)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        TextField("Name", text: $scheme.name)
                        Swatches(scheme: scheme, size: 18)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .listRowBackground(scheme[0])
                    }
                    Section {
                        ForEach(0..<16, id: \.self) { index in
                            ColorPicker(selection: color(index), supportsOpacity: false) {
                                VStack(alignment: .leading) {
                                    Text(verbatim: String(format: "base0%X", index)).font(.body.monospaced())
                                    Text(LocalizedStringKey(Base16Scheme.roles[index]))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Colours")
                    } footer: {
                        Text("base00 is the background, base01 cards and message bubbles, base02 reactions, base05 text and base0D the accent.")
                    }
                    Section {
                        Button {
                            UIPasteboard.general.string = scheme.yaml
                        } label: { Label("Copy as base16 YAML", systemImage: "doc.on.doc") }
                        Button {
                            guard let text = UIPasteboard.general.string,
                                  let pasted = Base16Scheme.parse(yaml: text) else {
                                importFailed = true
                                return
                            }
                            scheme.colors = pasted.colors
                        } label: { Label("Paste base16 YAML", systemImage: "doc.on.clipboard") }
                    }
                }
                .themedCells()
            }
            .themed()
            .navigationTitle("Theme")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if scheme.name.trimmingCharacters(in: .whitespaces).isEmpty {
                            scheme.name = String(localized: "Custom")
                        }
                        onSave(scheme)
                        dismiss()
                    }
                }
            }
            .alert("Couldn't Read Theme", isPresented: $importFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The clipboard needs a base16 scheme: base00 to base0F, each a hex colour.")
            }
        }
    }

    private func color(_ index: Int) -> Binding<Color> {
        Binding(get: { scheme[index] },
                set: { if let hex = $0.hex { scheme.colors[index] = hex } })
    }
}
