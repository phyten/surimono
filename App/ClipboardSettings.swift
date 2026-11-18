import SurimonoCore
import SwiftUI

/// Settings' Clipboard section: how text from the clipboard or a service gets its format.
struct ClipboardSettings: View {
    @Bindable var preferences: AppPreferences

    private typealias Mode = ClipboardFormatSettings.Mode
    private typealias Carefulness = ClipboardFormatSettings.Carefulness

    /// The kinds the detector may open without asking. Text is always a choice, and a URL opens as text for now.
    private static let recognizable: [ClipboardTextKind] = [.markdown, .org, .html, .latex, .csv, .notebook]

    var body: some View {
        Section {
            Picker("Choosing the Format", selection: $preferences.clipboardFormat.mode) {
                Text("Ask When Unsure").tag(Mode.askWhenUnsure)
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
            // Opening every text in one format asks the detector nothing, so how readily it formats would change
            // nothing there; the format to open takes its place.
            if preferences.clipboardFormat.mode != .fixed {
                Picker("How Readily to Format", selection: $preferences.clipboardFormat.carefulness) {
                    Text("Careful").tag(Carefulness.careful)
                    Text("Standard").tag(Carefulness.standard)
                    Text("Eager").tag(Carefulness.eager)
                }
                .pickerStyle(.segmented)
            }
        } header: {
            Text("When Opening from the Clipboard")
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                if let note = Self.carefulnessNote(for: preferences.clipboardFormat) {
                    SettingsFootnote(verbatim: note)
                }
                SettingsFootnote("Text from the Services menu uses the same settings.")
            }
        }
        Section {
            ForEach(Self.recognizable, id: \.self) { kind in
                Toggle(isOn: recognizes(kind)) {
                    Text(verbatim: kind == .csv ? String(localized: "CSV and TSV") : ClipboardFormatText.name(kind))
                }
            }
        } header: {
            Text("Formats to Recognize Automatically")
        } footer: {
            VStack(alignment: .leading, spacing: 10) {
                SettingsFootnote(
                    "A format turned off can still be chosen when asked and from the format menu after opening.")
                // Not a group of its own: one button needs no box.
                HStack {
                    Spacer()
                    Button("Back to Standard") { preferences.clipboardFormat = .standard }
                        .disabled(preferences.clipboardFormat == .standard)
                }
            }
        }
    }

    /// What the chosen level does to text a reader can recognize, rather than the detector's criterion; the examples and
    /// the order of the levels behind each sentence are in `ClipboardCarefulnessNoteTests`. Nil where it cannot come
    /// true: every sentence is about Markdown opening formatted without a question, which needs a mode that opens text
    /// on its own and Markdown among the formats recognized.
    static func carefulnessNote(for settings: ClipboardFormatSettings) -> String? {
        guard settings.mode == .askWhenUnsure || settings.mode == .plainTextWhenUnsure,
            settings.automaticKinds.contains(.markdown)
        else { return nil }
        return switch settings.carefulness {
        case .careful:
            String(
                localized: "Formats less than Standard. A note of headings, sentences and a list may stay unformatted.")
        case .standard: String(localized: "Usually also formats notes of headings, sentences and a list.")
        case .eager: String(localized: "May format even a heading with numbered steps.")
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
