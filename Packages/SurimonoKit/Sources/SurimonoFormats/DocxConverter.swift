import Foundation

public enum DocxError: LocalizedError, Equatable {
    case invalidDocument, encryptedOrLegacy, tooLarge, conversionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidDocument: String(localized: "This file is not a Word document (.docx).")
        case .encryptedOrLegacy: String(localized: "Open an unencrypted Word document (.docx).")
        case .tooLarge: String(localized: "Word documents must fit within 50 MB compressed and 300 MB expanded.")
        case .conversionFailed: String(localized: "The Word document could not be converted.")
        }
    }
}

public enum DocxConverter {
    private static let host = ScriptConverterHost(
        "mammoth-1.13.0", bridge: "docx-bridge", category: "DOCX", prelude: "docx-runtime")

    public static func convert(_ data: Data) throws -> HTMLFragment {
        try convert(data, maximumRounds: 100_000)
    }

    static func convert(_ data: Data, maximumRounds: Int) throws -> HTMLFragment {
        guard data.count <= 50_000_000 else { throw DocxError.tooLarge }
        // Encrypted OOXML and legacy .doc share the OLE compound-file signature.
        if data.starts(with: [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]) { throw DocxError.encryptedOrLegacy }
        let limit: UInt64 = 300_000_000
        let limits = ZipArchive.Limits(maximumEntrySize: limit, maximumTotalSize: limit)
        guard let archive = try? ZipArchive(data: data, limits: limits, cacheCapacity: 0),
            archive.entries.contains(where: { $0.path == "word/document.xml" && !$0.isDirectory })
        else { throw DocxError.invalidDocument }
        if archive.entries.contains(where: \.isEncrypted) { throw DocxError.encryptedOrLegacy }
        var remaining = limit
        for entry in archive.entries {
            guard entry.uncompressedSize <= remaining else { throw DocxError.tooLarge }
            remaining -= entry.uncompressedSize
        }
        var relationships: Data?
        var numberingXML: Data?
        var documentXML: Data?
        var metadataTitle: String?
        var styles: XMLDocument?
        for entry in archive.entries {
            try Task.checkCancellation()
            // JSZip expands its own copy. Verify the advertised sizes against the actual streams first.
            guard let bytes = try? archive.contents(of: entry) else { throw DocxError.invalidDocument }
            switch entry.path {
            case "word/_rels/document.xml.rels": relationships = bytes
            case "word/numbering.xml": numberingXML = bytes
            case "word/document.xml": documentXML = bytes
            case "docProps/core.xml":
                let xml = try? XMLDocument(data: bytes, options: [.nodeLoadExternalEntitiesNever])
                metadataTitle = trimmed(
                    xml?.rootElement()?.elements(
                        forLocalName: "title", uri: "http://purl.org/dc/elements/1.1/"
                    ).first?.stringValue)
            case "word/styles.xml":
                styles = try? XMLDocument(data: bytes, options: [.nodeLoadExternalEntitiesNever])
            default: break
            }
        }
        let html = try host.wordHTML(data, maximumRounds: maximumRounds)
        let document = documentXML.flatMap { try? XMLDocument(data: $0, options: [.nodeLoadExternalEntitiesNever]) }
        var fragment = try PrintMarkup.fragment(
            html, format: .docx, metadataTitle: metadataTitle,
            numbering: DocxNumbering(document: document, numbering: numberingXML, styles: styles),
            vectorLabels: legacyVectorLabels(in: document, relationships: relationships, archive: archive))
        fragment.language = language(in: styles)
        return fragment
    }

    // Mammoth omits the namespaced office:title on legacy VML image data. Match the embedded image
    // bytes to its package relationship so an unrelated bitmap cannot take the description.
    private static func legacyVectorLabels(in document: XMLDocument?, relationships: Data?, archive: ZipArchive)
        -> [String: [String]]
    {
        guard let images = try? document?.nodes(forXPath: "//*[local-name()='imagedata' and @*[local-name()='title']]"),
            !images.isEmpty, let relationships,
            let rels = try? XMLDocument(data: relationships, options: [.nodeLoadExternalEntitiesNever])
        else { return [:] }
        guard let packageBase = URL(string: "package:/word/document.xml") else { return [:] }
        var paths: [String: String] = [:]
        for case let rel as XMLElement in rels.rootElement()?.children ?? [] {
            guard let id = rel.attribute(forName: "Id")?.stringValue,
                rel.attribute(forName: "TargetMode")?.stringValue != "External",
                let target = rel.attribute(forName: "Target")?.stringValue,
                let part = URL(string: target, relativeTo: packageBase)?.absoluteURL.standardized,
                part.scheme == "package", part.host == nil
            else { continue }
            paths[id] = String(part.path.dropFirst())
        }
        let entries = Dictionary(archive.entries.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
        var labels: [String: [String]] = [:]
        var keys: [String: String] = [:]
        for case let image as XMLElement in images {
            guard let id = image.attributes?.first(where: { $0.localName == "id" })?.stringValue,
                let path = paths[id], ["wmf", "emf"].contains((path as NSString).pathExtension.lowercased()),
                let entry = entries[path],
                let title = image.attribute(forLocalName: "title", uri: "urn:schemas-microsoft-com:office:office")?
                    .stringValue
            else { continue }
            if keys[path] == nil { keys[path] = (try? archive.contents(of: entry))?.base64EncodedString() }
            if let key = keys[path] { labels[key, default: []].append(title) }
        }
        return labels.mapValues { $0.reversed() }
    }

    private static func language(in styles: XMLDocument?) -> String? {
        let path =
            "/*/*[local-name()='docDefaults']/*[local-name()='rPrDefault']"
            + "/*[local-name()='rPr']/*[local-name()='lang']"
        guard let lang = (try? styles?.nodes(forXPath: path).first) as? XMLElement else { return nil }
        return trimmed(lang.attribute(forLocalName: "val", uri: lang.uri)?.stringValue)
            ?? trimmed(lang.attribute(forLocalName: "eastAsia", uri: lang.uri)?.stringValue)
    }

    private static func trimmed(_ value: String?) -> String? {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
}
