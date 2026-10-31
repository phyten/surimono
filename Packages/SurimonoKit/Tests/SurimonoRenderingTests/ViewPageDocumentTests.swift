import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@MainActor
struct ViewPageDocumentTests {
    @Test("表示用の切り取りは元のページと選択できる本文を変えない", arguments: [0.0, 42.0])
    func cropping(margin: Double) throws {
        let source = try RenderingFixtures.pdf(count: 3, size: CGSize(width: 300, height: 500))
        let options = ViewOptions(layout: .single, scrollAxis: .vertical, transition: .scroll, showsCoverAlone: false)
        let plan = ViewPageLayout(pageCount: 3, options: options, hasLogicalMargins: true, showsNumbers: true)
        let copy = try #require(ViewPageDocument.make(source, plan: plan, margin: margin))
        #expect(copy.page(at: 0)?.bounds(for: .cropBox) == CGRect(x: 0, y: margin, width: 300, height: 500 - margin))
        #expect(
            copy.page(at: 1)?.bounds(for: .cropBox) == CGRect(x: 0, y: margin, width: 300, height: 500 - 2 * margin))
        #expect(copy.page(at: 2)?.bounds(for: .cropBox) == CGRect(x: 0, y: 0, width: 300, height: 500 - margin))
        for index in 0..<3 {
            #expect(source.page(at: index)?.bounds(for: .cropBox) == CGRect(x: 0, y: 0, width: 300, height: 500))
            #expect(copy.page(at: index)?.string == source.page(at: index)?.string)
        }
    }

    @Test("結合する辺だけを切り取り縦横と左右の読む順に応じて外端を残す", arguments: ViewOptions.ScrollAxis.allCases, ViewOptions.Direction.allCases)
    func cropAxes(axis: ViewOptions.ScrollAxis, direction: ViewOptions.Direction) throws {
        let source = try RenderingFixtures.pdf(count: 3, size: CGSize(width: 300, height: 500))
        let options = ViewOptions(
            layout: .single, direction: direction, scrollAxis: axis, transition: .scroll, showsCoverAlone: false)
        let plan = ViewPageLayout(pageCount: 3, options: options, hasLogicalMargins: true, showsNumbers: false)
        let copy = try #require(ViewPageDocument.make(source, plan: plan, margin: 42))
        let expected: [CGRect]
        if axis == .vertical {
            expected = [
                CGRect(x: 0, y: 42, width: 300, height: 458),
                CGRect(x: 0, y: 42, width: 300, height: 416),
                CGRect(x: 0, y: 0, width: 300, height: 458),
            ]
        } else if direction == .leftToRight {
            expected = [
                CGRect(x: 0, y: 0, width: 258, height: 500),
                CGRect(x: 42, y: 0, width: 216, height: 500),
                CGRect(x: 42, y: 0, width: 258, height: 500),
            ]
        } else {
            expected = [
                CGRect(x: 42, y: 0, width: 258, height: 500),
                CGRect(x: 42, y: 0, width: 216, height: 500),
                CGRect(x: 0, y: 0, width: 258, height: 500),
            ]
        }
        for index in 0..<3 {
            #expect(copy.page(at: index)?.bounds(for: .cropBox) == expected[index])
            #expect(source.page(at: index)?.bounds(for: .cropBox) == CGRect(x: 0, y: 0, width: 300, height: 500))
        }
    }

    @Test("見開きの空白を挿入しても内部リンクと注釈はコピー内の論理ページを指す")
    func links() throws {
        let source = try RenderingFixtures.pdf(count: 2, size: CGSize(width: 300, height: 500))
        let first = try #require(source.page(at: 0))
        let second = try #require(source.page(at: 1))
        let link = PDFAnnotation(
            bounds: CGRect(x: 20, y: 200, width: 100, height: 20), forType: .link, withProperties: nil)
        link.action = PDFActionGoTo(destination: PDFDestination(page: second, at: CGPoint(x: 50, y: 400)))
        first.addAnnotation(link)
        let options = ViewOptions(layout: .spread, scrollAxis: .horizontal, transition: .slide, showsCoverAlone: true)
        let plan = ViewPageLayout(pageCount: 2, options: options, hasLogicalMargins: false, showsNumbers: true)
        let copy = try #require(ViewPageDocument.make(source, plan: plan, margin: 0))
        #expect(copy.pageCount == 4)
        #expect(copy.page(at: 0)?.string?.isEmpty != false)
        #expect(copy.page(at: 3)?.string?.isEmpty != false)
        #expect(copy.page(at: 0)?.bounds(for: .cropBox) == first.bounds(for: .cropBox))
        let moved = try #require(copy.page(at: 1)?.annotations.first?.action as? PDFActionGoTo)
        #expect(moved.destination.page === copy.page(at: 2))
        #expect(moved.destination.point == CGPoint(x: 50, y: 400))
        #expect((link.action as? PDFActionGoTo)?.destination.page === second)
        #expect(link.page === first)
        #expect(first.annotations.count == 1)
        #expect(source.pageCount == 2)
        #expect(copy.page(at: 1)?.string?.contains("PAGE-1") == true)
        #expect(first.string?.trimmingCharacters(in: .whitespacesAndNewlines) == "PAGE-1")
    }

    @Test("表示番号は通常のPDFに描き込まれ本文の座標と寸法を変えない", arguments: [0.0, 42.0])
    func viewNumbers(margin: Double) throws {
        let source = try RenderingFixtures.pdf(count: 1, size: CGSize(width: 300, height: 500))
        let options = ViewOptions(layout: .single, scrollAxis: .vertical, transition: .instant, showsCoverAlone: false)
        let plan = ViewPageLayout(pageCount: 1, options: options, hasLogicalMargins: true, showsNumbers: true)
        let copy = try #require(ViewPageDocument.make(source, plan: plan, margin: margin))
        let page = try #require(copy.page(at: 0))
        let original = try #require(source.page(at: 0))
        #expect(type(of: page) == PDFPage.self)
        #expect(page.bounds(for: .mediaBox) == original.bounds(for: .mediaBox))
        let before = try #require(source.findString("PAGE-1", withOptions: []).first)
        let after = try #require(copy.findString("PAGE-1", withOptions: []).first)
        #expect(before.bounds(for: original) == after.bounds(for: page))
        let footer = try #require(page.selection(for: CGRect(x: 100, y: 0, width: 100, height: 42)))
        #expect(footer.string?.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
        #expect(footer.bounds(for: page).minY >= 0)
        #expect(original.selection(for: CGRect(x: 100, y: 0, width: 100, height: 42))?.string?.isEmpty != false)
    }

    @Test("回転と原点のあるページでも表示番号は見た目の下余白に入る", arguments: [0, 90, 180, 270])
    func rotatedNumbers(rotation: Int) throws {
        let source = try RenderingFixtures.pdf(count: 1, size: CGSize(width: 300, height: 500))
        let original = try #require(source.page(at: 0))
        let crop = CGRect(x: 20, y: 30, width: 260, height: 440)
        original.setBounds(crop, for: .cropBox)
        original.rotation = rotation
        let options = ViewOptions(
            layout: .single, scrollAxis: .horizontal, transition: .instant, showsCoverAlone: false)
        let plan = ViewPageLayout(pageCount: 1, options: options, hasLogicalMargins: true, showsNumbers: true)
        let copy = try #require(ViewPageDocument.make(source, plan: plan, margin: 42))
        let page = try #require(copy.page(at: 0))
        #expect(page.bounds(for: .cropBox) == crop)
        #expect(page.rotation == rotation)
        let footer: CGRect
        switch rotation {
        case 90: footer = CGRect(x: 238, y: 200, width: 42, height: 100)
        case 180: footer = CGRect(x: 100, y: 428, width: 100, height: 42)
        case 270: footer = CGRect(x: 20, y: 200, width: 42, height: 100)
        default: footer = CGRect(x: 100, y: 30, width: 100, height: 42)
        }
        #expect(page.selection(for: footer)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
    }

    @Test("番号入り表示PDFはワーカースレッドで通常のPDFPageとして描画できる")
    func backgroundDrawing() async throws {
        let source = try RenderingFixtures.pdf(count: 1, size: CGSize(width: 300, height: 500))
        let options = ViewOptions(layout: .single, scrollAxis: .vertical, transition: .instant, showsCoverAlone: false)
        let plan = ViewPageLayout(pageCount: 1, options: options, hasLogicalMargins: true, showsNumbers: true)
        let copy = try #require(ViewPageDocument.make(source, plan: plan, margin: 42))
        let data = try #require(copy.dataRepresentation())
        // Only immutable PDF bytes cross the actor boundary; the worker owns its document and drawing context.
        let drawn = await Task.detached { Self.drawOnWorker(data) }.value
        #expect(drawn)
    }

    private nonisolated static func drawOnWorker(_ data: Data) -> Bool {
        guard !Thread.isMainThread else { return false }
        guard let document = PDFDocument(data: data), let page = document.page(at: 0),
            let context = CGContext(
                data: nil, width: 300, height: 500, bitsPerComponent: 8, bytesPerRow: 1200,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 500))
        withExtendedLifetime(document) { page.draw(with: .cropBox, to: context) }
        guard let data = context.data else { return false }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        // The footer was empty in the source. Rendering the baked number must leave ink there.
        let hasFooterInk = (0..<42).contains { y in
            (100..<200).contains { x in pixels[((499 - y) * 300 + x) * 4] < 128 }
        }
        return hasFooterInk && page.string?.contains("PAGE-1") == true
    }

    @Test("印刷の番号は余白ゼロでも紙の内側にあり本文の位置と用紙寸法を変えない", arguments: [0.0, 15.0])
    func printedNumbers(margin: Double) async throws {
        let source = try RenderingFixtures.pdf(count: 1, size: PaperSize.a4.size)
        let plain = try await PDFComposer().compose(
            source, layout: .a4Single, options: PrintOptions(marginsInMillimeters: margin))
        let numbered = try await PDFComposer().compose(
            source, layout: .a4Single, options: PrintOptions(marginsInMillimeters: margin, showsPageNumbers: true))
        let before = try #require(plain.page(at: 0))
        let after = try #require(numbered.page(at: 0))
        #expect(after.bounds(for: .mediaBox) == before.bounds(for: .mediaBox))
        let beforeText = try #require(plain.findString("PAGE-1", withOptions: []).first)
        let afterText = try #require(numbered.findString("PAGE-1", withOptions: []).first)
        #expect(afterText.bounds(for: after) == beforeText.bounds(for: before))
        let footer = try #require(after.selection(for: CGRect(x: 250, y: 0, width: 100, height: 42)))
        #expect(footer.string?.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
        #expect(footer.bounds(for: after).minY >= 0)
        #expect(footer.bounds(for: after).maxY < (margin == 0 ? 15 : 42))
    }
}
