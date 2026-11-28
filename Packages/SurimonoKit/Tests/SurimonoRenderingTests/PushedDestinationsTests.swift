import CoreText
import Foundation
import PDFKit
import Testing

@testable import SurimonoRendering

/// Pages written as WebKit writes them: Quartz's named destinations, which it saves as explicit XYZ arrays.
struct PushedDestinationsTests {
    private let paper = CGRect(x: 0, y: 0, width: 400, height: 300)

    /// Two pages. The first has a link at the top and text down to `lowestText`; the link's destination is at
    /// `destinationY` on the first page. The second page begins with `nextText`.
    private func pages(destinationY: CGFloat, nextText: String) throws -> Data {
        let data = NSMutableData()
        var box = paper
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        func draw(_ text: String, at point: CGPoint) {
            let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font]))
            context.textPosition = point
            CTLineDraw(line, context)
        }
        context.beginPDFPage(nil)
        draw("LINK-TEXT", at: CGPoint(x: 20, y: 270))
        context.setDestination("target" as CFString, for: CGRect(x: 18, y: 266, width: 80, height: 16))
        draw("The question comes first.", at: CGPoint(x: 20, y: 200))
        context.addDestination("target" as CFString, at: CGPoint(x: 20, y: destinationY))
        context.endPDFPage()
        context.beginPDFPage(nil)
        draw(nextText, at: CGPoint(x: 20, y: 270))
        draw("More text.", at: CGPoint(x: 20, y: 240))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private func destinationPage(in bytes: Data) throws -> Int? {
        let document = try #require(PDFDocument(data: bytes))
        let link = try #require(document.page(at: 0)?.annotations.first { $0.type == "Link" })
        let destination = (link.action as? PDFActionGoTo)?.destination ?? link.destination
        return destination?.page.map { document.index(for: $0) }
    }

    @Test("同じページで下に何も描かれていない宛先は、次のページが別の文から始まれば動かない")
    func blankTargetOnItsPageStays() throws {
        // An empty answer box below the question; the explanation on the next page is not the box.
        let bytes = try pages(destinationY: 150, nextText: "Explanation")
        for text in ["", "Answer"] {
            let targets = PushedDestinations.Targets(links: [["LINK-TEXT", "target"]], texts: ["target": text])
            #expect(try destinationPage(in: PushedDestinations.moving(bytes, targets: targets)) == 0, "\(text)")
        }
    }

    @Test("下に何も描かれていない宛先は、その要素の文で次のページが始まるときだけ次のページの上端へ移る")
    func pushedTargetMoves() throws {
        let bytes = try pages(destinationY: 150, nextText: "Chapter Two")
        let targets = PushedDestinations.Targets(links: [["LINK-TEXT", "target"]], texts: ["target": "Chapter Two"])
        let moved = try PushedDestinations.moving(bytes, targets: targets)
        #expect(try destinationPage(in: moved) == 1)
        let document = try #require(PDFDocument(data: moved))
        let link = try #require(document.page(at: 0)?.annotations.first { $0.type == "Link" })
        let destination = try #require((link.action as? PDFActionGoTo)?.destination ?? link.destination)
        #expect(destination.point == CGPoint(x: 20, y: paper.maxY))
    }

    @Test("宛先の下に文字があれば、次のページが同じ文から始まっても動かない")
    func drawnTargetStays() throws {
        // The destination is above the question's line, so the target is drawn on its own page.
        let bytes = try pages(destinationY: 215, nextText: "Chapter Two")
        let targets = PushedDestinations.Targets(links: [["LINK-TEXT", "target"]], texts: ["target": "Chapter Two"])
        #expect(try destinationPage(in: PushedDestinations.moving(bytes, targets: targets)) == 0)
    }
}
