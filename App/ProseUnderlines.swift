import PDFKit

/// PDFKit places these views over the reading copy and keeps them aligned during zooms and page turns.
final class ProseUnderlines: NSObject, PDFPageOverlayViewProvider {
    private let views = NSMapTable<PDFPage, UnderlineView>.weakToWeakObjects()
    private(set) var strokes: [PDFPage: [CGRect]] = [:]

    func show(_ selections: [PDFSelection]) {
        var next: [PDFPage: [CGRect]] = [:]
        for selection in selections {
            for line in selection.selectionsByLine() {
                guard let page = line.pages.first else { continue }
                let box = line.bounds(for: page)
                guard !box.isEmpty else { continue }
                next[page, default: []].append(
                    CGRect(x: box.minX, y: box.minY, width: box.width, height: min(1.5, box.height)))
            }
        }
        for page in Set(strokes.keys).union(next.keys) {
            views.object(forKey: page)?.strokes = next[page] ?? []
        }
        strokes = next
    }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        let overlay = UnderlineView(frame: .zero)
        overlay.paper = view
        overlay.page = page
        overlay.strokes = strokes[page] ?? []
        overlay.setAccessibilityElement(false)
        views.setObject(overlay, forKey: page)
        return overlay
    }

    private final class UnderlineView: NSView {
        weak var paper: PDFView?
        weak var page: PDFPage?
        var strokes: [CGRect] = [] {
            didSet {
                isHidden = strokes.isEmpty
                needsDisplay = true
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            guard !strokes.isEmpty, let paper, let page else { return }
            NSColor(PrintPalette.paperAi).setFill()
            for stroke in strokes {
                convert(paper.convert(stroke, from: page), from: paper).fill()
            }
        }
    }
}
