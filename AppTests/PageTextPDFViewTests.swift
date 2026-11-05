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
