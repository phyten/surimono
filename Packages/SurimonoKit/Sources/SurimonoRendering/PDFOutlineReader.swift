import PDFKit
import SurimonoCore

/// A PDF's own bookmarks as a table of contents.
public enum PDFOutlineReader {
    public static func entries(of document: PDFDocument) -> [OutlineEntry] {
        guard let root = document.outlineRoot else { return [] }
        var entries: [OutlineEntry] = []
        func visit(_ outline: PDFOutline, level: Int) {
            for index in 0..<outline.numberOfChildren {
                guard let child = outline.child(at: index) else { continue }
                let title = child.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !title.isEmpty {
                    let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination
                    let page = destination?.page.map { document.index(for: $0) }
                    entries.append(OutlineEntry(level: level, title: title, pageIndex: page))
                }
                visit(child, level: level + 1)
            }
        }
        visit(root, level: 1)
        return entries
    }
}
