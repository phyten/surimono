import Foundation

public enum ClipboardContent: Equatable, Sendable {
    case files([URL])
    case document(data: Data, format: DocumentFormat)
    case empty

    public init(fileURLs: [URL] = [], text: String? = nil, png: Data? = nil, tiff: Data? = nil) {
        let files = fileURLs.filter(\.isFileURL)
        if !files.isEmpty {
            self = .files(files)
        } else if let text {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                self = .empty
                return
            }
            self = .document(data: Data(text.utf8), format: Self.format(of: trimmed))
        } else if let image = [png, tiff].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
            self = .document(data: image, format: .image)
        } else {
            self = .empty
        }
    }

    /// Text fed to a live preview. Editors stream whatever is being typed, so the guess between Markdown and plain text
    /// would flip as the first markup appears; Markdown shows plain text and HTML fragments as they are anyway.
    public static func streaming(text: String?) -> ClipboardContent {
        guard let text, text.contains(where: { !$0.isWhitespace }) else { return .empty }
        let format = format(of: text.trimmingCharacters(in: .whitespacesAndNewlines))
        return .document(data: Data(text.utf8), format: format == .html ? .html : .markdown)
    }

    /// The extension of a file that keeps what opened from memory as it is.
    public static func fileExtension(of data: Data, format: DocumentFormat) -> String {
        switch format {
        case .markdown: "md"
        case .html: "html"
        case .image: data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "png" : "tiff"
        default: "txt"
        }
    }

    private static func format(of text: String) -> DocumentFormat {
        var htmlStart = text[...]
        while true {
            htmlStart = htmlStart.drop { $0.isWhitespace || $0 == "\u{FEFF}" }
            guard htmlStart.hasPrefix("<!--"), let end = htmlStart.range(of: "-->") else { break }
            htmlStart = htmlStart[end.upperBound...]
        }
        if htmlStart.range(of: #"\A(?:<!doctype\s+html\b|<html\b)"#, options: [.regularExpression, .caseInsensitive])
            != nil
        {
            return .html
        }
        let markers = [
            #"(?m)^ {0,3}(?:#{1,6}\s|[-*]\s|[0-9]+\.\s|`{3,}|~{3,}|>\s)"#,
            #"\|\s*:?-{3,}:?\s*\|"#,
            #"\*\*[^*\r\n]+\*\*"#,
            #"(?<!\w)__(?=\S)[^_\r\n]+?(?<=\S)__(?!\w)"#,
            #"\[[^\]\r\n]+\]\([^\s)]+\)"#,
            #"\$\$"#,
        ]
        return markers.contains { text.range(of: $0, options: .regularExpression) != nil } ? .markdown : .plainText
    }
}
