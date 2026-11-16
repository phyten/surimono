import SurimonoCore
import SwiftUI

/// Settings' Clipboard section: how text from the clipboard or a service gets its format.
struct ClipboardSettings: View {
    @Bindable var preferences: AppPreferences

    private typealias Mode = ClipboardFormatSettings.Mode
    private typealias Carefulness = ClipboardFormatSettings.Carefulness

    /// The kinds the detector may open without asking. Text is always a choice, and a URL opens as text for now.
    private static let recognizable: [ClipboardTextKind] = [.markdown, .org, .html, .latex, .csv]

    var body: some View {
        Section("When Opening from the Clipboard") {
            Picker("Choosing the Format", selection: $preferences.clipboardFormat.mode) {
                Text("Ask When Unsure (Default)").tag(Mode.askWhenUnsure)
                Text("Open as Text When Unsure").tag(Mode.plainTextWhenUnsure)
                Text("Always Ask").tag(Mode.alwaysAsk)
                Text("Always Open in One Format").tag(Mode.fixed)
            }
            if preferences.clipboardFormat.mode == .fixed {
                Picker("Format to Open", selection: $preferences.clipboardFormat.fixedKind) {
                    ForEach(ClipboardTextKind.choosable, id: \.self) { kind in
                        Text(verbatim: ClipboardFormatText.name(kind)).tag(kind)
                    }
                }
            }
            Picker("How Readily to Format", selection: $preferences.clipboardFormat.carefulness) {
                Text("Careful").tag(Carefulness.careful)
                Text("Standard").tag(Carefulness.standard)
                Text("Eager").tag(Carefulness.eager)
            }
            .pickerStyle(.segmented)
            Text(carefulnessNote).font(.caption).foregroundStyle(.secondary)
            Text("Text from the Services menu opens the same way.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Formats to Recognize Automatically") {
            ForEach(Self.recognizable, id: \.self) { kind in
                Toggle(isOn: recognizes(kind)) {
                    Text(verbatim: kind == .csv ? String(localized: "CSV and TSV") : ClipboardFormatText.name(kind))
                }
            }
            Text(
                "A format turned off is never chosen automatically, but you can still choose it when asked and from the format menu after opening. Text is always a choice."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Text(
                "After opening, the format on the toolbar opens the same text again in another format. A format you choose is not detected again."
            )
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Back to Standard") { preferences.clipboardFormat = .standard }
                    .disabled(preferences.clipboardFormat == .standard)
            }
        }
    }

    private var carefulnessNote: String {
        switch preferences.clipboardFormat.carefulness {
        case .careful:
            String(
                localized:
                    "Formats only text that is clearly one format. You are asked more often, or it opens as text.")
        case .standard: String(localized: "Formats text whose structure is confirmed. This is the default.")
        case .eager: String(localized: "Formats text whose structure is confirmed, even from weaker marks.")
        }
    }

    private func recognizes(_ kind: ClipboardTextKind) -> Binding<Bool> {
        Binding(
            get: { preferences.clipboardFormat.automaticKinds.contains(kind) },
            set: { isOn in
                if isOn {
                    preferences.clipboardFormat.automaticKinds.insert(kind)
                } else {
                    preferences.clipboardFormat.automaticKinds.remove(kind)
                }
            })
    }
}
