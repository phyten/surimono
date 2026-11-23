import Foundation
import PDFKit
import SurimonoCore

@MainActor
public enum ReadingPDFExporter {
    public enum ExportError: Error { case cannotCopyDocument }

    /// Uses the same HTML and forward-only page matching as the Contents popover, when no reading outline is cached.
    public static func outline(
        of source: DocumentSource, in document: PDFDocument, proof: ProofMarks, includesSourceContents: Bool,
        facts: DocumentFacts? = nil
    ) async -> (entries: [OutlineEntry], title: String?, headings: [DocumentHeading]) {
        if let facts, let entries = facts.beamerOutline {
            // Section names need not appear on any painted slide.
            return (entries, facts.title, facts.headings)
        }
        let structure = await Task.detached(priority: .utility) {
            let html = DocumentRenderer.structureHTML(of: source, proof: proof) ?? ""
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

    public static func document(
        from logical: PDFDocument, entries: [OutlineEntry], title: String, preservesOutline: Bool = false,
        headings: [DocumentHeading] = [], sourceURL: URL? = nil, furniture: [Int: FurniturePlacement] = [:]
    ) throws -> PDFDocument {
        // Serializing the whole document preserves cross-page destinations and isolates the renderer's cache.
        // Drawing pages into a new context would discard the links and the source PDF's outline.
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
        guard let data = pages.dataRepresentation(), let document = PDFDocument(data: data) else {
            throw ExportError.cannotCopyDocument
        }
        // Do not inherit author names or arbitrary producer metadata from the source or the printing system.
        document.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: title, PDFDocumentAttribute.creatorAttribute: "Surimono",
        ]
        if !preservesOutline {
            repairLinks(in: document, headings: headings, entries: entries, sourceURL: sourceURL)
            let root = PDFOutline()
            func append(_ nodes: [ReadingBookmark], to parent: PDFOutline) {
                for node in nodes {
                    guard let index = node.entry.pageIndex, let page = document.page(at: index) else {
                        // An unresolved heading must not invent a destination or hide resolved descendants.
                        append(node.children, to: parent)
                        continue
                    }
                    let child = PDFOutline()
                    child.label = node.entry.title
                    let box = page.bounds(for: .cropBox)
                    child.destination = PDFDestination(page: page, at: CGPoint(x: box.minX, y: box.maxY))
                    parent.insertChild(child, at: parent.numberOfChildren)
                    append(node.children, to: child)
                }
            }
            append(ReadingBookmark.tree(from: entries), to: root)
            document.outlineRoot = root.numberOfChildren == 0 ? nil : root
        }
        return document
    }

    private static func repairLinks(
        in document: PDFDocument, headings: [DocumentHeading], entries: [OutlineEntry], sourceURL: URL?
    ) {
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
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
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
                    || (scheme == SnapshotSchemeHandler.scheme
                        && (bare == SnapshotSchemeHandler.rootURL || bare == SnapshotSchemeHandler.pageURL))
                    || (scheme.isEmpty && url.path.isEmpty)
                let fragment =
                    blankPage
                    ? blankAddress.map { String($0.dropFirst("about:blank#".count)) }
                    : URLComponents(url: url, resolvingAgainstBaseURL: true)?.fragment
                if isSelf, let fragment,
                    let destinationIndex = pages[fragment], let destinationPage = document.page(at: destinationIndex)
                {
                    let box = destinationPage.bounds(for: .cropBox)
                    annotation.url = nil
                    annotation.action = PDFActionGoTo(
                        destination: PDFDestination(page: destinationPage, at: CGPoint(x: box.minX, y: box.maxY)))
                } else {
                    page.removeAnnotation(annotation)
                }
            }
        }
    }
}
