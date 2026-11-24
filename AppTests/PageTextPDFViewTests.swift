import AppKit
import CoreText
import PDFKit
import Testing

@testable import Surimono

@MainActor
struct PageTextPDFViewTests {
    @Test("画面を読むアプリに渡す子は、Surimono のページの要素だけになる")
    func childrenAreOurOwnElements() throws {
        let (view, window) = try makePaper(pages: ["first page"])
        let children = try #require(view.accessibilityChildren())
        #expect(!children.isEmpty)
        #expect(children.allSatisfy { $0 is PageTextElement })
        withExtendedLifetime(window) {}
    }

    @Test("テストの中では PDFKit のページ解析を止める（CI でスレッドを使い切って本体が固まるため）")
    func analysisStopsInTests() throws {
        let view = PageTextPDFView()
        guard view.responds(to: NSSelectorFromString("setDocumentAnalysisEnabled:")) else {
            #expect(view.document == nil)
            return
        }
        try #require(
            view.responds(to: NSSelectorFromString("isDocumentAnalysisEnabled"))
                || view.responds(to: NSSelectorFromString("documentAnalysisEnabled")))
        #expect(view.value(forKey: "documentAnalysisEnabled") as? Bool == false)
        let document: PDFDocument = try #require(PDFDocument(data: textPDF(["analysis setting"])))
        view.document = document
        #expect(view.value(forKey: "documentAnalysisEnabled") as? Bool == false)
    }

    @Test("PDFKit がメインスレッド以外から document を読むと、紙に入れた文書が返る")
    func documentIsReadableFromTheAnalysisQueue() async throws {
        let view = PageTextPDFView()
        let document = try #require(PDFDocument(data: textPDF(["first page"])))
        view.document = document
        let getter = #selector(getter: PDFView.document)
        // An isolated override would trap the entire test host on the background message below.
        let inherited = try #require(class_getInstanceMethod(PDFView.self, getter))
        try #require(class_getInstanceMethod(PageTextPDFView.self, getter) == inherited)
        // The worker sends only the inherited getter; the test retains the view and leaves its document in place.
        nonisolated(unsafe) let receiver: NSObject = view
        let identity: ObjectIdentifier? = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { @Sendable in
                #expect(!Thread.isMainThread)
                let result = receiver.perform(getter)?.takeUnretainedValue()
                continuation.resume(returning: result.map(ObjectIdentifier.init))
            }
        }
        #expect(identity == ObjectIdentifier(document))
    }

    @Test("ページの要素は、そのページの文字を読める")
    func elementReadsItsPage() throws {
        let (view, window) = try makePaper(pages: ["first page"])
        let element = try #require(view.accessibilityChildren()?.first as? PageTextElement)
        #expect(element.accessibilityRole() == .staticText)
        #expect((element.accessibilityValue() as? String)?.contains("first page") == true)
        #expect(element.accessibilityLabel() == String(localized: "Page \(1)"))
        withExtendedLifetime(window) {}
    }

    @Test("座標から要素を探しても、PDFKit のノードを渡さない")
    func hitTestStaysOnOurElements() throws {
        let (view, window) = try makePaper(pages: ["first page"])
        let center = window.convertPoint(toScreen: view.convert(NSPoint(x: 210, y: 297), to: nil))
        #expect(view.accessibilityHitTest(center) is PageTextElement)
        withExtendedLifetime(window) {}
    }

    @Test("紙をクリックして内側のビューにフォーカスが移っても、PDFKit のノードを渡さない")
    func focusStaysOnOurElements() throws {
        let (view, window) = try makePaper(pages: ["first page"])
        let inner = try #require(view.documentView)
        #expect(window.makeFirstResponder(inner))
        let scrollView = try #require(inner.enclosingScrollView)
        #expect((NSAccessibility.unignoredAncestor(of: inner) as? NSView) === view)
        #expect(scrollView.accessibilityChildren()?.isEmpty == true)
        #expect((view.accessibilityFocusedUIElement as? NSView) === view)
        withExtendedLifetime(window) {}
    }

    @Test("見えているページが変わると、子もそのページになる")
    func childrenFollowTheVisiblePage() throws {
        let (view, window) = try makePaper(pages: ["first page", "second page"])
        let second = try #require(view.document?.page(at: 1))
        view.go(to: second)
        view.layoutSubtreeIfNeeded()
        let element = try #require(view.accessibilityChildren()?.first as? PageTextElement)
        #expect((element.accessibilityValue() as? String)?.contains("second page") == true)
        #expect(element.accessibilityLabel() == String(localized: "Page \(2)"))
        withExtendedLifetime(window) {}
    }

    @Test("同じページには同じ要素を返す（読み手が読んでいる場所を失わないため）")
    func elementsStayTheSameForAPage() throws {
        let (view, window) = try makePaper(pages: ["first page"])
        let first = try #require(view.accessibilityChildren()?.first as? PageTextElement)
        let again = try #require(view.accessibilityChildren()?.first as? PageTextElement)
        #expect(first === again)
        withExtendedLifetime(window) {}
    }

    @Test("紙と文書を捨てたあとに読まれても、持っていた要素は文字を返す")
    func elementOutlivesThePaper() throws {
        let element = try autoreleasepool { () throws -> PageTextElement in
            let (view, window) = try makePaper(pages: ["first page"])
            let element = try #require(view.accessibilityChildren()?.first as? PageTextElement)
            view.document = nil
            window.contentView = nil
            return element
        }
        #expect((element.accessibilityValue() as? String)?.contains("first page") == true)
        #expect(element.accessibilityFrame() == .zero)
    }

    @Test("ページと元のPDFを解放した後も、公開済みの要素だけで本文・範囲・行と位置に答える")
    func snapshotOutlivesPDF() throws {
        weak var source: PDFDocument?
        weak var originalPage: PDFPage?
        weak var parent: PageTextPDFView?
        let leaf = try autoreleasepool {
            let document = try #require(PDFDocument(data: textPDF(["first page"])))
            let page = try #require(document.page(at: 0))
            // Keep PDFKit's window and analysis caches outside this ownership assertion.
            let paper = PageTextPDFView()
            source = document
            originalPage = page
            parent = paper
            return PageTextElement(page: page, index: 0, parent: paper)
        }
        try #require(source == nil && originalPage == nil && parent == nil)
        let text = try #require(leaf.accessibilityValue() as? String)
        let range = (text as NSString).range(of: "first")
        try #require(range.location != NSNotFound)
        #expect(leaf.accessibilityRole() == .staticText)
        #expect(leaf.accessibilityLabel() == String(localized: "Page \(1)"))
        #expect(leaf.accessibilityNumberOfCharacters() == text.utf16.count)
        #expect(leaf.accessibilityString(for: range) == "first")
        #expect(leaf.accessibilityAttributedString(for: range)?.string == "first")
        #expect(leaf.accessibilityLine(for: range.location) == 0)
        #expect(leaf.accessibilityRange(forLine: 0) == (text as NSString).lineRange(for: range))
        #expect(leaf.accessibilityRange(for: range.location) == NSRange(location: range.location, length: 1))
        #expect(leaf.accessibilityFrame() == .zero)
        #expect(leaf.accessibilityFrame(for: range) == .zero)
        #expect(leaf.accessibilityRange(for: NSPoint.zero).location == NSNotFound)
        #expect(leaf.accessibilityParent() == nil)
        #expect(leaf.accessibilityChildren()?.isEmpty != false)
        #expect(leaf.accessibilityString(for: NSRange(location: NSNotFound, length: 1)) == nil)
    }

    @Test("公開した文字の矩形は紙の上を指し、同じビューが別の文書に替わると消える")
    func snapshotRangeGeometry() throws {
        let (view, window) = try makePaper(pages: ["first page"])
        let leaf = try #require(view.accessibilityChildren()?.first as? PageTextElement)
        let page = try #require(view.document?.page(at: 0))
        let box = window.convertToScreen(view.convert(view.convert(page.characterBounds(at: 0), from: page), to: nil))
        let range = NSRange(location: 0, length: 1)
        let frame = leaf.accessibilityFrame(for: range)
        #expect(!frame.isEmpty && abs(box.midX - frame.midX) < 0.1 && abs(box.midY - frame.midY) < 0.1)
        #expect(leaf.accessibilityRange(for: CGPoint(x: frame.midX, y: frame.midY)) == range)
        let replacement: PDFDocument = try #require(PDFDocument(data: textPDF(["second page"])))
        view.document = replacement
        #expect(leaf.accessibilityFrame() == .zero)
        #expect(leaf.accessibilityFrame(for: range) == .zero)
        #expect(leaf.accessibilityString(for: range) == "f")
    }

    private func makePaper(pages: [String]) throws -> (PageTextPDFView, NSWindow) {
        let document = try #require(PDFDocument(data: textPDF(pages)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 594), styleMask: [.titled], backing: .buffered,
            defer: true)
        let view = PageTextPDFView(frame: NSRect(x: 0, y: 0, width: 420, height: 594))
        window.contentView = view
        view.displayMode = .singlePage
        view.document = document
        // A window that is not on screen has no visible pages until the view goes to one.
        view.go(to: try #require(document.page(at: 0)))
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    private func textPDF(_ pages: [String]) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 420, height: 594)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for text in pages {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 40, y: 500)
            let string = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)])
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}
