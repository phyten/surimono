import AppKit
import PDFKit
import SurimonoCore
import SwiftUI
import Testing

@testable import Surimono

@MainActor
struct PaperViewTests {
    @Test(
        "表示モードに戻って紙を作り直すと、覚えているページから表示する", .timeLimit(.minutes(1)),
        arguments: [ViewOptions.Transition.scroll, .instant])
    func recreatedPaperOpensAtTheRememberedPage(transition: ViewOptions.Transition) async throws {
        let document = try #require(PDFDocument(data: TestFixtures.pdf("paper", pages: 6)))
        var reported: [Int] = []
        let options = ViewOptions(
            layout: .single, scrollAxis: .vertical, transition: transition, showsCoverAlone: false)
        let paper = PaperView(
            document: document, initialPageIndex: 3, options: options, zoom: 1, controller: PaperController(),
            onZoomChange: { _ in }, onPageChange: { reported.append($0) }, onTurn: {}, onKey: { _ in false })
        // As in the document window: SwiftUI makes the paper view without a size and sizes it when laying out.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 594), styleMask: [.titled], backing: .buffered,
            defer: true)
        let host = NSHostingView(rootView: paper)
        window.contentView = host
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let view = try #require(host.paperView)
        #expect(view.currentPageIndex == 3)
        #expect(reported.last == 3)
        withExtendedLifetime(window) {}
    }

    @Test("ピンチで拡大した倍率は、指を離したあとに PDFKit が倍率を変えても保つ", .timeLimit(.minutes(1)))
    func pinchedZoomStays() async throws {
        let (view, window) = try await makeSinglePagePaper()
        var reported: [Double] = []
        view.onZoomChange = { reported.append($0) }
        let fitted = view.scaleFactor
        view.magnify(by: 0.5, at: NSPoint(x: view.bounds.midX, y: view.bounds.midY))
        #expect(abs(view.zoom - 1.5) < 0.001)
        #expect(abs(view.scaleFactor - fitted * 1.5) < 0.01)
        #expect(abs((reported.last ?? 0) - 1.5) < 0.001)
        // As PDFKit's scroll view did at the end of a pinch, rescale behind the view's back.
        view.scaleFactor = fitted
        try await Task.sleep(for: .milliseconds(50))
        #expect(abs(view.zoom - 1.5) < 0.001)
        #expect(abs(view.scaleFactor - fitted * 1.5) < 0.01)
        withExtendedLifetime(window) {}
    }

    @Test("ピンチで縮めても、窓に合わせた大きさより小さくはならない", .timeLimit(.minutes(1)))
    func pinchStopsAtTheFit() async throws {
        let (view, window) = try await makeSinglePagePaper()
        let fitted = view.scaleFactor
        let center = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        view.magnify(by: 1, at: center)
        view.magnify(by: -0.9, at: center)
        #expect(view.zoom == 1)
        #expect(abs(view.scaleFactor - fitted) < 0.01)
        withExtendedLifetime(window) {}
    }

    @Test("紙に重なるパネルの上のピンチは、紙の拡大に使わない", .timeLimit(.minutes(1)))
    func pinchOverAPanelIsNotThePapers() async throws {
        let document = try #require(PDFDocument(data: TestFixtures.pdf("overlay", pages: 2)))
        let options = ViewOptions(layout: .single, scrollAxis: .vertical, transition: .instant, showsCoverAlone: false)
        let paper = PaperView(
            document: document, initialPageIndex: 0, options: options, zoom: 1, controller: PaperController(),
            onZoomChange: { _ in }, onPageChange: { _ in }, onTurn: {}, onKey: { _ in false })
        // As the thumbnails and the Smart Removal panel do, a panel covers the right side of the paper.
        let root = ZStack(alignment: .trailing) {
            paper
            Color.gray.frame(width: 120)
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 594), styleMask: [.titled], backing: .buffered,
            defer: true)
        let host = NSHostingView(rootView: root)
        window.contentView = host
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let view = try #require(host.paperView)
        #expect(view.isPaper(atWindowPoint: NSPoint(x: 100, y: 300)))
        #expect(!view.isPaper(atWindowPoint: NSPoint(x: 380, y: 300)))
        withExtendedLifetime(window) {}
    }

    /// A paper view of a six-page PDF filling a window. It is used without SwiftUI, whose fixed zoom input would
    /// otherwise set the zoom back on its next update.
    private func makeSinglePagePaper() async throws -> (PaperPDFView, NSWindow) {
        let document = try #require(PDFDocument(data: TestFixtures.pdf("pinch", pages: 6)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 594), styleMask: [.titled], backing: .buffered,
            defer: true)
        let view = PaperPDFView(frame: NSRect(x: 0, y: 0, width: 420, height: 594))
        window.contentView = view
        view.show(document, at: 0)
        view.apply(ViewOptions(layout: .single, scrollAxis: .vertical, transition: .instant, showsCoverAlone: false))
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        return (view, window)
    }
}

extension NSView {
    fileprivate var paperView: PaperPDFView? {
        self as? PaperPDFView ?? subviews.lazy.compactMap(\.paperView).first
    }
}
