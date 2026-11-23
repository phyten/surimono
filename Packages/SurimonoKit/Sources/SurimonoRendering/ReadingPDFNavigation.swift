import PDFKit

/// Capture page numbers while the destinations still belong to the source document. A PDFKit
/// write can return valid bytes while omitting the outline or leaving a GoTo without its page.
@MainActor
struct ReadingPDFNavigation {
    typealias Writer = ReadingPDFNavigationWriter

    private struct Link {
        let record: Writer.Link
        let bounds: CGRect
    }

    private struct OutlineEntry {
        let level: Int
        let title: String?
        let target: Writer.Destination?
        let hasOtherAction: Bool

        func matches(_ other: Self) -> Bool {
            level == other.level && title == other.title && hasOtherAction == other.hasOtherAction
                && sameTarget(target, other.target)
        }
    }

    private let links: [Link]
    private let outline: [OutlineEntry]

    private static func target(_ destination: PDFDestination?, in document: PDFDocument) -> Writer.Destination? {
        guard let destination, let page = destination.page else { return nil }
        let index = document.index(for: page)
        guard (0..<document.pageCount).contains(index) else { return nil }
        return Writer.Destination(page: index, point: destination.point, zoom: destination.zoom)
    }

    nonisolated private static func sameTarget(_ a: Writer.Destination?, _ b: Writer.Destination?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        // PDF numbers are written as decimals; allow only sub-pixel serialization noise.
        func close(_ x: CGFloat, _ y: CGFloat) -> Bool { x == y || abs(x - y) < 0.001 }
        func zoom(_ value: CGFloat) -> CGFloat { value == kPDFDestinationUnspecifiedValue ? 0 : value }
        return a.page == b.page && close(a.point.x, b.point.x) && close(a.point.y, b.point.y)
            && close(zoom(a.zoom), zoom(b.zoom))
    }

    init(_ document: PDFDocument) throws {
        var links: [Link] = []
        for p in 0..<document.pageCount {
            guard let page = document.page(at: p) else { throw ReadingPDFExporter.ExportError.cannotCopyDocument }
            for (i, annotation) in page.annotations.enumerated() where annotation.type == "Link" {
                let dest = (annotation.action as? PDFActionGoTo)?.destination ?? annotation.destination
                if let target = Self.target(dest, in: document) {
                    links.append(
                        Link(
                            record: Writer.Link(page: p, annotation: i, destination: target), bounds: annotation.bounds)
                    )
                }
            }
        }
        self.links = links
        // Imported PDFs can have much deeper outlines than generated headings. Walk iteratively
        // and keep ancestors alive while checking their identities for cycles.
        var entries: [OutlineEntry] = []
        var stack = document.outlineRoot.map { [(item: $0, next: 0)] } ?? []
        var ancestors = Set(stack.map { ObjectIdentifier($0.item) })
        while let top = stack.last {
            if top.next == top.item.numberOfChildren {
                ancestors.remove(ObjectIdentifier(top.item))
                stack.removeLast()
                continue
            }
            guard let child = top.item.child(at: top.next), ancestors.insert(ObjectIdentifier(child)).inserted else {
                throw ReadingPDFExporter.ExportError.cannotCopyDocument
            }
            stack[stack.count - 1].next += 1
            let dest = child.destination ?? (child.action as? PDFActionGoTo)?.destination
            entries.append(
                OutlineEntry(
                    level: stack.count, title: child.label, target: Self.target(dest, in: document),
                    hasOtherAction: child.action != nil && dest == nil))
            stack.append((child, 0))
        }
        outline = entries
    }

    private func bookmarks() throws -> [Writer.Bookmark] {
        var pending: [(level: Int, node: Writer.Bookmark)] = []
        for entry in outline.reversed() {
            // Preserve an imported action as-is. Never replace a nonlocal action with a made-up page.
            guard !entry.hasOtherAction else {
                throw ReadingPDFExporter.ExportError.navigation(
                    "The native writer changed a bookmark with an unsupported action.")
            }
            var children: [Writer.Bookmark] = []
            while let last = pending.last, last.level > entry.level {
                children.append(pending.removeLast().node)
            }
            pending.append(
                (entry.level, Writer.Bookmark(title: entry.title ?? "", destination: entry.target, children: children)))
        }
        return pending.reversed().map { $0.node }
    }

    private func changes(in saved: PDFDocument) throws -> (links: [Writer.Link], bookmarks: [Writer.Bookmark]?) {
        let actual = try Self(saved)
        var byPage: [Int: [Int: Writer.Destination]] = [:]
        for link in actual.links {
            byPage[link.record.page, default: [:]][link.record.annotation] = link.record.destination
        }
        var missing: [Writer.Link] = []
        for (page, group) in Dictionary(grouping: links, by: { $0.record.page }) {
            var annotations: [PDFAnnotation]?
            for link in group {
                let record = link.record
                if Self.sameTarget(record.destination, byPage[page]?[record.annotation]) { continue }
                if annotations == nil { annotations = saved.page(at: page)?.annotations }
                let detail = "page=\(page + 1) annotation=\(record.annotation) bounds=\(link.bounds)"
                guard let annotations, annotations.indices.contains(record.annotation) else {
                    throw ReadingPDFExporter.ExportError.navigation("Missing link (\(detail)).")
                }
                let annotation = annotations[record.annotation]
                let bounds = annotation.bounds
                guard annotation.type == "Link", !(annotation.action is PDFActionURL),
                    abs(bounds.minX - link.bounds.minX) < 0.01, abs(bounds.minY - link.bounds.minY) < 0.01,
                    abs(bounds.width - link.bounds.width) < 0.01, abs(bounds.height - link.bounds.height) < 0.01
                else { throw ReadingPDFExporter.ExportError.navigation("Saved link identity differs (\(detail)).") }
                missing.append(record)
            }
        }
        let sameOutline =
            outline.count == actual.outline.count && zip(outline, actual.outline).allSatisfy { $0.matches($1) }
        return (missing, sameOutline ? nil : try bookmarks())
    }

    func verified(_ data: Data, pageCount: Int, stage: String) throws -> (data: Data, document: PDFDocument) {
        do {
            return try readback(data, pageCount: pageCount)
        } catch {
            throw ReadingPDFExporter.ExportError.navigation("\(stage): \(error.localizedDescription)")
        }
    }

    private func readback(_ data: Data, pageCount: Int) throws -> (data: Data, document: PDFDocument) {
        guard let saved = PDFDocument(data: data), saved.pageCount == pageCount else {
            throw ReadingPDFExporter.ExportError.cannotCopyDocument
        }
        if links.isEmpty && outline.isEmpty && (saved.outlineRoot?.numberOfChildren ?? 0) == 0 {
            return (data, saved)
        }
        let changes = try changes(in: saved)
        if changes.links.isEmpty && changes.bookmarks == nil { return (data, saved) }
        let detail =
            "pages=\(pageCount), links=\(changes.links.count), outline=\(changes.bookmarks != nil), encrypted=\(saved.isEncrypted)"
        let patched: Data
        do {
            patched = try Writer.repair(data, links: changes.links, bookmarks: changes.bookmarks)
        } catch {
            throw ReadingPDFExporter.ExportError.navigation("Cannot encode PDF navigation (\(detail), \(error)).")
        }
        guard let reread = PDFDocument(data: patched), reread.pageCount == pageCount else {
            throw ReadingPDFExporter.ExportError.navigation("Cannot reopen repaired PDF (\(detail)).")
        }
        let remaining = try self.changes(in: reread)
        guard remaining.links.isEmpty, remaining.bookmarks == nil else {
            throw ReadingPDFExporter.ExportError.navigation("PDF navigation readback differs (\(detail)).")
        }
        return (patched, reread)
    }
}
