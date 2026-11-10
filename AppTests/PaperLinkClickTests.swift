import AppKit
import PDFKit
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct PaperLinkClickTests {
    /// In view coordinates of the 420 x 594 paper showing a 595 x 842 page.
    private static let onLink = NSPoint(x: 210, y: 300)
    private static let offLink = NSPoint(x: 210, y: 100)
    private static let onEdgeLink = NSPoint(x: 400, y: 300)
    private static let site = URL(string: "https://example.com/paper")

    @Test("リンクの上では指差し、それ以外では矢印のカーソルにする", arguments: [false, true])
    func cursor(selectsText: Bool) throws {
        let (view, window, _) = try paper()
        view.selectsText = selectsText
        #expect(view.cursor(at: Self.onLink) == NSCursor.pointingHand)
        #expect(view.cursor(at: Self.offLink) == NSCursor.arrow)
        withExtendedLifetime(window) {}
    }

    @Test("拡大中もリンクの上では指差し、それ以外では手のひらのカーソルにする")
    func cursorWhileZoomed() throws {
        let (view, window, _) = try paper()
        view.setZoom(2, anchor: Self.onLink)
        view.layoutSubtreeIfNeeded()
        // The anchor stays under the pointer, within the whole pixels the scroll position snaps to.
        #expect(view.cursor(at: Self.onLink) == NSCursor.pointingHand)
        #expect(view.cursor(at: NSPoint(x: 210, y: 500)) == NSCursor.openHand)
        withExtendedLifetime(window) {}
    }

    @Test("文書内のリンクをクリックすると、そのページへ移ってページの変化を知らせる")
    func internalLink() throws {
        let (view, window, _) = try paper()
        var reported: [Int] = []
        var turns = 0
        view.onPageChange = { reported.append($0) }
        view.onTurn = { turns += 1 }
        click(view, window, at: Self.onLink)
        #expect(view.currentPageIndex == 1)
        #expect(reported.last == 1)
        #expect(turns == 1)
        withExtendedLifetime(window) {}
    }

    @Test("URLのリンクをクリックすると、そのURLを開いてページは送らない")
    func externalLink() async throws {
        let (view, window, opened) = try paper(external: true)
        click(view, window, at: Self.onLink)
        for _ in 0..<100 where opened.urls.isEmpty { await Task.yield() }
        #expect(opened.urls == [try #require(Self.site)])
        #expect(view.currentPageIndex == 0)
        withExtendedLifetime(window) {}
    }

    @Test("紙の端にあるリンクをクリックしても、端のクリックとしてページを送らない")
    func linkAtTheEdge() async throws {
        let (view, window, opened) = try paper(external: true, linkAtEdge: true)
        var turns = 0
        view.onTurn = { turns += 1 }
        click(view, window, at: Self.onEdgeLink)
        for _ in 0..<100 where opened.urls.isEmpty { await Task.yield() }
        #expect(opened.urls == [try #require(Self.site)])
        #expect(turns == 0)
        #expect(view.currentPageIndex == 0)
        // The same edge still turns the page where there is no link.
        click(view, window, at: NSPoint(x: 400, y: 100))
        #expect(view.currentPageIndex == 1)
        withExtendedLifetime(window) {}
    }

    @Test("リンクの上から始めたドラッグは紙を動かすだけで、リンクをたどらない")
    func dragFromLink() throws {
        let (view, window, _) = try paper()
        view.setZoom(2, anchor: Self.onLink)
        view.layoutSubtreeIfNeeded()
        let clip = try #require(view.documentView?.enclosingScrollView?.contentView)
        let before = clip.bounds.origin
        view.mouseDown(with: event(.leftMouseDown, view, window, at: Self.onLink))
        let end = NSPoint(x: Self.onLink.x + 40, y: Self.onLink.y)
        view.mouseDragged(with: event(.leftMouseDragged, view, window, at: end, dx: 40))
        view.mouseUp(with: event(.leftMouseUp, view, window, at: end))
        #expect(view.currentPageIndex == 0)
        #expect(abs(clip.bounds.origin.x - before.x) > 10)
        withExtendedLifetime(window) {}
    }

    @Test("リンクをたどったクリックに続くダブルクリックでは拡大しない")
    func doubleClickOnLink() throws {
        let (view, window, _) = try paper()
        click(view, window, at: Self.onLink)
        view.mouseDown(with: event(.leftMouseDown, view, window, at: Self.onLink, clicks: 2))
        view.mouseUp(with: event(.leftMouseUp, view, window, at: Self.onLink, clicks: 2))
        #expect(view.currentPageIndex == 1)
        #expect(view.zoom == 1)
        // A double-click of its own, away from a link, still zooms.
        view.mouseDown(with: event(.leftMouseDown, view, window, at: Self.offLink))
        view.mouseUp(with: event(.leftMouseUp, view, window, at: Self.offLink))
        view.mouseDown(with: event(.leftMouseDown, view, window, at: Self.offLink, clicks: 2))
        #expect(view.zoom == 2)
        withExtendedLifetime(window) {}
    }

    // MARK: - Helpers

    @MainActor
    private final class Opened {
        var urls: [URL] = []
    }

    /// Three pages; the first has one link: to the second page, or to a web site.
    private func paper(external: Bool = false, linkAtEdge: Bool = false) throws -> (PaperPDFView, NSWindow, Opened) {
        let source = try #require(PDFDocument(data: TestFixtures.pdf("links", pages: 3)))
        let first = try #require(source.page(at: 0))
        // The page is shown at 420 / 595 of its size: view (210, 300) is page (297.5, 425), view x 400 is page x 567.
        let bounds =
            linkAtEdge
            ? CGRect(x: 540, y: 400, width: 50, height: 50) : CGRect(x: 250, y: 400, width: 100, height: 50)
        let annotation = PDFAnnotation(bounds: bounds, forType: .link, withProperties: nil)
        if external {
            annotation.action = PDFActionURL(url: try #require(Self.site))
        } else {
            let second = try #require(source.page(at: 1))
            annotation.action = PDFActionGoTo(destination: PDFDestination(page: second, at: CGPoint(x: 0, y: 842)))
        }
        first.addAnnotation(annotation)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 594), styleMask: [.titled], backing: .buffered,
            defer: true)
        let view = PaperPDFView(frame: NSRect(x: 0, y: 0, width: 420, height: 594))
        window.contentView = view
        let opened = Opened()
        view.linkHandler = PaperLinkHandler(openExternal: { url in await MainActor.run { opened.urls.append(url) } })
        view.onToast = { _ in Issue.record("リンクをたどってトーストを出さない") }
        view.show(source, at: 0)
        view.apply(ViewOptions(layout: .single, scrollAxis: .vertical, transition: .instant, showsCoverAlone: false))
        view.layoutSubtreeIfNeeded()
        return (view, window, opened)
    }

    private func click(_ view: PaperPDFView, _ window: NSWindow, at point: NSPoint) {
        view.mouseDown(with: event(.leftMouseDown, view, window, at: point))
        view.mouseUp(with: event(.leftMouseUp, view, window, at: point))
    }

    private func event(
        _ type: NSEvent.EventType, _ view: PaperPDFView, _ window: NSWindow, at point: NSPoint, dx: CGFloat = 0,
        clicks: Int = 1
    ) -> NSEvent {
        let event = PaperClickEvent()
        event.kind = type
        event.target = window
        event.point = view.convert(point, to: nil)
        event.dx = dx
        event.clicks = clicks
        return event
    }
}

/// Synthetic mouse events, so the clicks need no pointing device.
nonisolated private final class PaperClickEvent: NSEvent {
    var kind: NSEvent.EventType = .leftMouseDown
    var target: NSWindow?
    var point = NSPoint.zero
    var dx: CGFloat = 0
    var clicks = 1
    override var type: NSEvent.EventType { kind }
    override var window: NSWindow? { target }
    override var locationInWindow: NSPoint { point }
    override var deltaX: CGFloat { dx }
    override var deltaY: CGFloat { 0 }
    override var clickCount: Int { clicks }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
    override var timestamp: TimeInterval { 0 }
}
