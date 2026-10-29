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
        let (view, window) = try makeSinglePagePaper()
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

    @Test("素早く閉じると指を離す前に戻り始め280msで100%になる", .timeLimit(.minutes(1)))
    func fastPinchReturnsToFit() async throws {
        let (view, window) = try makeSinglePagePaper()
        view.shouldReduceMotion = { false }
        let center = NSPoint(x: 100, y: 400)
        view.setZoom(3, anchor: center)
        view.magnify(by: 0, at: center, phase: .began, time: 1)
        view.magnify(by: -0.2, at: center, phase: .changed, time: 1.04)
        #expect(view.isReturningToFit)
        let start = view.zoom
        view.magnify(by: 0.5, at: center, phase: .changed, time: 1.05)
        #expect(view.zoom == start)
        view.advanceZoomReturn(elapsed: 0.14)
        #expect(view.zoom > 1 && view.zoom < start)
        view.advanceZoomReturn(elapsed: 0.28)
        #expect(view.zoom == 1)
        #expect(!view.isReturningToFit)
        view.magnify(by: 0.5, at: center, phase: .changed, time: 1.4)
        #expect(view.zoom == 1)
        view.magnify(by: 0, at: center, phase: .began, time: 2)
        view.magnify(by: 0.5, at: center, phase: .changed, time: 2.1)
        #expect(abs(view.zoom - 1.5) < 0.001)
        withExtendedLifetime(window) {}
    }

    @Test("ゆっくり300%から200%へ縮めて離すと200%を保つ", .timeLimit(.minutes(1)))
    func slowPinchKeepsZoom() async throws {
        let (view, window) = try makeSinglePagePaper()
        let center = NSPoint(x: 200, y: 300)
        view.setZoom(3, anchor: center)
        view.magnify(by: 0, at: center, phase: .began, time: 0)
        for frame in 1...60 {
            view.magnify(by: pow(2.0 / 3, 1.0 / 60) - 1, at: center, phase: .changed, time: Double(frame) / 60)
        }
        view.magnify(by: 0, at: center, phase: .ended, time: 1)
        #expect(abs(view.zoom - 2) < 0.001)
        #expect(!view.isReturningToFit)
        withExtendedLifetime(window) {}
    }

    @Test(
        "100%未満はゴムになり離すかキャンセルすると100%へ戻り保存値は1以上", .timeLimit(.minutes(1)),
        arguments: [NSEvent.Phase.ended, .cancelled])
    func rubberReturnsToFit(phase: NSEvent.Phase) async throws {
        let (view, window) = try makeSinglePagePaper()
        view.shouldReduceMotion = { false }
        var reported: [Double] = []
        view.onZoomChange = { reported.append($0) }
        let fitted = view.scaleFactor
        let center = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        view.magnify(by: 0, at: center, phase: .began, time: 0)
        view.magnify(by: -0.5, at: center, phase: .changed, time: 0.5)
        #expect(view.zoom == 1)
        #expect(view.displayedZoom >= 0.8 && view.displayedZoom < 1)
        #expect(view.scaleFactor < fitted)
        #expect(reported.isEmpty)
        view.magnify(by: 0, at: center, phase: phase, time: 0.6)
        #expect(view.isReturningToFit)
        view.advanceZoomReturn(elapsed: 0.28)
        #expect(view.zoom == 1 && view.displayedZoom == 1)
        #expect(abs(view.scaleFactor - fitted) < 0.01)
        #expect(reported.allSatisfy { $0 >= 1 })
        withExtendedLifetime(window) {}
    }

    @Test("視差効果を減らす場合は素早いピンチから即時に100%へ戻る", .timeLimit(.minutes(1)))
    func reducedMotionReturnsImmediately() async throws {
        let (view, window) = try makeSinglePagePaper()
        view.shouldReduceMotion = { true }
        let center = NSPoint(x: 200, y: 300)
        view.setZoom(3, anchor: center)
        view.magnify(by: 0, at: center, phase: .began, time: 0)
        view.magnify(by: -0.2, at: center, phase: .changed, time: 0.04)
        #expect(view.zoom == 1 && view.displayedZoom == 1)
        #expect(!view.isReturningToFit)
        withExtendedLifetime(window) {}
    }

    @Test(
        "戻る途中の拡大操作と新しいピンチはアニメーションを止める", .timeLimit(.minutes(1)),
        arguments: ["pinch", "in", "out", "fit", "doubleClick"])
    func newZoomInterruptsReturn(operation: String) async throws {
        let (view, window) = try makeSinglePagePaper()
        view.shouldReduceMotion = { false }
        let center = NSPoint(x: 200, y: 300)
        view.setZoom(3, anchor: center)
        view.magnify(by: 0, at: center, phase: .began, time: 0)
        view.magnify(by: -0.2, at: center, phase: .changed, time: 0.04)
        view.advanceZoomReturn(elapsed: 0.1)
        switch operation {
        case "pinch":
            view.magnify(by: 0, at: center, phase: .began, time: 0.2)
            view.magnify(by: 0.1, at: center, phase: .changed, time: 0.25)
        case "in": view.stepZoom(up: true)
        case "out": view.stepZoom(up: false)
        case "fit": view.setZoom(1, anchor: nil)
        default:
            let event = try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: center, modifierFlags: [], timestamp: 0.2,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
            view.mouseDown(with: event)
        }
        let interrupted = view.zoom
        #expect(interrupted >= 1)
        if operation == "fit" || operation == "doubleClick" { #expect(interrupted == 1) }
        #expect(!view.isReturningToFit)
        view.advanceZoomReturn(elapsed: 0.28)
        #expect(view.zoom == interrupted)
        withExtendedLifetime(window) {}
    }

    @Test("ゴムから戻る途中の新しいピンチは同じ見た目の倍率から続く", .timeLimit(.minutes(1)))
    func pinchInterruptsRubberWithoutJumping() async throws {
        let (view, window) = try makeSinglePagePaper()
        view.shouldReduceMotion = { false }
        let center = NSPoint(x: 200, y: 300)
        view.magnify(by: 0, at: center, phase: .began, time: 0)
        view.magnify(by: -0.5, at: center, phase: .changed, time: 0.5)
        view.magnify(by: 0, at: center, phase: .ended, time: 0.6)
        view.advanceZoomReturn(elapsed: 0.1)
        let interrupted = view.displayedZoom
        view.magnify(by: 0, at: center, phase: .began, time: 0.7)
        #expect(!view.isReturningToFit)
        #expect(abs(view.displayedZoom - interrupted) < 0.000001)
        view.magnify(by: 0.1, at: center, phase: .changed, time: 0.8)
        #expect(view.displayedZoom > interrupted)
        withExtendedLifetime(window) {}
    }

    @Test("ピンチの拡大は600%で止まり指を閉じればすぐ縮む", .timeLimit(.minutes(1)))
    func pinchStopsAtMaximum() async throws {
        let (view, window) = try makeSinglePagePaper()
        let center = NSPoint(x: 200, y: 300)
        view.magnify(by: 0, at: center, phase: .began, time: 0)
        view.magnify(by: 10, at: center, phase: .changed, time: 1)
        #expect(view.zoom == 6)
        view.magnify(by: -0.1, at: center, phase: .changed, time: 2)
        #expect(abs(view.zoom - 5.4) < 0.001)
        withExtendedLifetime(window) {}
    }

    @Test(
        "戻りの途中で紙の外縁を露出せず通常の100%と同じ位置に着く", .timeLimit(.minutes(1)),
        arguments: [ViewOptions.Transition.instant, .scroll])
    func returnLandsAtFitPosition(transition: ViewOptions.Transition) async throws {
        let (view, window) = try makeSinglePagePaper()
        let (reference, referenceWindow) = try makeSinglePagePaper()
        let options = ViewOptions(
            layout: .single, scrollAxis: .vertical, transition: transition, showsCoverAlone: false)
        let center = NSPoint(x: 100, y: 400)
        for paper in [view, reference] {
            paper.apply(options)
            paper.goToPage(index: 3)
            paper.setZoom(3, anchor: center)
        }
        view.shouldReduceMotion = { false }
        let page = try #require(view.document?.page(at: 3))
        let referencePage = try #require(reference.document?.page(at: 3))
        reference.setZoom(2.4, anchor: center)
        reference.setZoom(1, anchor: nil)
        let fitted = reference.convert(referencePage.bounds(for: .cropBox), from: referencePage)
        view.magnify(by: 0, at: center, phase: .began, time: 0)
        view.magnify(by: -0.2, at: center, phase: .changed, time: 0.04)
        for frame in 0...28 {
            view.advanceZoomReturn(elapsed: Double(frame) / 100)
            var rect = view.convert(page.bounds(for: .cropBox), from: page)
            if options.isContinuous, let document = view.document {
                for index in 0..<document.pageCount {
                    let other = try #require(document.page(at: index))
                    rect = rect.union(view.convert(other.bounds(for: .cropBox), from: other))
                }
            }
            #expect(rect.minX <= 1 && rect.minY <= 1, "frame \(frame): \(rect)")
            #expect(rect.maxX >= view.bounds.maxX - 1 && rect.maxY >= view.bounds.maxY - 1, "frame \(frame): \(rect)")
        }
        let landed = view.convert(page.bounds(for: .cropBox), from: page)
        #expect(abs(landed.minX - fitted.minX) < 1, "landed \(landed), fitted \(fitted)")
        #expect(abs(landed.minY - fitted.minY) < 1, "landed \(landed), fitted \(fitted)")
        withExtendedLifetime((window, referenceWindow)) {}
    }

    @Test(
        "ゴムの途中で文書を差し替えると表示とモデルが100%にそろい残りのピンチを無視する",
        .timeLimit(.minutes(1)), arguments: [false, true])
    func replacementClearsRubber(isReturning: Bool) async throws {
        let (view, window) = try makeSinglePagePaper()
        view.shouldReduceMotion = { false }
        let fitted = view.scaleFactor
        var modelZoom = 1.0
        view.onZoomChange = { modelZoom = $0 }
        let center = NSPoint(x: 200, y: 300)
        view.magnify(by: 0, at: center, phase: .began, time: 0)
        view.magnify(by: -0.5, at: center, phase: .changed, time: 0.5)
        if isReturning {
            view.magnify(by: 0, at: center, phase: .ended, time: 0.6)
            view.advanceZoomReturn(elapsed: 0.1)
            #expect(view.isReturningToFit)
        }
        #expect(view.displayedZoom < 1)
        let replacement = try #require(PDFDocument(data: TestFixtures.pdf("replacement", pages: 3)))
        view.show(replacement, at: 1)
        #expect(view.document === replacement)
        #expect(view.zoom == 1 && view.displayedZoom == 1 && modelZoom == 1)
        #expect(abs(view.scaleFactor - fitted) < 0.001)
        #expect(!view.isReturningToFit)
        view.advanceZoomReturn(elapsed: 0.28)
        view.magnify(by: 0.5, at: center, phase: .changed, time: 0.7)
        view.magnify(by: 0, at: center, phase: .ended, time: 0.8)
        #expect(view.zoom == 1 && view.displayedZoom == 1)
        view.magnify(by: 0, at: center, phase: .began, time: 1)
        view.magnify(by: 0.5, at: center, phase: .changed, time: 1.1)
        #expect(abs(view.zoom - 1.5) < 0.001)
        withExtendedLifetime(window) {}
    }

    @Test("文書の差し替えでも利用者が選んだ100%以上の倍率は保つ", .timeLimit(.minutes(1)))
    func replacementKeepsChosenZoom() async throws {
        let (view, window) = try makeSinglePagePaper()
        view.setZoom(2, anchor: nil)
        let replacement = try #require(PDFDocument(data: TestFixtures.pdf("replacement", pages: 3)))
        view.show(replacement, at: 1)
        #expect(view.zoom == 2 && view.displayedZoom == 2)
        withExtendedLifetime(window) {}
    }

    @Test(
        "連続表示の戻り途中でページを移動すると100%になり後続フレームでも移動先を保つ",
        .timeLimit(.minutes(1)), arguments: [false, true])
    func pageNavigationFinishesReturn(turn: Bool) async throws {
        let (view, window) = try makeSinglePagePaper()
        view.apply(ViewOptions(layout: .single, scrollAxis: .vertical, transition: .scroll, showsCoverAlone: false))
        view.shouldReduceMotion = { false }
        let center = NSPoint(x: 200, y: 300)
        view.setZoom(3, anchor: center)
        view.magnify(by: 0, at: center, phase: .began, time: 0)
        view.magnify(by: -0.2, at: center, phase: .changed, time: 0.04)
        view.advanceZoomReturn(elapsed: 0.1)
        #expect(view.isReturningToFit)
        let targetPage = turn ? view.currentPageIndex + 1 : 4
        if turn { view.turnPage(forward: true) } else { view.goToPage(index: targetPage) }
        #expect(view.currentPageIndex == targetPage)
        let destination = try #require(view.documentView?.enclosingScrollView?.contentView.bounds.origin)
        #expect(!view.isReturningToFit)
        #expect(view.zoom == 1 && view.displayedZoom == 1)
        for elapsed in [0.14, 0.28] {
            view.advanceZoomReturn(elapsed: elapsed)
            #expect(view.currentPageIndex == targetPage)
            #expect(view.documentView?.enclosingScrollView?.contentView.bounds.origin == destination)
        }
        withExtendedLifetime(window) {}
    }

    @Test("SwiftUIへ倍率を往復しても戻りが途中で止まらずモデルと表示が100%にそろう", .timeLimit(.minutes(1)))
    func returnSurvivesSwiftUIFeedback() async throws {
        let document = try #require(PDFDocument(data: TestFixtures.pdf("feedback", pages: 6)))
        let model = ZoomFeedbackModel()
        let host = NSHostingView(rootView: ZoomFeedbackPaper(document: document, model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 594), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let view = try #require(host.paperView)
        view.shouldReduceMotion = { false }
        let center = NSPoint(x: 200, y: 300)
        view.setZoom(3, anchor: center)
        host.layout()
        #expect(model.renderedZoom == 3)
        view.magnify(by: 0, at: center, phase: .began, time: 0)
        view.magnify(by: -0.2, at: center, phase: .changed, time: 0.04)
        for elapsed in [0.04, 0.1, 0.18, 0.24] {
            view.advanceZoomReturn(elapsed: elapsed)
            let reported = model.zoom
            // Force the hosting view to process its pending graph update, without waiting on wall-clock frames.
            host.layout()
            #expect(host.paperView === view)
            #expect(model.renderedZoom == reported)
            #expect(view.zoom == reported)
            #expect(view.isReturningToFit)
        }
        view.advanceZoomReturn(elapsed: 0.28)
        host.layout()
        #expect(model.renderedZoom == 1)
        #expect(model.zoom == 1 && view.zoom == 1 && view.displayedZoom == 1)
        #expect(!view.isReturningToFit)
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

    @Test("文字を選択のときは紙の端をクリックしてもページを送らず、やめると端のクリックで送る", .timeLimit(.minutes(1)))
    func clickWhileSelectingTextKeepsThePage() async throws {
        let (view, window) = try makeSinglePagePaper()
        let edge = NSPoint(x: 410, y: 300)
        view.selectsText = true
        try clickThroughPDFKit(view, in: window, at: edge)
        #expect(view.currentPageIndex == 0)
        view.selectsText = false
        try click(view, in: window, at: edge)
        #expect(view.currentPageIndex == 1)
        withExtendedLifetime(window) {}
    }

    @Test(
        "⌥ を押している間は、文字の選択と窓の移動が入れ替わる",
        arguments: [(false, false, false), (false, true, true), (true, false, true), (true, true, false)])
    func optionSwapsTheDrag(selecting: Bool, option: Bool, selects: Bool) throws {
        let view = PaperPDFView(frame: NSRect(x: 0, y: 0, width: 420, height: 594))
        view.selectsText = selecting
        let event = try mouseEvent(.leftMouseDown, at: NSPoint(x: 100, y: 100), option: option, windowNumber: 0)
        #expect(view.selectsText(for: event) == selects)
    }

    @Test("⌥ で一時的に文字を選ぶときは、⌥ を外して PDFKit に渡し、矩形の選択にしない")
    func optionDragSelectsTextNotARectangle() throws {
        let pressed = try mouseEvent(.leftMouseDown, at: NSPoint(x: 100, y: 100), option: true, windowNumber: 0)
        let passed = PaperPDFView.withoutOption(pressed)
        #expect(!passed.modifierFlags.contains(.option))
        #expect(passed.type == .leftMouseDown)
        #expect(passed.locationInWindow == pressed.locationInWindow)
        #expect(passed.clickCount == pressed.clickCount)
    }

    @Test("すべて選択は文字を選択のときだけ効き、文字を選択をやめると選択を消す", .timeLimit(.minutes(1)))
    func selectAllFollowsTheMode() async throws {
        let (view, window) = try makeSinglePagePaper(document: Self.textDocument())
        view.selectAll(nil)
        #expect(view.currentSelection?.string?.isEmpty ?? true)
        view.selectsText = true
        view.selectAll(nil)
        let selected = view.currentSelection?.string ?? ""
        #expect(selected.contains("Surimono"))
        view.selectsText = false
        #expect(view.currentSelection?.string?.isEmpty ?? true)
        withExtendedLifetime(window) {}
    }

    /// PDFKit's text selection tracks the mouse in a loop of its own until the button goes up, so the release has to
    /// wait in the event queue before the press is sent.
    private func clickThroughPDFKit(_ view: PaperPDFView, in window: NSWindow, at point: NSPoint) throws {
        window.postEvent(try mouseEvent(.leftMouseUp, at: point, windowNumber: window.windowNumber), atStart: false)
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: point, windowNumber: window.windowNumber))
    }

    private func click(_ view: PaperPDFView, in window: NSWindow, at point: NSPoint) throws {
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: point, windowNumber: window.windowNumber))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: point, windowNumber: window.windowNumber))
    }

    private func mouseEvent(
        _ type: NSEvent.EventType, at point: NSPoint, option: Bool = false, windowNumber: Int
    ) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: option ? [.option] : [], timestamp: 0,
                windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// Six pages that each carry a line of text, which PDFKit can select.
    private static func textDocument() throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for page in 1...6 {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSAttributedString(
                string: "Surimono selection page \(page)", attributes: [.font: NSFont.systemFont(ofSize: 24)]
            ).draw(at: NSPoint(x: 72, y: 720))
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return try #require(PDFDocument(data: data as Data))
    }

    /// A paper view of a six-page PDF filling a window. It is used without SwiftUI, whose fixed zoom input would
    /// otherwise set the zoom back on its next update.
    private func makeSinglePagePaper(document: PDFDocument? = nil) throws -> (PaperPDFView, NSWindow) {
        let document = try document ?? #require(PDFDocument(data: TestFixtures.pdf("pinch", pages: 6)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 594), styleMask: [.titled], backing: .buffered,
            defer: true)
        let view = PaperPDFView(frame: NSRect(x: 0, y: 0, width: 420, height: 594))
        window.contentView = view
        view.show(document, at: 0)
        view.apply(ViewOptions(layout: .single, scrollAxis: .vertical, transition: .instant, showsCoverAlone: false))
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }
}

extension NSView {
    fileprivate var paperView: PaperPDFView? {
        self as? PaperPDFView ?? subviews.lazy.compactMap(\.paperView).first
    }
}

@MainActor
@Observable
private final class ZoomFeedbackModel {
    var zoom = 1.0
    @ObservationIgnored var renderedZoom = 1.0
    let controller = PaperController()
}

@MainActor
private struct ZoomFeedbackPaper: View {
    let document: PDFDocument
    let model: ZoomFeedbackModel

    var body: some View {
        PaperView(
            document: document, initialPageIndex: 0,
            options: ViewOptions(layout: .single, scrollAxis: .vertical, transition: .instant, showsCoverAlone: false),
            zoom: model.zoom, controller: model.controller,
            onZoomChange: { model.zoom = $0 }, onPageChange: { _ in }, onTurn: {}, onKey: { _ in false }
        )
        .onChange(of: model.zoom, initial: true) { _, value in model.renderedZoom = value }
    }
}
