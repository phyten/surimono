import Foundation
import PDFKit
import SurimonoCore

@MainActor
public enum ReadingPDFExporter {
    public enum ExportError: Error { case cannotCopyDocument }

    /// Uses the same HTML and forward-only page matching as the Contents popover, when no reading outline is cached.
    public static func outline(
        of source: DocumentSource, in document: PDFDocument, proof: ProofMarks, includesSourceContents: Bool
    ) async -> (entries: [OutlineEntry], title: String?) {
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
            if Task.isCancelled { return ([], nil) }
        }
        let entries = await Task.detached(priority: .utility) { [texts] in
            DocumentOutline.entries(of: structure.0, inPageTexts: texts, contentsEntries: structure.1)
        }.value
        return (entries, structure.2)
    }

    public static func document(
        from logical: PDFDocument, entries: [OutlineEntry], title: String, preservesOutline: Bool = false
    ) throws -> PDFDocument {
        // Serializing the whole document preserves cross-page destinations and isolates the renderer's cache.
        // Drawing pages into a new context would discard the links and the source PDF's outline.
        guard let data = logical.dataRepresentation(), let document = PDFDocument(data: data) else {
            throw ExportError.cannotCopyDocument
        }
        // Do not inherit author names or arbitrary producer metadata from the source or the printing system.
        document.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: title, PDFDocumentAttribute.creatorAttribute: "Surimono",
        ]
        if !preservesOutline {
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
}
