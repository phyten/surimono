import PDFKit

/// Only the capture touches the UI's PDFDocument. All subsequent comparisons use value records.
struct ReadingPDFNavigation: Sendable {
    typealias Raw = ReadingPDFRawNavigation
    typealias Writer = ReadingPDFNavigationWriter

    var links: [Raw.Link]
    var outline: [Raw.Entry]

    private static func sameBounds(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01
            && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
    }

    @MainActor
    init(_ document: PDFDocument) async throws {
        let count = document.pageCount
        var work = 0
        func checkpoint() async throws {
            try Task.checkCancellation()
            work += 1
            if work.isMultiple(of: 128) { await Task.yield() }
            guard document.pageCount == count else { throw ReadingPDFExporter.ExportError.cannotCopyDocument }
        }
        try await checkpoint()

        // Pages in a binder can come from different files or have moved since the file was opened.
        // Map each original page dictionary back to its position in the live document.
        var indexes: [CGPDFDictionaryRef: Int] = [:]
        var repeated = Set<CGPDFDictionaryRef>()
        var sources: [ObjectIdentifier: CGPDFDocument] = [:]
        for i in 0..<count {
            try await checkpoint()
            guard let page = document.page(at: i) else { throw ReadingPDFExporter.ExportError.cannotCopyDocument }
            if let ref = page.pageRef, let key = ref.dictionary, let pdf = ref.document {
                if indexes.updateValue(i, forKey: key) != nil { repeated.insert(key) }
                sources[ObjectIdentifier(pdf)] = pdf
            }
        }
        if let pdf = document.documentRef { sources[ObjectIdentifier(pdf)] = pdf }
        var byPage: [CGPDFDictionaryRef: [Int: Raw.Link]] = [:]
        var originalOutline: [Raw.Entry] = []
        for pdf in sources.values {
            let raw: Raw
            do {
                raw = try await Raw.capture(pdf)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ReadingPDFExporter.ExportError.navigation("Cannot read the original PDF navigation (\(error)).")
            }
            func remap(_ action: Raw.Action) -> Raw.Action {
                guard case .internalDestination(let dest) = action else { return action }
                guard let page = pdf.page(at: dest.page + 1)?.dictionary, !repeated.contains(page),
                    let index = indexes[page]
                else {
                    return .unresolved
                }
                return .internalDestination(.init(page: index, mode: dest.mode, arguments: dest.arguments))
            }
            for link in raw.links {
                try await checkpoint()
                if let key = pdf.page(at: link.page + 1)?.dictionary, let index = indexes[key] {
                    byPage[key, default: [:]][link.annotation] = Raw.Link(
                        page: index, annotation: link.annotation, bounds: link.bounds, action: remap(link.action))
                }
            }
            if pdf === document.documentRef {
                for entry in raw.outline {
                    try await checkpoint()
                    originalOutline.append(
                        .init(level: entry.level, title: entry.title, isOpen: entry.isOpen, action: remap(entry.action))
                    )
                }
            }
        }

        var links: [Raw.Link] = []
        for p in 0..<count {
            try await checkpoint()
            guard let page = document.page(at: p) else { throw ReadingPDFExporter.ExportError.cannotCopyDocument }
            var originals = page.pageRef?.dictionary.flatMap { byPage[$0] } ?? [:]
            for (i, annotation) in page.annotations.enumerated() {
                try await checkpoint()
                guard annotation.type == "Link" else { continue }
                let original = originals.removeValue(forKey: i)
                if let original, original.action.isInternal, !Self.sameBounds(original.bounds, annotation.bounds) {
                    throw ReadingPDFExporter.ExportError.navigation(
                        "Cannot identify the original link (page=\(p + 1) annotation=\(i)).")
                }
                let matching = original.flatMap { Self.sameBounds($0.bounds, annotation.bounds) ? $0.action : nil }
                let value = try Self.action(
                    annotation.action, annotation.destination, original: matching, in: document,
                    detail: "page=\(p + 1) annotation=\(i)")
                if case .internalDestination = value {
                    links.append(.init(page: p, annotation: i, bounds: annotation.bounds, action: value))
                }
            }
            // An imported GoTo can be unreadable in PDFKit even though its dictionary exists.
            for link in originals.values {
                try await checkpoint()
                if link.action.isInternal {
                    throw ReadingPDFExporter.ExportError.navigation(
                        "Cannot identify the original link (page=\(p + 1) annotation=\(link.annotation)).")
                }
            }
        }
        self.links = links
        var entries: [Raw.Entry] = []
        var stack = document.outlineRoot.map { [(item: $0, next: 0)] } ?? []
        var ancestors = Set(stack.map { ObjectIdentifier($0.item) })
        while let top = stack.last {
            try await checkpoint()
            if top.next == top.item.numberOfChildren {
                ancestors.remove(ObjectIdentifier(top.item))
                stack.removeLast()
                continue
            }
            guard let child = top.item.child(at: top.next), ancestors.insert(ObjectIdentifier(child)).inserted else {
                throw ReadingPDFExporter.ExportError.cannotCopyDocument
            }
            stack[stack.count - 1].next += 1
            let i = entries.count
            let original = originalOutline.indices.contains(i) ? originalOutline[i] : nil
            let matching = original.flatMap { $0.level == stack.count && $0.title == child.label ? $0.action : nil }
            if let original, original.action.isInternal && matching == nil {
                throw ReadingPDFExporter.ExportError.navigation(
                    "Cannot identify the original bookmark (bookmark=\(i + 1)).")
            }
            let value = try Self.action(
                child.action, child.destination, original: matching, in: document, detail: "bookmark=\(i + 1)")
            entries.append(
                .init(
                    level: stack.count, title: child.label, isOpen: child.numberOfChildren > 0 && child.isOpen,
                    action: value))
            stack.append((child, 0))
        }
        for entry in originalOutline.dropFirst(entries.count) {
            try await checkpoint()
            if entry.action.isInternal {
                throw ReadingPDFExporter.ExportError.navigation("An original bookmark is missing from the view.")
            }
        }
        try Task.checkCancellation()
        self.outline = entries
    }

    @MainActor
    private static func action(
        _ action: PDFAction?, _ destination: PDFDestination?, original: Raw.Action?, in document: PDFDocument,
        detail: String
    ) throws -> Raw.Action {
        let failure = ReadingPDFExporter.ExportError.navigation("Cannot resolve the internal destination (\(detail)).")
        if original == .unresolved { throw failure }
        let goTo = action as? PDFActionGoTo
        if action != nil && goTo == nil {
            // Conflicting representations must not hide an internal action from readback.
            if original?.isInternal == true { throw failure }
            return .other
        }
        guard let dest = goTo?.destination ?? destination, let page = dest.page else {
            // PDFKit may not expose the page of a valid named destination.
            if case .internalDestination(let raw) = original { return .internalDestination(raw) }
            if goTo != nil || destination != nil { throw failure }
            return original ?? .none
        }
        let index = document.index(for: page)
        guard (0..<document.pageCount).contains(index) else { throw failure }
        let live = Writer.Destination(page: index, point: dest.point, zoom: dest.zoom)
        guard live.arguments.allSatisfy({ $0?.isFinite ?? true }) else { throw failure }
        if case .internalDestination(let raw) = original {
            if raw.mode != "XYZ" {
                // PDFKit does not expose the Fit operands. Only the original identifies the view.
                guard raw.page == index else { throw failure }
                return .internalDestination(raw)
            }
            // PDFKit projects both a zero zoom and a null zoom as unspecified. Preserve
            // the original operand even when the owner has changed a different coordinate.
            if raw.arguments[2] == 0, live.arguments[2] == nil {
                return .internalDestination(
                    .init(page: index, mode: "XYZ", arguments: [live.arguments[0], live.arguments[1], 0]))
            }
        }
        return .internalDestination(live)
    }

    private func bookmarks() throws -> [Writer.Bookmark] {
        var pending: [(level: Int, node: Writer.Bookmark)] = []
        for entry in outline.reversed() {
            try Task.checkCancellation()
            guard entry.level <= 65 else {
                throw ReadingPDFExporter.ExportError.navigation("Cannot rebuild a deeply nested outline.")
            }
            let target: Writer.Destination?
            switch entry.action {
            case .none: target = nil
            case .internalDestination(let dest): target = dest
            case .other, .unresolved:
                throw ReadingPDFExporter.ExportError.navigation("Cannot reconstruct this bookmark action.")
            }
            var children: [Writer.Bookmark] = []
            while let last = pending.last, last.level > entry.level { children.append(pending.removeLast().node) }
            pending.append(
                (
                    entry.level,
                    .init(title: entry.title ?? "", destination: target, isOpen: entry.isOpen, children: children)
                ))
        }
        return pending.reversed().map { $0.node }
    }

    private func changes(in saved: Raw) throws -> (links: [Writer.Link], bookmarks: [Writer.Bookmark]?) {
        var expected: [Int: [Int: Raw.Link]] = [:]
        for link in links { expected[link.page, default: [:]][link.annotation] = link }
        var repairs: [Writer.Link] = []
        var matched = 0
        for link in saved.links {
            try Task.checkCancellation()
            guard let original = expected[link.page]?[link.annotation],
                case .internalDestination(let target) = original.action
            else {
                if link.action.isInternal {
                    throw ReadingPDFExporter.ExportError.navigation(
                        "Unexpected internal link (page=\(link.page + 1) annotation=\(link.annotation)).")
                }
                continue
            }
            guard Self.sameBounds(original.bounds, link.bounds), link.action != .other else {
                throw ReadingPDFExporter.ExportError.navigation(
                    "Saved link identity differs (page=\(link.page + 1) annotation=\(link.annotation)).")
            }
            matched += 1
            if link.action != original.action {
                repairs.append(.init(page: link.page, annotation: link.annotation, destination: target))
            }
        }
        guard matched == links.count else {
            throw ReadingPDFExporter.ExportError.navigation("Missing link annotation (\(matched)/\(links.count)).")
        }
        return (repairs, saved.hasValidOutlineCounts && saved.outline == outline ? nil : try bookmarks())
    }

    @concurrent
    func verified(_ data: Data, pageCount: Int, stage: String) async throws -> Data {
        do {
            let saved = try await Raw.read(data)
            guard saved.pageCount == pageCount else { throw ReadingPDFExporter.ExportError.cannotCopyDocument }
            let changes = try changes(in: saved)
            if changes.links.isEmpty && changes.bookmarks == nil { return data }
            let patched = try Writer.repair(data, links: changes.links, bookmarks: changes.bookmarks)
            let reread = try await Raw.read(patched)
            guard reread.pageCount == pageCount else { throw ReadingPDFExporter.ExportError.cannotCopyDocument }
            let remaining = try self.changes(in: reread)
            guard remaining.links.isEmpty, remaining.bookmarks == nil else {
                throw ReadingPDFExporter.ExportError.navigation("PDF navigation readback differs.")
            }
            return patched
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ReadingPDFExporter.ExportError.navigation("\(stage): \(error.localizedDescription)")
        }
    }
}
