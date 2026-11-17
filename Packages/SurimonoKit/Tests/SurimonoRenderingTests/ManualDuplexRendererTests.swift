import AppKit
import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct ManualDuplexRendererTests {
    @Test("裏のPDFは指定した用紙順と寸法で作り元のPDFを変えない")
    func orderedPages() async throws {
        let source = try RenderingFixtures.pdf(count: 6, size: CGSize(width: 300, height: 200))
        let before = try #require(source.dataRepresentation())
        let plan = try ManualDuplexPlan.make(
            imposition: Imposition.plan(pageCount: 6, layout: .a4Duplex), copies: 2,
            frontPageOrder: .firstSheetFirst, correction: .init())
        let backs = try await ManualDuplexRenderer().document(from: source, sides: plan.backs)
        #expect(backs.pageCount == 6)
        for (index, expected) in [5, 3, 1, 5, 3, 1].enumerated() {
            let page = try #require(backs.page(at: index))
            #expect(page.bounds(for: .mediaBox).size == CGSize(width: 300, height: 200))
            #expect(page.string?.contains("PAGE-\(expected + 1)") == true)
            #expect(try pixels(page) == pixels(#require(source.page(at: expected))))
        }
        #expect(try stableBytes(#require(source.dataRepresentation())) == stableBytes(before))
    }

    @Test("非対称の目印で裏だけの180度回転を確かめる")
    func rotation() async throws {
        let source = try RenderingFixtures.pdf(count: 2, size: CGSize(width: 300, height: 200))
        let before = try #require(source.dataRepresentation())
        let plan = try ManualDuplexPlan.make(
            imposition: Imposition.plan(pageCount: 2, layout: .a4Duplex), copies: 1,
            frontPageOrder: .lastSheetFirst, correction: .init(rotatesBackSides: true))
        let renderer = ManualDuplexRenderer()
        let fronts = try await renderer.document(from: source, sides: plan.fronts)
        let backs = try await renderer.document(from: source, sides: plan.backs)
        #expect(try pixels(#require(fronts.page(at: 0))) == pixels(#require(source.page(at: 0))))
        let actual = try pixels(#require(backs.page(at: 0)))
        let expected = try pixels(#require(source.page(at: 1)), rotated: true)
        let differences = zip(actual, expected).filter { abs(Int($0) - Int($1)) > 16 }.count
        // Serializing the center transform rounds fractional coordinates; only edge antialiasing may differ.
        #expect(differences < actual.count / 1000)
        #expect(try pixels(#require(backs.page(at: 0))) != pixels(#require(source.page(at: 1))))
        #expect(try stableBytes(#require(source.dataRepresentation())) == stableBytes(before))
    }

    @Test("元のPDFを変えていないかの比較は、書き出すたびに変わる日時とIDに左右されない")
    func comparisonIgnoresSerializationDates() async throws {
        let source = try RenderingFixtures.pdf(count: 1, size: CGSize(width: 300, height: 200))
        let before = try #require(source.dataRepresentation())
        // The dates carry whole seconds: wait until the next one so the two serializations are sure to differ.
        try await Task.sleep(for: .milliseconds(1100))
        let after = try #require(source.dataRepresentation())
        #expect(after != before)
        #expect(stableBytes(after) == stableBytes(before))
    }

    @Test("5ページの両面印刷は最後の白紙の裏もPDFに残す")
    func blankBack() async throws {
        let logical = try RenderingFixtures.pdf(count: 5)
        let imposed = try await PDFComposer().compose(logical, layout: .a4Duplex, options: .init())
        let plan = try ManualDuplexPlan.make(
            imposition: Imposition.plan(pageCount: 5, layout: .a4Duplex), copies: 1,
            frontPageOrder: .firstSheetFirst, correction: .init())
        let backs = try await ManualDuplexRenderer().document(from: imposed, sides: plan.backs)
        #expect(backs.pageCount == 3)
        #expect(try pixels(#require(backs.page(at: 0))).allSatisfy { $0 == 255 })
    }

    @Test("冊子の搬送用レイアウトは同じ横長の紙を持つ通常片面になる")
    func transport() throws {
        for layout in [PrintLayout.a4Duplex, .a4Duplex.oriented(true), .a3BookletA4, .b5BookletB6] {
            let transport = try ManualDuplexRenderer().transportLayout(for: layout)
            #expect(transport.kind == .normal)
            #expect(transport.sentDuplex == .none)
            #expect(transport.sheetSize == layout.sheetSize)
        }
    }

    @Test("自動両面の補正を変えても手動両面のPDFは変わらない", arguments: [false, true])
    func independentCalibration(landscape: Bool) async throws {
        let source = DocumentSource(
            data: try #require(RenderingFixtures.pdf(count: 4).dataRepresentation()), format: .pdf)
        let renderer = DocumentRenderer()
        var settings = RenderSettings(
            layout: .a4Duplex.oriented(landscape), theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        settings.paperOrientation = landscape ? .landscape : .portrait
        let first = try await renderer.prepare(source, settings: settings)
        settings.options.rotatesBackSides = true
        let calibrated = try await renderer.prepare(source, settings: settings)
        let plain = try await renderer.composeSheet(for: first, rotatesBackSides: false)
        let neutral = try await renderer.composeSheet(for: calibrated, rotatesBackSides: false)
        for reverse in [false, true] {
            for rotate in [false, true] {
                let plan = try ManualDuplexPlan.make(
                    imposition: first.plan, copies: 1, frontPageOrder: .lastSheetFirst,
                    correction: .init(reversesBackOrder: reverse, rotatesBackSides: rotate))
                let a = try await ManualDuplexRenderer().document(from: plain.sheetDocument, sides: plan.backs)
                let b = try await ManualDuplexRenderer().document(from: neutral.sheetDocument, sides: plan.backs)
                for index in 0..<a.pageCount {
                    #expect(try pixels(#require(a.page(at: index))) == pixels(#require(b.page(at: index))))
                }
            }
        }
    }

    private func stableBytes(_ data: Data) -> Data {
        var bytes = data
        // PDFKit writes a fresh trailer ID and the current second as the creation and modification dates on every
        // serialization, even with no edits; two serializations a second apart would otherwise differ.
        for (opening, closing) in [("/ID", "]"), ("/CreationDate", ")"), ("/ModDate", ")")] {
            if let start = bytes.range(of: Data(opening.utf8)),
                let end = bytes.range(of: Data(closing.utf8), in: start.upperBound..<bytes.endIndex)
            {
                bytes.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        return bytes
    }

    private func pixels(_ page: PDFPage, rotated: Bool = false) throws -> [UInt8] {
        let size = page.bounds(for: .mediaBox).size
        let width = Int(ceil(size.width))
        let height = Int(ceil(size.height))
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if rotated {
            context.translateBy(x: size.width, y: size.height)
            context.rotate(by: .pi)
        }
        context.drawPDFPage(try #require(page.pageRef))
        return Array(
            UnsafeBufferPointer(
                start: try #require(context.data).assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    }
}
