import UniformTypeIdentifiers

public enum DocumentFormat: String, CaseIterable, Codable, Sendable {
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
        case "csv", "tsv": self = .csv
        case "png", "jpg", "jpeg", "gif", "tif", "tiff", "heic", "heif", "webp", "bmp", "svg", "ico", "icns":
            self = .image
        default: return nil
        }
    }

    public var usesPrintTheme: Bool { [.markdown, .org, .plainText, .csv].contains(self) }
    public var usesHTMLPreset: Bool { self == .html }
    public var isWebRendered: Bool { self != .pdf && self != .image }

    public init?(contentType: UTType) {
        // Recognize known types independently of LaunchServices registration.
        let known: [String: DocumentFormat] = [
            "net.daringfireball.markdown": .markdown, "org.orgmode.org": .org,
            "public.plain-text": .plainText, "public.text": .plainText, "public.utf8-plain-text": .plainText,
            "public.html": .html, "com.adobe.pdf": .pdf, "public.image": .image,
            "public.png": .image, "public.jpeg": .image, "public.comma-separated-values-text": .csv,
            "public.tab-separated-values-text": .csv,
        ]
        if let format = known[contentType.identifier] {
            self = format
            return
        }
        if let suffix = contentType.preferredFilenameExtension, let format = Self(fileExtension: suffix) {
            self = format
            return
        }
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
