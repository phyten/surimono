import Foundation

extension ClipboardTextKind {
    /// The kinds a reader can choose, in the order every list of them follows. Opening a URL is not built yet, so it
    /// is never offered.
    public static let choosable: [ClipboardTextKind] = [.markdown, .org, .html, .latex, .csv, .notebook, .plainText]

    /// The format a document of this kind opens as. A URL opens as text until the app can load the page it names.
    public var documentFormat: DocumentFormat {
        switch self {
        case .markdown: .markdown
        case .org: .org
        case .html: .html
        case .latex: .latex
        case .notebook: .notebook
        case .csv: .csv
        case .url, .plainText: .plainText
        }
    }

    public init?(_ format: DocumentFormat) {
        guard let kind = Self.choosable.first(where: { $0.documentFormat == format }) else { return nil }
        self = kind
    }
}

/// What the question about unsure clipboard text offers: the formats worth a row, the rest folded under Other Formats,
/// and the first lines of the text, so that the reader sees what is about to open.
public struct ClipboardQuestion: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public let kind: ClipboardTextKind
        public let evidence: [ClipboardFormatDetection.Evidence]
    }

    public let reason: ClipboardFormatDetection.Reason
    public let preferred: ClipboardTextKind
    public let options: [Option]
    public let others: [Option]
    public let preview: [String]
    /// The preview leaves out lines, or the end of a line.
    public let isPreviewCut: Bool
    /// The two formats the text reads as equally well, when that is why the reader is asked.
    public let competing: [ClipboardTextKind]

    public static let previewLines = 5
    public static let previewColumns = 72

    public init(text: String, detection: ClipboardFormatDetection, settings: ClipboardFormatSettings) {
        reason = detection.reason
        let preferred: ClipboardTextKind =
            switch detection.action {
            case .ask(let kind), .open(let kind): Self.choosable(kind)
            }
        self.preferred = preferred
        let choices = detection.choices.filter { $0.kind != .url }
        // A format turned off for automatic opening stays a choice, folded away with the formats nothing pointed to.
        let shown = choices.filter { choice in
            choice.kind == preferred || choice.kind == .plainText
                || (choice.confidence > 0 && settings.automaticKinds.contains(choice.kind))
        }
        // The formats in the detector's order, then Text, which is always the last row whatever it scored.
        options = (shown.filter { $0.kind != .plainText } + shown.filter { $0.kind == .plainText }).map {
            Option(kind: $0.kind, evidence: $0.evidence)
        }
        let listed = Set(shown.map(\.kind))
        others = ClipboardTextKind.choosable.filter { !listed.contains($0) }.map { kind in
            Option(kind: kind, evidence: choices.first { $0.kind == kind && $0.confidence > 0 }?.evidence ?? [])
        }
        competing =
            detection.reason == .competingFormats
            ? Array(choices.filter { $0.kind != .plainText && $0.confidence > 0.5 }.map(\.kind).prefix(2)) : []
        (preview, isPreviewCut) = Self.preview(of: text)
    }

    private static func choosable(_ kind: ClipboardTextKind) -> ClipboardTextKind {
        ClipboardTextKind.choosable.contains(kind) ? kind : .plainText
    }

    /// The first lines as they are, with tabs widened so that a table's columns still show apart.
    static func preview(of text: String) -> ([String], Bool) {
        let lines = TextDecoding.normalizeNewlines(String(text.prefix(8_192))).split(
            separator: "\n", omittingEmptySubsequences: false)
        let start = lines.firstIndex { $0.contains { !$0.isWhitespace } } ?? lines.endIndex
        var shown: [String] = []
        var cut = text.count > 8_192
        for line in lines[start...] {
            if shown.count == previewLines {
                if line.contains(where: { !$0.isWhitespace }) { cut = true }
                if cut { break }
                continue
            }
            var visible = line.replacingOccurrences(of: "\t", with: "    ")
            while let last = visible.last, last.isWhitespace { visible.removeLast() }
            if visible.count > previewColumns {
                visible = String(visible.prefix(previewColumns - 1)) + "…"
                cut = true
            }
            shown.append(visible)
        }
        while shown.last?.isEmpty == true { shown.removeLast() }
        return (shown, cut)
    }
}
