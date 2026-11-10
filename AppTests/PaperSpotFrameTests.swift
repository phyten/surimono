import AppKit
import PDFKit
import SurimonoCore
import Testing

@testable import Surimono

/// The frame the paper shows for a moment around a spot, such as a problem found before printing.
@MainActor
struct PaperSpotFrameTests {
    private func makePaper(pages: Int = 3) throws -> (view: PaperPDFView, source: PDFDocument, window: NSWindow) {
        let source = try #require(PDFDocument(data: TestFixtures.pdf("spot", pages: pages)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 594), styleMask: [.titled], backing: .buffered,
            defer: true)
        let view = PaperPDFView(frame: NSRect(x: 0, y: 0, width: 420, height: 594))
        window.contentView = view
        view.show(source, at: 0)
        view.apply(ViewOptions(layout: .single, scrollAxis: .vertical, transition: .instant, showsCoverAlone: false))
        view.layoutSubtreeIfNeeded()
        return (view, source, window)
    }

    private func frameView(in paper: PaperPDFView) -> PaperSpotFrameView? {
        paper.subviews.compactMap { $0 as? PaperSpotFrameView }.first
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    private let anchor = CGRect(x: 100, y: 600, width: 0.5, height: 0.5)

    private func spot(_ pageIndex: Int, _ anchor: CGRect, in document: PDFDocument) -> PaperSpot {
        PaperSpot(pageIndex: pageIndex, anchor: anchor, document: document)
    }

    @Test("枠は、紙が見せているページの問題の位置に重なり、紙の PDF には何も足さない", .timeLimit(.minutes(1)))
    func framesTheSpotOnTheShownPage() async throws {
        let (view, source, window) = try makePaper()
        view.goToPage(index: 1)
        view.layoutSubtreeIfNeeded()
        #expect(view.showSpot(spot(1, anchor, in: source), lifetime: .seconds(30)))
        let frame = try #require(frameView(in: view))
        try await waitUntil { frame.alphaValue > 0.99 && !frame.isHidden }
        // The page is 595 pt wide and shown at 420 / 595. The frame runs from 8 pt left of the spot to 8 pt inside
        // the page's right edge (495 pt), and is 32 pt tall.
        #expect(abs(frame.frame.width - 495 * 420 / 595) < 1.5)
        #expect(abs(frame.frame.height - 32 * 420 / 595) < 1.5)
        #expect(view.bounds.contains(frame.frame))
        // Nothing was written to the pages, so neither the print nor the export can carry the frame.
        #expect(view.document === source)
        for index in 0..<source.pageCount {
            #expect(source.page(at: index)?.annotations.isEmpty == true)
        }
        withExtendedLifetime(window) {}
    }

    @Test("枠はクリックを紙へ通し、書き換える見えない物にもならない")
    func framePassesClicksThrough() async throws {
        let (view, source, window) = try makePaper()
        view.goToPage(index: 1)
        view.layoutSubtreeIfNeeded()
        #expect(view.showSpot(spot(1, anchor, in: source), lifetime: .seconds(30)))
        let frame = try #require(frameView(in: view))
        try await waitUntil { frame.alphaValue > 0.99 }
        let inside = NSPoint(x: frame.frame.midX, y: frame.frame.midY)
        #expect(frame.hitTest(inside) == nil)
        #expect(!(view.hitTest(view.convert(inside, to: view.superview)) is PaperSpotFrameView))
        #expect(!frame.isAccessibilityElement())
        withExtendedLifetime(window) {}
    }

    @Test("見せていないページの問題や、紙が別の PDF のときに見つけた問題は受け付けず、枠も作らない")
    func refusesWhatThePaperDoesNotShow() throws {
        let (view, source, window) = try makePaper()
        // The paper shows page 1, so that only the document makes the difference.
        view.goToPage(index: 1)
        view.layoutSubtreeIfNeeded()
        let other = try #require(PDFDocument(data: TestFixtures.pdf("other", pages: 3)))
        #expect(!view.showSpot(spot(7, anchor, in: source)))
        #expect(!view.showSpot(spot(1, anchor, in: other)))
        #expect(frameView(in: view) == nil)
        withExtendedLifetime(window) {}
    }

    @Test("紙が同じページ数の別の PDF に替わったら、出ていた枠は消え、新しい PDF には出ない", .timeLimit(.minutes(1)))
    func replacedPagesTakeTheFrameAway() async throws {
        let (view, source, window) = try makePaper()
        view.goToPage(index: 1)
        view.layoutSubtreeIfNeeded()
        let old = spot(1, anchor, in: source)
        #expect(view.showSpot(old, lifetime: .seconds(30)))
        let frame = try #require(frameView(in: view))
        try await waitUntil { frame.alphaValue > 0.99 && !frame.isHidden }
        // The same number of pages, so that the old page number and rectangle would still find a place.
        let other = try #require(PDFDocument(data: TestFixtures.pdf("replacement", pages: 3)))
        view.show(other, at: 1)
        view.layoutSubtreeIfNeeded()
        try await waitUntil { frameView(in: view) == nil }
        #expect(frame.superview == nil)
        // The old request is refused now, and nothing shows on the new pages.
        #expect(!view.showSpot(old, lifetime: .seconds(30)))
        try await Task.sleep(for: .milliseconds(200))
        #expect(frameView(in: view) == nil)
        withExtendedLifetime(window) {}
    }

    @Test("見せ方が見開きに変わっても同じ PDF のあいだは、枠は残る", .timeLimit(.minutes(1)))
    func anotherWayOfShowingTheSamePagesKeepsTheFrame() async throws {
        let (view, source, window) = try makePaper(pages: 4)
        view.goToPage(index: 1)
        view.layoutSubtreeIfNeeded()
        #expect(view.showSpot(spot(1, anchor, in: source), lifetime: .seconds(30)))
        let frame = try #require(frameView(in: view))
        try await waitUntil { frame.alphaValue > 0.99 && !frame.isHidden }
        view.configure(
            source, at: 1,
            options: ViewOptions(
                layout: .spread, scrollAxis: .horizontal, transition: .instant, showsCoverAlone: false),
            logicalMargin: nil, showsPageNumbers: false)
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        #expect(frame.superview === view)
        withExtendedLifetime(window) {}
    }

    @Test("枠は、別のページへ移ると隠れ、そのページへ戻ると現れる")
    func frameFollowsThePageOutOfSightAndBack() async throws {
        let (view, source, window) = try makePaper()
        view.goToPage(index: 1)
        view.layoutSubtreeIfNeeded()
        #expect(view.showSpot(spot(1, anchor, in: source), lifetime: .seconds(30)))
        let frame = try #require(frameView(in: view))
        try await waitUntil { frame.alphaValue > 0.99 && !frame.isHidden }
        view.goToPage(index: 2)
        view.layoutSubtreeIfNeeded()
        try await waitUntil { frame.isHidden }
        view.goToPage(index: 1)
        view.layoutSubtreeIfNeeded()
        try await waitUntil { !frame.isHidden }
        withExtendedLifetime(window) {}
    }

    @Test("紙を拡大しても、枠は同じページの位置に付いてくる")
    func frameFollowsTheZoom() async throws {
        let (view, source, window) = try makePaper()
        view.goToPage(index: 0)
        view.layoutSubtreeIfNeeded()
        // High on the page: magnified, the paper shows its top half, and the band must lie whole in it.
        let high = spot(0, CGRect(x: 300, y: 700, width: 0.5, height: 0.5), in: source)
        #expect(view.showSpot(high, lifetime: .seconds(30)))
        let frame = try #require(frameView(in: view))
        try await waitUntil { frame.alphaValue > 0.99 && !frame.isHidden }
        let before = frame.frame
        view.setZoom(2, anchor: NSPoint(x: view.bounds.midX, y: view.bounds.maxY))
        view.layoutSubtreeIfNeeded()
        // The band's height is not cut by the window's edge, as its width is.
        try await waitUntil { abs(frame.frame.height - before.height * 2) < 2 }
        withExtendedLifetime(window) {}
    }

    @Test(
        "拡大した紙でページの下のほうの問題を示すと、手でスクロールしなくても枠が見える", .timeLimit(.minutes(1)),
        arguments: [2.0, 4.0])
    func scrollsToASpotOutOfSight(zoom: Double) async throws {
        let (view, source, window) = try makePaper()
        view.goToPage(index: 1)
        view.setZoom(zoom, anchor: nil)
        view.layoutSubtreeIfNeeded()
        // Low on the page: a magnified paper shows its top, and this is a long way below it.
        let low = spot(1, CGRect(x: 300, y: 100, width: 0.5, height: 0.5), in: source)
        let page = try #require(view.document?.page(at: 1))
        let lying = view.convert(PrintIssue.spotFrame(around: low.anchor, in: page.bounds(for: .cropBox)), from: page)
        #expect(!view.bounds.intersects(lying))
        #expect(view.showSpot(low, lifetime: .seconds(30)))
        let frame = try #require(frameView(in: view))
        try await waitUntil { frame.alphaValue > 0.99 && !frame.isHidden }
        // In sight, and whole in its height: the window's edge cuts only its far end.
        #expect(view.bounds.contains(frame.frame))
        #expect(abs(frame.frame.height - 32 * view.scaleFactor) < 1.5)
        #expect(frame.frame.minX >= 0)
        withExtendedLifetime(window) {}
    }

    @Test("枠の場所がもう見えているなら、紙はスクロールしない")
    func staysPutWhenTheSpotIsInSight() async throws {
        let (view, source, window) = try makePaper()
        view.goToPage(index: 0)
        view.setZoom(2, anchor: NSPoint(x: view.bounds.midX, y: view.bounds.maxY))
        view.layoutSubtreeIfNeeded()
        let clip = try #require(view.documentView?.enclosingScrollView?.contentView)
        // PDFKit settles the magnified layout a moment later, by a fraction of a point.
        try await Task.sleep(for: .milliseconds(200))
        let before = clip.bounds.origin
        // High on the page and right of its middle, where a magnified paper shows both the start of the frame and
        // all of its height.
        let high = spot(0, CGRect(x: 400, y: 700, width: 0.5, height: 0.5), in: source)
        #expect(view.showSpot(high, lifetime: .seconds(30)))
        let frame = try #require(frameView(in: view))
        try await waitUntil { frame.alphaValue > 0.99 && !frame.isHidden }
        #expect(abs(clip.bounds.origin.x - before.x) < 0.5)
        #expect(abs(clip.bounds.origin.y - before.y) < 0.5)
        withExtendedLifetime(window) {}
    }

    @Test("枠は決めた時間がたつと消え、紙の部品には何も残らない", .timeLimit(.minutes(1)))
    func frameGoesAway() async throws {
        let (view, source, window) = try makePaper()
        view.goToPage(index: 1)
        view.layoutSubtreeIfNeeded()
        #expect(view.showSpot(spot(1, anchor, in: source), lifetime: .milliseconds(100)))
        let frame = try #require(frameView(in: view))
        try await waitUntil { frameView(in: view) == nil }
        #expect(frame.superview == nil)
        withExtendedLifetime(window) {}
    }

    @Test("続けて別の問題を示すと、同じ枠が新しい位置へ移る")
    func anotherSpotReplacesTheFrame() async throws {
        let (view, source, window) = try makePaper()
        view.goToPage(index: 1)
        view.layoutSubtreeIfNeeded()
        #expect(view.showSpot(spot(1, anchor, in: source), lifetime: .seconds(30)))
        let frame = try #require(frameView(in: view))
        try await waitUntil { frame.alphaValue > 0.99 && !frame.isHidden }
        let first = frame.frame
        let lower = CGRect(x: 100, y: 300, width: 0.5, height: 0.5)
        #expect(view.showSpot(spot(1, lower, in: source), lifetime: .seconds(30)))
        try await waitUntil { frame.alphaValue > 0.99 && !frame.isHidden && abs(frame.frame.minY - first.minY) > 100 }
        #expect(view.subviews.compactMap { $0 as? PaperSpotFrameView }.count == 1)
        withExtendedLifetime(window) {}
    }
}
