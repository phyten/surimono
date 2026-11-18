import SurimonoCore
import SwiftUI

/// How a text from the clipboard or a service came by its format, which the format menu tells the reader.
enum TextFormatOrigin: Equatable {
    /// The detector was sure of it.
    case automatic
    /// Settings say to always open one format.
    case settings
    /// The reader chose it, when asked or from the format menu; the text is not detected again.
    case chosen
}

extension DocumentViewModel {
    /// The kind of a text that can open again as another one, from the format menu; nil for files, images and
    /// anything else whose format is not a guess.
    var textKind: ClipboardTextKind? {
        guard textFormatOrigin != nil, textReopener != nil, memoryContent != nil else { return nil }
        return ClipboardTextKind(format)
    }

    /// The same original text as another kind. The reader chose it, so the new window does not detect it again.
    func reopenText(as kind: ClipboardTextKind) {
        guard let current = textKind, kind != current else { return }
        textReopener?(kind)
    }
}

/// The words for the kinds, the detector's reasons and its evidence, shared by the question, the band and the menus.
enum ClipboardFormatText {
    static func name(_ kind: ClipboardTextKind) -> String {
        switch kind {
        case .markdown: "Markdown"
        case .org: "Org"
        case .html: "HTML"
        case .latex: "LaTeX"
        case .notebook: "Jupyter Notebook"
        case .csv: "CSV"
        case .url: "URL"
        case .plainText: String(localized: "Plain Text")
        }
    }

    static func reason(_ question: ClipboardQuestion) -> String {
        switch question.reason {
        case .blank: String(localized: "The text has only spaces and line breaks.")
        case .ordinaryText: String(localized: "No marks of a format were found.")
        case .accepted: String(localized: "The text reads clearly as one format.")
        case .insufficientStructure:
            String(localized: "No format could be confirmed from the text’s structure.")
        // The text can be read more than one way; the reader did nothing wrong by mixing marks.
        case .conflictingSyntax: String(localized: "The text can be read as more than one format.")
        case .competingFormats:
            if question.competing.count == 2 {
                String(
                    format: String(localized: "The text reads as both %1$@ and %2$@."), name(question.competing[0]),
                    name(question.competing[1]))
            } else {
                String(localized: "The text reads as more than one format.")
            }
        case .truncated: String(localized: "The text is long, and only its beginning was read.")
        case .damagedText: String(localized: "The text contains characters that could not be read.")
        case .alwaysAsk: String(localized: "Settings say to ask every time.")
        case .fixed: String(localized: "Settings say to always open one format.")
        }
    }

    static func evidence(_ item: ClipboardFormatDetection.Evidence, of kind: ClipboardTextKind) -> String {
        switch item {
        case .headings(let count): String(localized: "Headings: \(count)")
        case .lists(let count): String(localized: "List items: \(count)")
        case .codeBlocks(let count): String(localized: "Code blocks: \(count)")
        case .tables(let count): String(localized: "Tables: \(count)")
        case .markup(let count):
            kind == .latex ? String(localized: "Commands: \(count)") : String(localized: "Tags: \(count)")
        case .metadata(let count): String(localized: "Setting lines: \(count)")
        case .links(let count): String(localized: "Links: \(count)")
        case .document: String(localized: "Starts as a whole document")
        case .pasteboard: String(localized: "Copied as a table from a spreadsheet")
        case .incomplete: String(localized: "Seems to stop partway")
        case .conflictingSyntax: String(localized: "Also has marks of another format")
        case .damagedText: String(localized: "Has characters that could not be read")
        }
    }

    /// The evidence of one choice on a line. Text needs none: it changes nothing. Marks of another format are the
    /// question's reason, said once above the choices rather than on each of them.
    static func evidence(of option: ClipboardQuestion.Option) -> String {
        if option.kind == .plainText { return String(localized: "Marks shown as they are") }
        let items = option.evidence.filter { $0 != .conflictingSyntax }
        guard !items.isEmpty else { return String(localized: "No marks of this format were found") }
        return items.map { evidence($0, of: option.kind) }.joined(separator: " · ")
    }

    /// The tooltip of the format on the band, which says whether the app chose it.
    static func help(kind: ClipboardTextKind, origin: TextFormatOrigin?) -> String {
        let name = name(kind)
        let format: String =
            switch origin {
            case .automatic: String(format: String(localized: "Format: %@, chosen automatically"), name)
            case .settings: String(format: String(localized: "Format: %@, as set in Settings"), name)
            case .chosen, nil: String(format: String(localized: "Format: %@"), name)
            }
        return format + " · " + String(localized: "Choose another format to open the same text again.")
    }

    /// The format's name in the More menu, marked when the app chose it.
    static func value(kind: ClipboardTextKind, origin: TextFormatOrigin?) -> String {
        origin == .automatic ? String(format: String(localized: "%@ (Automatic)"), name(kind)) : name(kind)
    }
}

/// The kinds a text can open again as, with the current one checked.
struct TextFormatPicker: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        Picker(
            "Open As",
            selection: Binding(
                get: { model.textKind ?? .plainText }, set: { model.reopenText(as: $0) })
        ) {
            ForEach(ClipboardTextKind.choosable, id: \.self) { kind in
                Text(verbatim: ClipboardFormatText.name(kind)).tag(kind)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

/// The format on the band, as a menu for a text whose format was a guess. Both the measured and the drawn band show
/// this same view, so their widths agree.
struct TextFormatBadgeMenu: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        let kind = model.textKind ?? .plainText
        Menu {
            TextFormatPicker(model: model)
        } label: {
            HStack(spacing: 2) {
                FormatBadge(text: model.formatBadge)
                BandMenuChevron()
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(ClipboardFormatText.help(kind: kind, origin: model.textFormatOrigin))
        .accessibilityLabel(Text("Format"))
        .accessibilityValue(Text(verbatim: ClipboardFormatText.value(kind: kind, origin: model.textFormatOrigin)))
    }
}
