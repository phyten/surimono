import AppKit
import PDFKit

/// Screen readers may keep this leaf after the paper and even the window have gone.
nonisolated final class PageTextElement: NSAccessibilityElement {
    let index: Int
    private let text: NSString
    private let lines: [NSRange]
    private let boxes: [CGRect]
    @MainActor final class Position {
        weak var anchor: NSView?
        var pageToAnchor = CGAffineTransform.identity
        var pageBounds = CGRect.zero

        func pagePoint(_ point: CGPoint) -> CGPoint? {
            guard let anchor, let window = anchor.window else { return nil }
            return anchor.convert(window.convertPoint(fromScreen: point), from: nil).applying(pageToAnchor.inverted())
        }

        func screenRect(_ rect: CGRect) -> CGRect {
            guard !rect.isNull, !rect.isEmpty, let anchor, let window = anchor.window else { return .zero }
            return window.convertToScreen(anchor.convert(rect.applying(pageToAnchor), to: nil))
        }
    }
    let position: Position

    @MainActor init(page: PDFPage, index: Int, parent: PageTextPDFView) {
        position = Position()
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
        boxes = (0..<min(text.length, page.numberOfCharacters)).map { page.characterBounds(at: $0) }
        super.init()
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(String(localized: "Page \(index + 1)"))
        setAccessibilityParent(parent)
    }

    #if DEBUG
        private(set) var firstReadSeconds: Double?
        var estimatedBytes: Int {
            class_getInstanceSize(PageTextElement.self) + class_getInstanceSize(Position.self) + text.length * 2
                + lines.capacity * MemoryLayout<NSRange>.stride + boxes.capacity * MemoryLayout<CGRect>.stride
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
        guard let local = MainActor.assumeIsolated({ position.pagePoint(point) }) else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return accessibilityRange(for: boxes.firstIndex { $0.contains(local) } ?? NSNotFound)
    }

    override func accessibilityFrame() -> NSRect {
        let position = position
        return MainActor.assumeIsolated { position.screenRect(position.pageBounds) }
    }

    override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard valid(range), range.location < boxes.count else { return .zero }
        let end = min(NSMaxRange(range), boxes.count)
        let bounds = boxes[range.location..<end].reduce(CGRect.null) { $1.isEmpty ? $0 : $0.union($1) }
        let position = position
        return MainActor.assumeIsolated { position.screenRect(bounds) }
    }
}
