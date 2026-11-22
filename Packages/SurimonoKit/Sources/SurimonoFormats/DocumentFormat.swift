import UniformTypeIdentifiers

public enum DocumentFormat: String, CaseIterable, Codable, Sendable {
    case markdown
    case org
    case plainText
    case html
    case pdf
    case image
    case csv
    case zipArchive
    case latex
    case asciidoc
    case quarto
    case rMarkdown = "rmarkdown"
    case djot
    case textile
    case mediawiki
    case rst
    case docx
    case notebook
    case graphviz
    case plantuml

    public init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "md", "markdown", "mdown", "mkd", "mkdn": self = .markdown
        case "org": self = .org
        case "txt", "text", "json", "jsonl", "ndjson", "log", "yaml", "yml", "toml", "xml": self = .plainText
        case "html", "htm": self = .html
        case "pdf": self = .pdf
        case "csv", "tsv": self = .csv
        case "zip": self = .zipArchive
        case "tex", "latex", "ltx": self = .latex
        case "qmd": self = .quarto
        case "rmd", "rmarkdown": self = .rMarkdown
        case "dj", "djot": self = .djot
        case "docx": self = .docx
        case "textile": self = .textile
        case "rst", "rest": self = .rst
        case "mediawiki", "wiki", "wikitext": self = .mediawiki
        case "adoc", "asciidoc": self = .asciidoc
        case "ipynb": self = .notebook
        case "dot", "gv": self = .graphviz
        case "puml", "plantuml", "pu", "iuml", "wsd": self = .plantuml
        case "png", "jpg", "jpeg", "gif", "tif", "tiff", "heic", "heif", "webp", "bmp", "svg", "ico", "icns":
            self = .image
        default: return nil
        }
    }

    public var usesPrintTheme: Bool {
        [
            .markdown, .org, .plainText, .csv, .latex, .asciidoc, .quarto, .rMarkdown, .djot, .textile, .mediawiki,
            .rst,
            .docx,
            .notebook,
            .graphviz, .plantuml,
        ]
        .contains(self)
    }
    public var supportsChangeMarks: Bool { usesPrintTheme && self != .graphviz && self != .plantuml }

    public var usesHTMLPreset: Bool { self == .html }
    public var isWebRendered: Bool { self != .pdf && self != .image && self != .zipArchive }

    public init?(contentType: UTType) {
        // Recognize known types independently of LaunchServices registration.
        let known: [String: DocumentFormat] = [
            "net.daringfireball.markdown": .markdown, "org.orgmode.org": .org,
            "public.plain-text": .plainText, "public.text": .plainText, "public.utf8-plain-text": .plainText,
            "public.json": .plainText, "public.yaml": .plainText, "public.xml": .plainText,
            "public.ndjson": .plainText, "com.apple.log": .plainText, "org.toml-lang.toml": .plainText,
            "app.surimono.jsonl": .plainText,
            "public.xhtml": .html, "public.html": .html, "com.adobe.pdf": .pdf, "public.image": .image,
            "public.png": .image, "public.jpeg": .image, "public.comma-separated-values-text": .csv,
            "public.tab-separated-values-text": .csv,
            "org.graphviz.dot": .graphviz, "net.sourceforge.plantuml": .plantuml,
            "public.zip-archive": .zipArchive, "org.tug.tex": .latex, "org.jupyter.ipynb": .notebook,
            "org.quarto.qmarkdown": .quarto, "org.rstudio.rmarkdown": .rMarkdown,
            "org.openxmlformats.wordprocessingml.document": .docx,
            "net.djot.djot": .djot,
            "org.textile-lang.textile": .textile,
            "app.surimono.restructuredtext": .rst,
            "org.mediawiki.wikitext": .mediawiki,
            "org.asciidoc.asciidoc": .asciidoc,
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
        } else if contentType.conforms(to: .surimonoQuarto) {
            self = .quarto
        } else if contentType.conforms(to: .surimonoRMarkdown) {
            self = .rMarkdown
        } else if contentType.conforms(to: .surimonoDjot) {
            self = .djot
        } else if contentType.conforms(to: .surimonoMediaWiki) {
            self = .mediawiki
        } else if contentType.conforms(to: .surimonoRST) {
            self = .rst
        } else if contentType.conforms(to: .surimonoTextile) {
            self = .textile
        } else if contentType.conforms(to: .surimonoAsciiDoc) {
            self = .asciidoc
        } else if contentType.conforms(to: .surimonoNotebook) {
            self = .notebook
        } else if contentType.conforms(to: .surimonoGraphviz) {
            self = .graphviz
        } else if contentType.conforms(to: .surimonoPlantUML) {
            self = .plantuml
        } else if contentType.conforms(to: .surimonoLaTeX) {
            self = .latex
        } else if contentType.conforms(to: .commaSeparatedText) {
            self = .csv
        } else if contentType.conforms(to: .html) {
            self = .html
        } else if contentType.conforms(to: .pdf) {
            self = .pdf
        } else if contentType.conforms(to: .image) {
            self = .image
        } else if contentType.conforms(to: .zip) {
            self = .zipArchive
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
        case .zipArchive: "ZIP"
        case .latex: "LaTeX"
        case .quarto: "Quarto"
        case .rMarkdown: "R Markdown"
        case .djot: "Djot"
        case .textile: "Textile"
        case .rst: "reStructuredText"
        case .mediawiki: "MediaWiki"
        case .docx: "Word"
        case .asciidoc: "AsciiDoc"
        case .notebook: "Jupyter Notebook"
        case .graphviz: "Graphviz"
        case .plantuml: "PlantUML"
        }
    }
}

extension UTType {
    // With competing imports for the same extension, importedAs: can return another app’s type.
    // Prefer our declared identifier; a standalone package client may have no registered declaration yet.
    public static let surimonoJSONLines =
        UTType("app.surimono.jsonl") ?? UTType(importedAs: "app.surimono.jsonl", conformingTo: .plainText)
    public static let surimonoTOML = UTType(importedAs: "org.toml-lang.toml", conformingTo: .plainText)
    public static let surimonoGraphviz = UTType(importedAs: "org.graphviz.dot", conformingTo: .plainText)
    public static let surimonoPlantUML = UTType(importedAs: "net.sourceforge.plantuml", conformingTo: .plainText)
    public static let surimonoQuarto = UTType(importedAs: "org.quarto.qmarkdown", conformingTo: .plainText)
    public static let surimonoRMarkdown = UTType(importedAs: "org.rstudio.rmarkdown", conformingTo: .plainText)
    public static let surimonoDjot = UTType(importedAs: "net.djot.djot", conformingTo: .plainText)
    public static let surimonoTextile = UTType(importedAs: "org.textile-lang.textile", conformingTo: .plainText)
    public static let surimonoRST =
        UTType("app.surimono.restructuredtext")
        ?? UTType(importedAs: "app.surimono.restructuredtext", conformingTo: .plainText)
    public static let surimonoMediaWiki = UTType(importedAs: "org.mediawiki.wikitext", conformingTo: .plainText)
    public static let surimonoAsciiDoc = UTType(importedAs: "org.asciidoc.asciidoc", conformingTo: .plainText)
    public static let surimonoNotebook = UTType(importedAs: "org.jupyter.ipynb", conformingTo: .json)
    public static let surimonoMarkdown = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
    public static let surimonoOrg = UTType(importedAs: "org.orgmode.org", conformingTo: .plainText)
    /// The identifier TeX distributions and editors on the Mac use for `.tex` files.
    public static let surimonoLaTeX = UTType(importedAs: "org.tug.tex", conformingTo: .plainText)
}
