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
}

extension NSView {
    fileprivate var paperView: PaperPDFView? {
        self as? PaperPDFView ?? subviews.lazy.compactMap(\.paperView).first
    }
}
