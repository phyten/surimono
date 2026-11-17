import AppKit
import Darwin

/// Files are placed only below the folder selected by the reader; creating the folder reserves its name atomically.
enum ExportFiles {
    static func newFolder(in parent: URL, name: String) throws -> URL {
        let name = name.isEmpty || name == "." || name == ".." ? "Document" : name
        for suffix in 1...10_000 {
            let folder = parent.appendingPathComponent(suffix == 1 ? name : "\(name) \(suffix)", isDirectory: true)
            if Darwin.mkdir(folder.path, 0o700) == 0 { return folder }
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    static func pageName(_ name: String, index: Int, count: Int) -> String {
        let digits = max(2, String(count).count)
        return name + "-" + String(format: "%0*d", digits, index + 1) + ".png"
    }
}

enum ExportClipboard {
    static func copy(html: String, plainText: String? = nil, to pasteboard: NSPasteboard = .general) throws {
        let bytes = Data(html.utf8)
        // AppKit's HTML importer can load external resources. Deny them in its private conversion copy;
        // the public HTML representation still retains the document's remote image URLs.
        let policy =
            "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:\">"
        let conversion = html.replacingOccurrences(of: "<head>", with: "<head>" + policy)
        let text = try NSAttributedString(
            data: Data((policy + conversion).utf8),
            options: [
                .documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue,
            ],
            documentAttributes: nil)
        let rtf = try text.data(
            from: NSRange(location: 0, length: text.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let rtfd = try text.data(
            from: NSRange(location: 0, length: text.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        let item = NSPasteboardItem()
        item.setData(bytes, forType: .html)
        item.setData(rtf, forType: .rtf)
        item.setData(rtfd, forType: .rtfd)
        item.setString(plainText ?? text.string, forType: .string)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw CocoaError(.fileWriteUnknown) }
    }
}
