import AppKit
import CoreText

struct RichTextFigure {
    let size: CGSize
    let alt: String

    init(size: CGSize, alt: String) {
        self.size = size
        self.alt = alt
    }

    init(fields: [String: Any]) throws {
        guard let width = fields["width"] as? Double, let height = fields["height"] as? Double,
            width.isFinite, height.isFinite, width > 0, height > 0, let alt = fields["alt"] as? String
        else { throw CocoaError(.fileReadCorruptFile) }
        self.init(size: CGSize(width: width, height: height), alt: alt)
    }
}

@MainActor
public struct RichTextExport {
    // A family in the document can come from an embedded web font or a user's private font library.
    // The copy can also opt in to the two bundled faces, independently of this system list.
    static let systemFonts: [String] = {
        let fonts = CTFontCollectionCreateFromAvailableFonts(nil)
        let descriptors = CTFontCollectionCreateMatchingFontDescriptors(fonts) as? [CTFontDescriptor] ?? []
        var families: Set<String> = ["serif", "sans-serif", "monospace", "system-ui", "-apple-system"]
        for descriptor in descriptors {
            guard let url = CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute) as? URL,
                url.path.hasPrefix("/System/Library/"),
                let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String
            else { continue }
            families.insert(family)
        }
        return families.sorted()
    }()

    static let styleSheet = """
        body { color: black; } a { text-decoration: underline; }
        table { border-collapse: collapse; } th, td { border: 0.5pt solid black; padding: 3pt; }
        code, pre, kbd, samp { font-family: Menlo, monospace; }
        h1 { font-size: 2em; } h2 { font-size: 1.5em; } h3 { font-size: 1.25em; }
        h4 { font-size: 1.1em; } h5, h6 { font-size: 1em; }
        """
    public let html: String
    public let plain: String
    public let rtfd: FileWrapper
    public let rtf: Data

    init(html: String, figures: [RichTextFigure]) throws {
        let imported = try NSMutableAttributedString(
            data: Data(html.utf8),
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ], documentAttributes: nil)
        self.html = html
        let text = try Self.prepare(imported, figures: figures)
        plain = text.string
        rtf = try text.data(
            from: NSRange(location: 0, length: text.length),
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.rtf
            ])
        rtfd = try imported.fileWrapper(
            from: NSRange(location: 0, length: imported.length),
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.rtfd
            ])
    }

    static func prepare(_ imported: NSMutableAttributedString, figures: [RichTextFigure]) throws -> NSAttributedString {
        let range = NSRange(location: 0, length: imported.length)
        imported.removeAttribute(.backgroundColor, range: range)
        var attachments: [(NSTextAttachment, NSRange)] = []
        imported.enumerateAttribute(.attachment, in: range) { value, run, _ in
            if let attachment = value as? NSTextAttachment {
                for offset in run.location..<NSMaxRange(run) {
                    attachments.append((attachment, NSRange(location: offset, length: 1)))
                }
            }
        }
        guard figures.count == attachments.count else { throw CocoaError(.fileReadCorruptFile) }
        let text = NSMutableAttributedString(attributedString: imported)
        for index in attachments.indices.reversed() {
            let (attachment, run) = attachments[index]
            let figure = figures[index]
            guard let bytes = attachment.fileWrapper?.regularFileContents ?? attachment.contents,
                let bitmap = NSBitmapImageRep(data: bytes)
            else { throw CocoaError(.fileReadCorruptFile) }
            // RTFD readers may rebuild the cell from the file. Give the PNG its display size as well as the attachment.
            bitmap.size = figure.size
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let wrapper = FileWrapper(regularFileWithContents: png)
            wrapper.preferredFilename = String(format: "image-%03d.png", index + 1)
            let named = NSTextAttachment(fileWrapper: wrapper)
            named.bounds = CGRect(origin: attachment.bounds.origin, size: figure.size)
            imported.addAttribute(.attachment, value: named, range: run)
            text.removeAttribute(.attachment, range: run)
            text.replaceCharacters(in: run, with: figure.alt)
        }
        return text
    }

    public func write(to board: NSPasteboard) throws {
        let item = NSPasteboardItem()
        guard let flat = rtfd.serializedRepresentation,
            item.setData(flat, forType: .rtfd), item.setData(rtf, forType: .rtf),
            item.setString(html, forType: .html), item.setString(plain, forType: .string)
        else { throw CocoaError(.fileWriteUnknown) }
        board.clearContents()
        guard board.writeObjects([item]) else { throw CocoaError(.fileWriteUnknown) }
    }
}
