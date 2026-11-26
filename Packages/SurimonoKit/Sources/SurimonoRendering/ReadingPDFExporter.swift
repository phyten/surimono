import Foundation
import PDFKit
import SurimonoCore

@MainActor
public enum ReadingPDFExporter {
    public enum ExportError: LocalizedError {
        case unverifiedBinderNavigation
        case cannotCopyDocument
        case navigation(String)

        public var errorDescription: String? {
            switch self {
            case .unverifiedBinderNavigation:
                return String(localized: "The original link destinations in this binder could not be verified.")
            case .cannotCopyDocument: return String(localized: "The PDF could not be exported.")
            case .navigation(let detail): return detail
            }
        }
    }

    /// Uses the same HTML and forward-only page matching as the Contents popover, when no reading outline is cached.
    public static func outline(
        of source: DocumentSource, in document: PDFDocument, proof: ProofMarks, includesSourceContents: Bool,
        facts: DocumentFacts? = nil, orgReading: OrgReadingSettings = .init()
    ) async -> (entries: [OutlineEntry], title: String?, headings: [DocumentHeading]) {
        if let facts, let entries = facts.beamerOutline {
            // Section names need not appear on any painted slide.
            return (entries, facts.title, facts.headings)
        }
        let structure = await Task.detached(priority: .utility) {
            let html = DocumentRenderer.structureHTML(of: source, proof: proof, orgReading: orgReading) ?? ""
            return (
                DocumentOutline.headings(inHTML: html),
                includesSourceContents ? DocumentOutline.sourceContentsEntries(inHTML: html) : [],
                DocumentOutline.title(ofHTML: html)
            )
        }.value
        var texts: [String] = []
        for index in 0..<document.pageCount {
            texts.append(document.page(at: index)?.string ?? "")
            await Task.yield()
            if Task.isCancelled { return ([], nil, []) }
        }
        let entries = await Task.detached(priority: .utility) { [texts] in
            DocumentOutline.entries(of: structure.0, inPageTexts: texts, contentsEntries: structure.1)
        }.value
        return (entries, structure.2, structure.0)
    }

    /// Captures navigation before PDFKit can drop weak destinations during its native write.
    public static func data(from document: PDFDocument) async throws -> Data {
        let expected = try await ReadingPDFNavigation(document, stage: "export")
        guard let bytes = document.dataRepresentation() else { throw ExportError.cannotCopyDocument }
        return try await expected.verified(bytes, pageCount: document.pageCount, stage: "export → saved")
    }

    public static func document(
        from logical: PDFDocument, entries: [OutlineEntry], title: String, preservesOutline: Bool = false,
        headings: [DocumentHeading] = [], sourceURL: URL? = nil, furniture: [Int: FurniturePlacement] = [:]
    ) async throws -> PDFDocument {
        let bytes = try await data(
            from: logical, entries: entries, title: title, preservesOutline: preservesOutline, headings: headings,
            sourceURL: sourceURL, furniture: furniture)
        guard let document = PDFDocument(data: bytes) else { throw ExportError.cannotCopyDocument }
        return document
    }

    public static func data(
        from logical: PDFDocument, entries: [OutlineEntry], title: String, preservesOutline: Bool = false,
        headings: [DocumentHeading] = [], sourceURL: URL? = nil, furniture: [Int: FurniturePlacement] = [:]
    ) async throws -> Data {
        // Capture on the original. Decoration keeps page order and coordinates, but a copied
        // annotation can lose its target before PDFKit produces even the first set of bytes.
        let original = try await ReadingPDFNavigation(logical)
        let pages: PDFDocument
        if furniture.isEmpty {
            pages = logical
        } else {
            // Keep the source page order and links while adding the same searchable footer as the printed sheet.
            let options = ViewOptions(
                layout: .single, scrollAxis: .vertical, transition: .instant, showsCoverAlone: false)
            let plan = ViewPageLayout(
                pageCount: logical.pageCount, options: options, hasLogicalMargins: false, showsNumbers: false)
            guard
                let decorated = ViewPageDocument.make(
                    logical, plan: plan, margin: 0, furniture: furniture, furnitureAsText: true)
            else { throw ExportError.cannotCopyDocument }
            pages = decorated
        }
        guard let bytes = pages.dataRepresentation() else { throw ExportError.cannotCopyDocument }
        return try await finish(
            bytes, original: original, pageCount: logical.pageCount, entries: entries, title: title,
            preservesOutline: preservesOutline, headings: headings, sourceURL: sourceURL,
            snapshotURLs: [SnapshotSchemeHandler.rootURL, SnapshotSchemeHandler.pageURL])
    }

    private typealias Raw = ReadingPDFRawNavigation

    @concurrent private static func finish(
        _ bytes: Data, original: ReadingPDFNavigation, pageCount: Int, entries: [OutlineEntry], title: String,
        preservesOutline: Bool, headings: [DocumentHeading], sourceURL: URL?, snapshotURLs: [URL]
    ) async throws -> Data {
        try Task.checkCancellation()
        guard let document = PDFDocument(data: bytes), document.pageCount == pageCount else {
            throw ExportError.cannotCopyDocument
        }
        document.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: title, PDFDocumentAttribute.creatorAttribute: "Surimono",
        ]
        var expected = original
        // PDFDestination.page is weak; this independent writer owns its target wrappers until serialization.
        var targets = PageTargets()
        if !preservesOutline {
            expected = try original.rebased(to: document)
            expected.links = try repairLinks(
                in: document, original: expected.links, headings: headings, entries: entries, sourceURL: sourceURL,
                snapshotURLs: snapshotURLs, targets: &targets)
            expected.outline = try setOutline(in: document, entries: entries, targets: &targets)
        }
        try Task.checkCancellation()
        let saved = withExtendedLifetime(targets) { document.dataRepresentation() }
        guard let saved else { throw ExportError.cannotCopyDocument }
        return try await expected.verified(saved, pageCount: pageCount, stage: "view → saved")
    }

    private struct PageTargets {
        var pages: [Int: PDFPage] = [:]

        mutating func top(of index: Int, in document: PDFDocument) -> (PDFActionGoTo, Raw.Action)? {
            guard let page = pages[index] ?? document.page(at: index) else { return nil }
            pages[index] = page
            let box = page.bounds(for: .cropBox)
            let point = CGPoint(x: box.minX, y: box.maxY)
            return (
                PDFActionGoTo(destination: PDFDestination(page: page, at: point)),
                .internalDestination(.init(page: index, mode: "XYZ", arguments: [point.x, point.y, nil]))
            )
        }
    }

    nonisolated private static func setOutline(
        in document: PDFDocument, entries: [OutlineEntry], targets: inout PageTargets
    ) throws -> [Raw.Entry] {
        let root = PDFOutline()
        var outline: [Raw.Entry] = []
        func append(_ nodes: [ReadingBookmark], to parent: PDFOutline, level: Int) throws {
            for node in nodes {
                try Task.checkCancellation()
                guard let index = node.entry.pageIndex, let (action, record) = targets.top(of: index, in: document)
                else {
                    // An unresolved heading must not invent a destination or hide resolved descendants.
                    try append(node.children, to: parent, level: level)
                    continue
                }
                let child = PDFOutline()
                child.label = node.entry.title
                parent.insertChild(child, at: parent.numberOfChildren)
                child.action = action
                let i = outline.count
                outline.append(.init(level: level, title: node.entry.title, isOpen: false, action: record))
                try append(node.children, to: child, level: level + 1)
                if child.numberOfChildren > 0, child.isOpen {
                    outline[i] = .init(level: level, title: node.entry.title, isOpen: true, action: record)
                }
            }
        }
        try append(ReadingBookmark.tree(from: entries), to: root, level: 1)
        document.outlineRoot = root.numberOfChildren == 0 ? nil : root
        return outline
    }

    nonisolated private static func repairLinks(
        in document: PDFDocument, original: [Raw.Link], headings: [DocumentHeading], entries: [OutlineEntry],
        sourceURL: URL?, snapshotURLs: [URL], targets: inout PageTargets
    ) throws -> [Raw.Link] {
        var pages: [String: Int] = [:]
        var cursor = entries.startIndex
        for heading in headings {
            guard
                let index = entries[cursor...].firstIndex(where: {
                    $0.title == heading.text && $0.level == heading.level
                })
            else { continue }
            cursor = index + 1
            if let id = heading.id, let page = entries[index].pageIndex, pages[id] == nil { pages[id] = page }
        }
        func withoutFragment(_ url: URL) -> URL? {
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: true)
            parts?.fragment = nil
            return parts?.url?.standardizedFileURL
        }
        let ownURLs = [sourceURL, sourceURL?.deletingLastPathComponent()].compactMap { $0 }.compactMap(withoutFragment)
        var expected: [Raw.Link] = []
        var next = original.startIndex
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw ExportError.cannotCopyDocument }
            var removed = 0
            for (i, annotation) in page.annotations.enumerated() {
                try Task.checkCancellation()
                if next < original.endIndex, original[next].page == index, original[next].annotation == i {
                    // Keep the pre-write intent even when this PDFKit clone already lost its action.
                    let link = original[next]
                    expected.append(
                        .init(page: index, annotation: i - removed, bounds: link.bounds, action: link.action))
                    next += 1
                    continue
                }
                guard annotation.type == "Link",
                    let url = (annotation.action as? PDFActionURL)?.url ?? annotation.url
                else { continue }
                let scheme = url.scheme?.lowercased() ?? ""
                // PDFKit escapes the separator of opaque about: URLs when it serializes them.
                let blankAddress = scheme == "about" ? url.absoluteString.removingPercentEncoding : nil
                let blankPage = blankAddress == "about:blank" || blankAddress?.hasPrefix("about:blank#") == true
                guard scheme == "file" || scheme.hasPrefix("surimono-") || scheme.isEmpty || blankPage else { continue }
                let target = LocalResourceSchemeHandler.fileURL(for: url) ?? url
                let bare = withoutFragment(target)
                // Only pagination's own temporary HTML is an alias, never another local document with the same id.
                let temporary =
                    target.isFileURL
                    && target.deletingLastPathComponent().standardizedFileURL
                        == FileManager.default.temporaryDirectory.standardizedFileURL
                    && target.lastPathComponent.hasPrefix("surimono-pagination-") && target.pathExtension == "html"
                let isSelf =
                    ownURLs.contains { $0 == bare } || temporary || blankPage
                    || snapshotURLs.contains { $0 == bare }
                    || (scheme.isEmpty && url.path.isEmpty)
                let fragment =
                    blankPage
                    ? blankAddress.map { String($0.dropFirst("about:blank#".count)) }
                    : URLComponents(url: url, resolvingAgainstBaseURL: true)?.fragment
                if isSelf, let fragment,
                    let destinationIndex = pages[fragment],
                    let (action, record) = targets.top(of: destinationIndex, in: document)
                {
                    annotation.url = nil
                    annotation.action = action
                    expected.append(
                        .init(page: index, annotation: i - removed, bounds: annotation.bounds, action: record))
                } else {
                    page.removeAnnotation(annotation)
                    removed += 1
                }
            }
        }
        guard next == original.endIndex else {
            throw ExportError.navigation("Missing source link while preparing the reading PDF.")
        }
        return expected
    }
}
