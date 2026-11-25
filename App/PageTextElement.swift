import AppKit
import PDFKit

/// Screen readers may keep this leaf after the paper and even the window have gone.
nonisolated class PageTextElement: NSAccessibilityElement {
    let index: Int
    private let text: NSString
    private let lines: [NSRange]
    @MainActor final class Position {
        weak var anchor: NSView?
        var pageToAnchor = CGAffineTransform.identity
        var pageBounds = CGRect.zero

        // A reader can outlive the paper. A retry is valid only while this same generation is installed.
        private weak var paper: PageTextPDFView?
        private weak var sourcePage: PDFPage?
        private weak var sourceDocument: PDFDocument?
        private let text: NSString
        private var boxes: [CGRect]
        private var missing: [NSRange] = []
        private var nextRetry: ContinuousClock.Instant?
        private var resolving = false

        init(page: PDFPage, paper: PageTextPDFView, text: NSString) {
            self.paper = paper
            sourcePage = page
            sourceDocument = paper.document ?? page.document
            self.text = text
            boxes = Array(repeating: .zero, count: text.length)
            // Selections use UTF-16. Glyph indices can omit line breaks or count a surrogate pair once.
            var offset = 0
            while offset < text.length {
                let range = text.rangeOfComposedCharacterSequence(at: offset)
                if text.rangeOfCharacter(from: .newlines, options: [], range: range).location == NSNotFound,
                    !store(paper.characterSelectionBounds(for: range, on: page), for: range)
                {
                    missing.append(range)
                }
                offset = NSMaxRange(range)
            }
        }

        private func store(_ box: CGRect?, for range: NSRange) -> Bool {
            guard let box, PageTextGeometry.usable(box) else {
                return false
            }
            for unit in range.location..<NSMaxRange(range) { boxes[unit] = box }
            return true
        }

        private func fillMissing(in requested: NSRange? = nil, _ bounds: (NSRange) -> CGRect?) {
            missing.removeAll { range in
                if let requested, NSIntersectionRange(range, requested).length == 0 { return false }
                return store(bounds(range), for: range)
            }
        }

        private func retry(for requested: NSRange?) {
            func needsBounds() -> Bool {
                guard let requested else { return !missing.isEmpty }
                return missing.contains { NSIntersectionRange($0, requested).length > 0 }
            }
            guard !resolving, !missing.isEmpty, anchor != nil, let paper else { return }
            if let nextRetry, paper.selectionRetryTime < nextRetry { return }
            guard needsBounds(),
                let document = sourceDocument, paper.document === document,
                let page = sourcePage, page.document === document
            else { return }
            resolving = true
            defer { resolving = false }
            withExtendedLifetime(document) {
                if let liveText = page.string, text.compare(liveText, options: .literal) == .orderedSame {
                    fillMissing(in: requested) { paper.characterSelectionBounds(for: $0, on: page) }
                    guard needsBounds() else { return }
                    // A native copy can resolve all remaining ranges without keeping another document alive.
                    paper.withSelectionCopy(of: page, matching: text) { copy in
                        fillMissing { copy.selection(for: $0)?.bounds(for: copy) }
                    }
                }
                // Nonprinting characters may stay unresolved. Allow a full interval after the scan finishes
                // before either the source or a copy can occupy the main thread again.
                nextRetry = paper.selectionRetryTime + .milliseconds(250)
            }
        }

        func pageRect(for range: NSRange) -> CGRect {
            guard range.length > 0 else { return .zero }
            retry(for: range)
            let bounds = boxes[range.location..<NSMaxRange(range)].reduce(CGRect.null) {
                $1.isEmpty ? $0 : $0.union($1)
            }
            return PageTextGeometry.usable(bounds) ? bounds : .zero
        }

        func index(at point: CGPoint) -> Int {
            guard let local = pagePoint(point) else { return NSNotFound }
            if let index = boxes.firstIndex(where: { $0.contains(local) }) { return index }
            retry(for: nil)
            return boxes.firstIndex { $0.contains(local) } ?? NSNotFound
        }

        #if DEBUG
            var estimatedBytes: Int {
                boxes.capacity * MemoryLayout<CGRect>.stride + missing.capacity * MemoryLayout<NSRange>.stride
            }
        #endif

        func pagePoint(_ point: CGPoint) -> CGPoint? {
            guard let anchor, let window = anchor.window else { return nil }
            let local = anchor.convert(window.convertPoint(fromScreen: point), from: nil).applying(
                pageToAnchor.inverted())
            return local.x.isFinite && local.y.isFinite ? local : nil
        }

        func screenRect(_ rect: CGRect) -> CGRect {
            guard PageTextGeometry.usable(rect), let anchor, let window = anchor.window else { return .zero }
            let local = rect.applying(pageToAnchor)
            guard PageTextGeometry.usable(local) else { return .zero }
            let box = window.convertToScreen(anchor.convert(local, to: nil))
            return PageTextGeometry.usable(box) ? box : .zero
        }
    }
    let position: Position

    @MainActor init(page: PDFPage, index: Int, parent: PageTextPDFView) {
        self.index = index
        #if DEBUG
            let start = ShownDocumentsProbe.measuresElements ? ProcessInfo.processInfo.systemUptime : nil
        #endif
        // Copy the code units as well: a bridged NSString may otherwise share its PDF provider's storage.
        let units = Array((page.string ?? "").utf16)
        let text = NSString(characters: units, length: units.count)
        #if DEBUG
            if let start {
                let seconds = ProcessInfo.processInfo.systemUptime - start
                if ShownDocumentsProbe.firstTextSeconds == nil { ShownDocumentsProbe.firstTextSeconds = seconds }
                firstReadSeconds = seconds
                ShownDocumentsProbe.textSeconds += seconds
            }
        #endif
        self.text = text
        var lines: [NSRange] = []
        var offset = 0
        while offset < text.length {
            let line = text.lineRange(for: NSRange(location: offset, length: 0))
            lines.append(line)
            offset = NSMaxRange(line)
        }
        if lines.isEmpty || text.lineRange(for: NSRange(location: offset, length: 0)).length == 0 {
            lines.append(NSRange(location: offset, length: 0))
        }
        self.lines = lines
        position = Position(page: page, paper: parent, text: text)
        super.init()
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(String(localized: "Page \(self.index + 1)"))
        setAccessibilityParent(parent)
    }

    #if DEBUG
        private(set) var firstReadSeconds: Double?
        @MainActor var estimatedBytes: Int {
            class_getInstanceSize(PageTextElement.self) + class_getInstanceSize(Position.self) + text.length * 2
                + lines.capacity * MemoryLayout<NSRange>.stride + position.estimatedBytes
        }
    #endif

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityValue() -> Any? { text as String }
    override func accessibilityNumberOfCharacters() -> Int { text.length }

    private func valid(_ range: NSRange) -> Bool {
        range.location >= 0 && range.location <= text.length && range.length >= 0
            && range.length <= text.length - range.location
    }

    override func accessibilityString(for range: NSRange) -> String? {
        valid(range) ? text.substring(with: range) : nil
    }

    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        accessibilityString(for: range).map { NSAttributedString(string: $0) }
    }

    override func accessibilityRange(forLine line: Int) -> NSRange {
        lines.indices.contains(line) ? lines[line] : NSRange(location: NSNotFound, length: 0)
    }

    override func accessibilityLine(for index: Int) -> Int {
        if index == text.length { return lines.count - 1 }
        return lines.firstIndex { NSLocationInRange(index, $0) } ?? NSNotFound
    }

    override func accessibilityRange(for index: Int) -> NSRange {
        guard (0..<text.length).contains(index) else { return NSRange(location: NSNotFound, length: 0) }
        return text.rangeOfComposedCharacterSequence(at: index)
    }

    override func accessibilityRange(for point: NSPoint) -> NSRange {
        let position = position
        return accessibilityRange(for: onPaperAccessibilityMain { position.index(at: point) })
    }

    override func accessibilityFrame() -> NSRect {
        let position = position
        return onPaperAccessibilityMain { position.screenRect(position.pageBounds) }
    }

    override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard valid(range) else { return .zero }
        let position = position
        return onPaperAccessibilityMain {
            guard position.anchor?.window != nil else { return .zero }
            return position.screenRect(position.pageRect(for: range))
        }
    }
}

@MainActor enum PageTextGeometry {
    static func usable(_ box: CGRect) -> Bool {
        box.origin.x.isFinite && box.origin.y.isFinite && box.size.width.isFinite && box.size.height.isFinite
            && !box.isInfinite && !box.isEmpty && box.maxX.isFinite && box.maxY.isFinite
    }

    static func withCopy(of page: PDFPage, matching text: NSString, read: (PDFPage) -> Void) {
        // Keep the native font metrics: serializing and reopening a PDF page can change its selection height.
        guard let copy = page.copy() as? PDFPage, copy !== page else { return }
        let document = PDFDocument()
        document.insert(copy, at: 0)
        // A range is only transferable when the copied text and page coordinate system still match.
        guard let copiedText = copy.string,
            text.compare(copiedText, options: .literal) == .orderedSame,
            page.rotation == copy.rotation, page.bounds(for: .mediaBox) == copy.bounds(for: .mediaBox),
            page.bounds(for: .cropBox) == copy.bounds(for: .cropBox)
        else { return }
        withExtendedLifetime(document) { read(copy) }
    }
}

#if DEBUG
    // Only the external reader's fixture advertises this getter. Ordinary pages use AppKit's default attributes.
    nonisolated final class ProbePageTextElement: PageTextElement {
        @MainActor init(page: PDFPage, index: Int, parent: PageTextPDFView, token: String) {
            super.init(page: page, index: index, parent: parent)
            setAccessibilityIdentifier(token + ".page." + String(index))
        }

        override func accessibilityIdentifier() -> String? { super.accessibilityIdentifier() }
    }
#endif

// AX requests need an immediate result. AppKit coordinate conversion must run on the main thread even
// when an Objective-C caller enters a nonisolated accessibility method from another queue.
nonisolated func onPaperAccessibilityMain<Value: Sendable>(_ read: @MainActor () -> Value) -> Value {
    if Thread.isMainThread { return MainActor.assumeIsolated(read) }
    return DispatchQueue.main.sync { read() }
}
