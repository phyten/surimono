import PDFKit

/// Only the capture touches the UI's PDFDocument. All subsequent comparisons use value records.
struct ReadingPDFNavigation: Sendable {
    typealias Raw = ReadingPDFRawNavigation
    typealias Writer = ReadingPDFNavigationWriter

    private var mediaOrigins: [CGPoint]
    var links: [Raw.Link]
    var outline: [Raw.Entry]

    private static func sameBounds(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01
            && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
    }

    @MainActor
    init(_ document: PDFDocument, stage: String = "view") async throws {
        let count = document.pageCount
        var work = 0
        func checkpoint() async throws {
            try Task.checkCancellation()
            work += 1
            if work.isMultiple(of: 128) { await Task.yield() }
            guard document.pageCount == count else { throw ReadingPDFExporter.ExportError.cannotCopyDocument }
        }
        try await checkpoint()

        // Read the UI-owned actions before consulting PDFKit's backing page dictionaries.
        let live = try await Self.projection(of: document)
        // Pages in a binder can come from different files or have moved since the file was opened.
        // Map each original page dictionary back to its position in the live document.
        var indexes: [CGPDFDictionaryRef: Int] = [:]
        var repeated = Set<CGPDFDictionaryRef>()
        var sources: [ObjectIdentifier: CGPDFDocument] = [:]
        var origins: [CGPoint] = []
        var pageKeys: [Int: CGPDFDictionaryRef] = [:]
        for i in 0..<count {
            try await checkpoint()
            guard let page = document.page(at: i) else { throw ReadingPDFExporter.ExportError.cannotCopyDocument }
            origins.append(page.bounds(for: .mediaBox).origin)
            if let ref = page.pageRef, let key = ref.dictionary, let pdf = ref.document {
                pageKeys[i] = key
                if indexes.updateValue(i, forKey: key) != nil { repeated.insert(key) }
                sources[ObjectIdentifier(pdf)] = pdf
            }
        }
        let backing = document.documentRef
        if let pdf = backing { sources[ObjectIdentifier(pdf)] = pdf }
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
                guard let dest = action.target else { return action }
                guard let page = pdf.page(at: dest.page + 1)?.dictionary, !repeated.contains(page),
                    let index = indexes[page]
                else {
                    return .missingPage(mode: dest.mode, arguments: dest.arguments)
                }
                let mapped = Writer.Destination(page: index, mode: dest.mode, arguments: dest.arguments)
                if case .namedDestination = action { return .namedDestination(mapped) }
                return .internalDestination(mapped)
            }
            for link in raw.links {
                try await checkpoint()
                if let key = pdf.page(at: link.page + 1)?.dictionary, let index = indexes[key] {
                    byPage[key, default: [:]][link.annotation] = Raw.Link(
                        page: index, annotation: link.annotation, bounds: link.bounds, action: remap(link.action))
                }
            }
            if pdf === backing {
                for entry in raw.outline {
                    try await checkpoint()
                    originalOutline.append(
                        .init(level: entry.level, title: entry.title, isOpen: entry.isOpen, action: remap(entry.action))
                    )
                }
            }
        }

        var links: [Raw.Link] = []
        var visited: [Int: Set<Int>] = [:]
        for link in live.links {
            try await checkpoint()
            let original = pageKeys[link.page].flatMap { byPage[$0]?[link.annotation] }
            let detail = "\(stage) p\(link.page + 1) annotation=\(link.annotation)"
            if let original, original.action.isInternal, !Self.sameBounds(original.bounds, link.bounds) {
                throw ReadingPDFExporter.ExportError.navigation("\(detail): original link bounds differ.")
            }
            let matching = original.flatMap { Self.sameBounds($0.bounds, link.bounds) ? $0.action : nil }
            let value = try Self.resolve(link.action, original: matching, detail: detail)
            visited[link.page, default: []].insert(link.annotation)
            if value.isInternal {
                links.append(.init(page: link.page, annotation: link.annotation, bounds: link.bounds, action: value))
            }
        }
        for (p, key) in pageKeys {
            try await checkpoint()
            guard let originals = byPage[key] else { continue }
            for link in originals.values {
                try await checkpoint()
                if link.action.isInternal && visited[p]?.contains(link.annotation) != true {
                    throw ReadingPDFExporter.ExportError.navigation(
                        "\(stage) p\(p + 1) annotation=\(link.annotation): missing original link.")
                }
            }
        }
        self.mediaOrigins = origins
        self.links = links
        var entries: [Raw.Entry] = []
        for (i, entry) in live.outline.enumerated() {
            try await checkpoint()
            let original = originalOutline.indices.contains(i) ? originalOutline[i] : nil
            let matching = original.flatMap { $0.level == entry.level && $0.title == entry.title ? $0.action : nil }
            let detail = "\(stage) bookmark=\(i + 1)"
            if let original, original.action.isInternal && matching == nil {
                throw ReadingPDFExporter.ExportError.navigation("\(detail): original bookmark identity differs.")
            }
            let value = try Self.resolve(entry.action, original: matching, detail: detail)
            entries.append(.init(level: entry.level, title: entry.title, isOpen: entry.isOpen, action: value))
        }
        for entry in originalOutline.dropFirst(entries.count) {
            try await checkpoint()
            if entry.action.isInternal {
                throw ReadingPDFExporter.ExportError.navigation("\(stage): an original bookmark is missing.")
            }
        }
        try Task.checkCancellation()
        self.outline = entries
    }

    /// A native write can translate each copied page by a different amount. Express the captured navigation in
    /// the reopened document's page spaces before comparing it or adding destinations authored on those pages.
    func rebased(to document: PDFDocument) throws -> Self {
        guard document.pageCount == mediaOrigins.count else { throw ReadingPDFExporter.ExportError.cannotCopyDocument }
        let origins = try mediaOrigins.indices.map { i in
            try Task.checkCancellation()
            guard let page = document.page(at: i) else { throw ReadingPDFExporter.ExportError.cannotCopyDocument }
            return page.bounds(for: .mediaBox).origin
        }
        guard origins != mediaOrigins else { return self }
        func offset(_ page: Int) -> CGPoint {
            CGPoint(x: origins[page].x - mediaOrigins[page].x, y: origins[page].y - mediaOrigins[page].y)
        }
        func moved(_ action: Raw.Action) -> Raw.Action {
            guard let target = action.target else { return action }
            let delta = offset(target.page)
            let shifted = target.offsetBy(dx: delta.x, dy: delta.y)
            if case .namedDestination = action { return .namedDestination(shifted) }
            return .internalDestination(shifted)
        }
        var copy = self
        copy.mediaOrigins = origins
        copy.links = try links.map { link in
            try Task.checkCancellation()
            let delta = offset(link.page)
            return .init(
                page: link.page, annotation: link.annotation, bounds: link.bounds.offsetBy(dx: delta.x, dy: delta.y),
                action: moved(link.action))
        }
        copy.outline = try outline.map { entry in
            try Task.checkCancellation()
            return .init(level: entry.level, title: entry.title, isOpen: entry.isOpen, action: moved(entry.action))
        }
        return copy
    }

    // The source is read on its owning actor. A saved file is independently opened and
    // inspected on the worker. Never use a Quartz fallback here: it would mask a broken GoTo.
    private static func projection(of document: PDFDocument, isolation: isolated (any Actor)? = #isolation)
        async throws -> (links: [Raw.Link], outline: [Raw.Entry])
    {
        let count = document.pageCount
        var visited = 0
        func checkpoint(isolation: isolated (any Actor)? = #isolation) async throws {
            try Task.checkCancellation()
            visited += 1
            if visited.isMultiple(of: 128) { await Task.yield() }
            guard document.pageCount == count else { throw ReadingPDFExporter.ExportError.cannotCopyDocument }
        }
        func action(_ action: PDFAction?, _ destination: @autoclosure () -> PDFDestination?) -> Raw.Action {
            let goTo = action as? PDFActionGoTo
            if action != nil && goTo == nil { return .other }
            guard let dest = goTo?.destination ?? destination() else { return .none }
            guard let page = dest.page else { return .releasedPage }
            let index = document.index(for: page)
            guard (0..<count).contains(index) else { return .unresolved("foreign page") }
            let target = Writer.Destination(page: index, point: dest.point, zoom: dest.zoom)
            guard target.arguments.allSatisfy({ $0?.isFinite ?? true }) else { return .unresolved("nonfinite XYZ") }
            return .internalDestination(target)
        }
        var links: [Raw.Link] = []
        for p in 0..<count {
            try await checkpoint()
            guard let page = document.page(at: p) else { throw ReadingPDFExporter.ExportError.cannotCopyDocument }
            for (i, annotation) in page.annotations.enumerated() {
                try await checkpoint()
                if annotation.type == "Link" {
                    links.append(
                        .init(
                            page: p, annotation: i, bounds: annotation.bounds,
                            action: action(annotation.action, annotation.destination)))
                }
            }
        }
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
            entries.append(
                .init(
                    level: stack.count, title: child.label, isOpen: child.numberOfChildren > 0 && child.isOpen,
                    action: action(child.action, child.destination)))
            stack.append((child, 0))
        }
        return (links, entries)
    }

    private static func resolve(_ live: Raw.Action, original: Raw.Action?, detail: String) throws -> Raw.Action {
        func failure() -> ReadingPDFExporter.ExportError {
            .navigation("\(detail): PDFKit=\(live.summary), dictionary=\(original?.summary ?? "absent").")
        }
        if case .unresolved = original { throw failure() }
        guard let target = live.target else {
            if let original, original.target != nil, live != .other { return original }
            if live.isInternal || original?.isInternal == true { throw failure() }
            return live == .none ? original ?? .none : live
        }
        let mode: String
        let arguments: [CGFloat?]
        if let raw = original?.target {
            if raw.mode != "XYZ" && raw.page != target.page { throw failure() }
            mode = raw.mode
            arguments = raw.arguments
        } else if case .missingPage(let kind, let operands) = original {
            // The owning document supplies the page; the backing array still supplies the view.
            mode = kind
            arguments = operands
        } else {
            return live
        }
        if mode != "XYZ" { return .internalDestination(.init(page: target.page, mode: mode, arguments: arguments)) }
        if arguments[2] == 0, target.arguments[2] == nil {
            // PDFKit projects both zero zoom and null zoom as unspecified.
            return .internalDestination(
                .init(page: target.page, mode: mode, arguments: [target.arguments[0], target.arguments[1], 0]))
        }
        return live
    }

    private static func bookmarks(from outline: [Raw.Entry]) throws -> [Writer.Bookmark] {
        var pending: [(level: Int, node: Writer.Bookmark)] = []
        for entry in outline.reversed() {
            try Task.checkCancellation()
            guard entry.level <= 65 else {
                throw ReadingPDFExporter.ExportError.navigation("Cannot rebuild a deeply nested outline.")
            }
            let target: Writer.Destination?
            switch entry.action {
            case .none: target = nil
            case .internalDestination(let dest), .namedDestination(let dest): target = dest
            case .other, .unresolved, .missingPage, .releasedPage:
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

    // Quartz preserves the exact view operands. PDFKit must also be able to follow the saved destination.
    private func matches(_ expected: Raw.Action, dictionary: Raw.Action, reader: Raw.Action?) -> Bool {
        guard let target = expected.target else { return expected == dictionary }
        guard let stored = dictionary.target, stored.page == target.page, stored.mode == target.mode,
            let actual = reader?.target, actual.page == target.page
        else { return false }
        // Quartz can parse a translated coordinate one ulp away from the number written as a PDF decimal.
        // Keep the page, mode, nulls and zoom exact, and allow only floating-point roundoff for positions.
        for i in target.arguments.indices where target.arguments[i] != stored.arguments[i] {
            guard !(target.mode == "XYZ" && i == 2), let wanted = target.arguments[i], let got = stored.arguments[i],
                abs(wanted - got) <= min(0.001, 4 * wanted.ulp)
            else { return false }
        }
        guard target.mode == "XYZ" else { return true }
        // PDFKit exposes XYZ coordinates and scale, but projects zero zoom as unspecified.
        for i in target.arguments.indices {
            let wanted = target.arguments[i]
            let got = actual.arguments[i]
            if wanted == got || (i == 2 && (wanted ?? 0) == (got ?? 0)) { continue }
            guard let wanted, let got, abs(wanted - got) < 0.001 else { return false }
        }
        return true
    }

    private func changes(in bytes: Data, pageCount: Int, stage: String, reopen: @Sendable (Data) -> PDFDocument?)
        async throws
        -> (links: [Writer.Link], outline: [Raw.Entry]?, firstDifference: String?)
    {
        let saved: Raw
        do {
            saved = try await Raw.read(bytes)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ReadingPDFExporter.ExportError.navigation("\(stage): cannot read PDF dictionaries (\(error)).")
        }
        guard saved.pageCount == pageCount, let document = reopen(bytes), document.pageCount == pageCount
        else {
            throw ReadingPDFExporter.ExportError.navigation("\(stage): cannot reopen \(pageCount) pages.")
        }
        let native = try await Self.projection(of: document)
        let rebased = try self.rebased(to: document)
        var observed: [Int: [Int: Raw.Link]] = [:]
        for link in native.links { observed[link.page, default: [:]][link.annotation] = link }
        var expected: [Int: [Int: Raw.Link]] = [:]
        for link in rebased.links { expected[link.page, default: [:]][link.annotation] = link }
        var repairs: [Writer.Link] = []
        var difference: String?
        var matched = 0
        for link in saved.links {
            try Task.checkCancellation()
            guard let original = expected[link.page]?[link.annotation], let target = original.action.target else {
                if link.action.isInternal {
                    throw ReadingPDFExporter.ExportError.navigation(
                        "\(stage) p\(link.page + 1) annotation=\(link.annotation): unexpected internal link.")
                }
                continue
            }
            guard Self.sameBounds(original.bounds, link.bounds), link.action != .other else {
                throw ReadingPDFExporter.ExportError.navigation(
                    "\(stage) p\(link.page + 1) annotation=\(link.annotation): link identity differs.")
            }
            matched += 1
            let reader = observed[link.page]?[link.annotation]
            if reader.map({ Self.sameBounds(original.bounds, $0.bounds) }) != true
                || !matches(original.action, dictionary: link.action, reader: reader?.action)
            {
                repairs.append(.init(page: link.page, annotation: link.annotation, destination: target))
                if difference == nil {
                    difference =
                        "\(stage) p\(link.page + 1) annotation=\(link.annotation): expected=\(original.action.summary) dictionary=\(link.action.summary) PDFKit=\(reader?.action.summary ?? "missing")"
                }
            }
        }
        guard matched == links.count else {
            throw ReadingPDFExporter.ExportError.navigation(
                "\(stage): missing link annotation (\(matched)/\(links.count)).")
        }
        let outline = rebased.outline
        var sameOutline =
            saved.hasValidOutlineCounts && saved.outline.count == outline.count && native.outline.count == outline.count
        if sameOutline {
            for (index, entry) in outline.enumerated() {
                try Task.checkCancellation()
                let raw = saved.outline[index]
                let live = native.outline[index]
                if raw.level != entry.level || live.level != entry.level || raw.title != entry.title
                    || live.title != entry.title
                    || raw.isOpen != entry.isOpen || !matches(entry.action, dictionary: raw.action, reader: live.action)
                {
                    sameOutline = false
                    if difference == nil {
                        difference =
                            "\(stage) bookmark=\(index + 1): expected=\(entry.action.summary) dictionary=\(raw.action.summary) PDFKit=\(live.action.summary) open=\(raw.isOpen)/\(entry.isOpen)"
                    }
                    break
                }
            }
        } else if difference == nil {
            difference =
                "\(stage) bookmarks: expected=\(outline.count) dictionary=\(saved.outline.count) PDFKit=\(native.outline.count) validCounts=\(saved.hasValidOutlineCounts)"
        }
        return (repairs, sameOutline ? nil : outline, difference)
    }

    @concurrent
    func verified(
        _ data: Data, pageCount: Int, stage: String,
        reopen: @Sendable (Data) -> PDFDocument? = { PDFDocument(data: $0) }
    ) async throws -> Data {
        do {
            let changes = try await changes(in: data, pageCount: pageCount, stage: "saved", reopen: reopen)
            if changes.links.isEmpty && changes.outline == nil { return data }
            let difference = changes.firstDifference ?? "saved navigation differs"
            let patched: Data
            do {
                let bookmarks = try changes.outline.map(Self.bookmarks(from:))
                patched = try Writer.repair(data, links: changes.links, bookmarks: bookmarks)
            } catch is CancellationError { throw CancellationError() } catch {
                throw ReadingPDFExporter.ExportError.navigation("\(difference); repair: \(error.localizedDescription)")
            }
            let remaining = try await self.changes(in: patched, pageCount: pageCount, stage: "repaired", reopen: reopen)
            if !remaining.links.isEmpty || remaining.outline != nil {
                throw ReadingPDFExporter.ExportError.navigation(
                    "\(difference); \(remaining.firstDifference ?? "repaired navigation differs")")
            }
            return patched
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ReadingPDFExporter.ExportError.navigation("\(stage): \(error.localizedDescription)")
        }
    }
}
