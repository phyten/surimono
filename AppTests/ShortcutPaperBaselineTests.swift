import AppKit
import PDFKit
import SurimonoCore
import Testing

@testable import Surimono

/// Expectations captured from the pre-customization paper handler, not generated from the shortcut catalog.
@MainActor
struct ShortcutPaperBaselineTests {
    @Test("紙の左右キーは読む向きに従い拡大中もページを送る", arguments: [false, true])
    func horizontalKeys(rightToLeft: Bool) throws {
        let f = try ShortcutSurfaceFixture()
        defer { f.close() }
        let window = f.window
        let paper = f.paper
        let document = try #require(PDFDocument(data: TestFixtures.pdf("keys", pages: 6)))
        paper.show(document, at: 2)
        paper.apply(
            ViewOptions(
                layout: .single, direction: rightToLeft ? .rightToLeft : .leftToRight,
                scrollAxis: .vertical, transition: .instant, showsCoverAlone: false))
        paper.goToPage(index: 2)
        paper.setZoom(2, anchor: nil)
        paper.keyDown(with: key("\u{F703}", code: 124, window: window))
        #expect(paper.currentPageIndex == (rightToLeft ? 1 : 3))
        paper.keyDown(with: key("\u{F702}", code: 123, window: window))
        #expect(paper.currentPageIndex == 2)
    }

    @Test("紙の上下とSpaceは通常のページ送りで前後へ進む")
    func verticalKeys() throws {
        let f = try ShortcutSurfaceFixture()
        defer { f.close() }
        let window = f.window
        let paper = f.paper
        let document = try #require(PDFDocument(data: TestFixtures.pdf("keys", pages: 6)))
        paper.show(document, at: 0)
        paper.apply(
            ViewOptions(
                layout: .single, scrollAxis: .vertical, transition: .instant,
                showsCoverAlone: false))
        paper.keyDown(with: key("\u{F701}", code: 125, window: window))
        #expect(paper.currentPageIndex == 1)
        paper.keyDown(with: key(" ", code: 49, window: window))
        #expect(paper.currentPageIndex == 2)
        paper.keyDown(with: key(" ", code: 49, flags: .shift, window: window))
        #expect(paper.currentPageIndex == 1)
        paper.keyDown(with: key("\u{F700}", code: 126, window: window))
        #expect(paper.currentPageIndex == 0)
    }

    private func key(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags = [], window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: text,
            charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }
}
