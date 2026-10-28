import UniformTypeIdentifiers

public enum DocumentFormat: String, CaseIterable, Sendable {
    case markdown
    case org
    case plainText
    case html
    case pdf
    case image
    case csv

    public init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "md", "markdown", "mdown", "mkd", "mkdn": self = .markdown
        case "org": self = .org
        case "txt", "text": self = .plainText
        case "html", "htm": self = .html
        case "pdf": self = .pdf
        case "csv": self = .csv
        case "png", "jpg", "jpeg", "gif", "tif", "tiff", "heic", "heif", "webp", "bmp", "svg", "ico", "icns":
            self = .image
        default: return nil
        }
    }

    public init?(contentType: UTType) {
        if contentType.conforms(to: .surimonoMarkdown) {
            self = .markdown
        } else if contentType.conforms(to: .surimonoOrg) {
            self = .org
        } else if contentType.conforms(to: .commaSeparatedText) {
            self = .csv
        } else if contentType.conforms(to: .html) {
            self = .html
        } else if contentType.conforms(to: .pdf) {
            self = .pdf
        } else if contentType.conforms(to: .image) {
            self = .image
        } else if contentType.conforms(to: .text) {
            self = .plainText
        } else {
            return nil
        }
    }

    public var displayName: String {
        switch self {
        case .markdown: "Markdown"
        case .org: "Org"
        case .plainText: "Plain Text"
        case .html: "HTML"
        case .pdf: "PDF"
        case .image: "Image"
        case .csv: "CSV"
        }
    }
}

extension UTType {
    public static let surimonoMarkdown = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
    public static let surimonoOrg = UTType(importedAs: "org.orgmode.org", conformingTo: .plainText)
}
