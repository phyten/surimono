import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@MainActor
struct PDFComposerTests {
    @Test("A4の2ページ配置は横用紙2枚に3ページを収め最後の右を空ける")
    func a4TwoUp() async throws {
        let output = try await PDFComposer().compose(
            RenderingFixtures.pdf(count: 3), layout: .a4TwoUp, options: PrintOptions())
        #expect(output.pageCount == 2)
        let first = try #require(output.page(at: 0))
        let last = try #require(output.page(at: 1))
        #expect(abs(first.bounds(for: .mediaBox).width - 841.890) < 0.01)
        #expect(abs(first.bounds(for: .mediaBox).height - 595.276) < 0.01)
        #expect(
            first.selection(for: CGRect(x: 0, y: 0, width: 420.945, height: 595.276))?.string?.contains("PAGE-1")
                == true)
        #expect(
            first.selection(for: CGRect(x: 420.945, y: 0, width: 420.945, height: 595.276))?.string?.contains("PAGE-2")
                == true)
        #expect(
            last.selection(for: CGRect(x: 0, y: 0, width: 420.945, height: 595.276))?.string?.contains("PAGE-3") == true
        )
        let blank = last.selection(for: CGRect(x: 420.945, y: 0, width: 420.945, height: 595.276))?.string ?? ""
        #expect(blank.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("4ページ配置は10ページを縦用紙3枚の左上から並べる", arguments: [PrintLayout.a4FourUp, .b5FourUp, .letterFourUp])
    func fourUp(layout: PrintLayout) async throws {
        let output = try await PDFComposer().compose(
            RenderingFixtures.pdf(count: 10), layout: layout, options: PrintOptions())
        #expect(output.pageCount == 3)
        for index in 0..<3 {
            let page = try #require(output.page(at: index))
            let box = page.bounds(for: .mediaBox)
            #expect(abs(box.width - layout.sheet.size.width) < 0.01)
            #expect(abs(box.height - layout.sheet.size.height) < 0.01)
            #expect(page.rotation == 0)
            for slot in 0..<4 {
                let rect = CGRect(
                    x: CGFloat(slot % 2) * box.width / 2, y: slot < 2 ? box.height / 2 : 0, width: box.width / 2,
                    height: box.height / 2)
                let text = page.selection(for: rect)?.string ?? ""
                let number = index * 4 + slot + 1
                if number <= 10 {
                    #expect(text.contains("PAGE-\(number)"))
                } else {
                    #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    @Test("右とじLetter冊子は裏面補正後も指定した左右のページを持つ", arguments: [false, true])
    func rightLetterBooklet(rotates: Bool) async throws {
        let output = try await PDFComposer().compose(
            RenderingFixtures.pdf(count: 5), layout: PrintLayout.letterBookletHalfLetter.bound(.right),
            options: PrintOptions(rotatesBackSides: rotates))
        #expect(output.pageCount == 4)
        let expected: [[String?]] = [["PAGE-1", nil], [nil, "PAGE-2"], ["PAGE-3", nil], ["PAGE-5", "PAGE-4"]]
        for index in 0..<4 {
            let page = try #require(output.page(at: index))
            #expect(abs(page.bounds(for: .mediaBox).width - 792) < 0.01)
            #expect(abs(page.bounds(for: .mediaBox).height - 612) < 0.01)
            for slot in 0..<2 {
                let target = rotates && index % 2 == 1 ? 1 - slot : slot
                let text = page.selection(for: CGRect(x: target * 396, y: 0, width: 396, height: 612))?.string ?? ""
                if let marker = expected[index][slot] {
                    #expect(text.contains(marker))
                } else {
                    #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    @Test("3枚＋メモは7ページを上から配置し最後も罫線を残す", arguments: [false, true])
    func handout(landscape: Bool) async throws {
        let source = try RenderingFixtures.pdf(count: 7, size: CGSize(width: 800, height: 450))
        let output = try await PDFComposer().compose(
            source, layout: PrintLayout.a4Handout3.oriented(landscape), options: PrintOptions(showsPageNumbers: true))
        #expect(output.pageCount == 3)
        for sheet in 0..<3 {
            let page = try #require(output.page(at: sheet))
            for (slot, y) in [562.2, 302.4, 42.5].enumerated() {
                let rect = CGRect(x: 42.5, y: y, width: 312, height: 237)
                let text = page.selection(for: rect)?.string ?? ""
                let number = sheet * 3 + slot + 1
                if number <= 7 {
                    #expect(text.contains("PAGE-\(number)"))
                    let numberRect = CGRect(x: 42.5, y: y - 22, width: 312, height: 22)
                    #expect(
                        page.selection(for: numberRect)?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
                            == String(number))
                    #expect(try RenderingFixtures.pixel(page, x: 44, y: Int(y + 32))[0] < 60)
                } else {
                    #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    #expect(try RenderingFixtures.pixel(page, x: 44, y: Int(y + 32))[0] > 240)
                }
            }
            let linePixels = try (775...778).map { try RenderingFixtures.pixel(page, x: 430, y: $0)[0] }
            #expect(linePixels.min()! < 245)
            #expect(try RenderingFixtures.pixel(page, x: 430, y: 765)[0] > 250)
            #expect(try RenderingFixtures.pixel(page, x: 365, y: 777)[0] > 250)
        }
    }

    @Test("枠いっぱいの黒い内容でも番号は枠外か白い台紙の上で読める", arguments: [15.0, 0, 1])
    func handoutNumberContrast(margin: Double) async throws {
        let options = PrintOptions(marginsInMillimeters: margin, showsPageNumbers: true)
        let layout = PrintLayout.a4Handout3
        var box = CGRect(origin: .zero, size: layout.logicalPageSize(options: options))
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for _ in 0..<3 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(box)
            context.endPDFPage()
        }
        context.closePDF()
        let source = try #require(PDFDocument(data: data as Data))
        let output = try await PDFComposer().compose(source, layout: layout, options: options)
        let page = try #require(output.page(at: 0))
        for slot in 0..<3 {
            let selection = try #require(output.findString(String(slot + 1), withOptions: []).first)
            let number = selection.bounds(for: page)
            let unit = layout.slotRect(at: slot, options: options)
            let bottom = (1 - unit.maxY) * layout.sheetSize.height
            if slot < 2 || margin == 15 {
                #expect(number.maxY < bottom)
            } else {
                #expect(number.minX < 15)
                #expect(number.minY >= bottom)
            }
            #expect(try RenderingFixtures.pixel(page, x: Int(number.minX) - 1, y: Int(number.midY))[0] > 240)
            var ink: [UInt8] = []
            for x in Int(ceil(number.minX))..<Int(number.maxX) {
                for y in Int(ceil(number.minY))..<Int(number.maxY) {
                    ink.append(try RenderingFixtures.pixel(page, x: x, y: y)[0])
                }
            }
            #expect(try #require(ink.min()) < 180)
            #expect(
                try RenderingFixtures.pixel(page, x: Int(unit.midX * layout.sheetSize.width), y: Int(bottom + 20))[0]
                    < 10)
        }
    }

    @Test("3枚＋メモは負の余白と枠を作れない余白を拒否する", arguments: [-1.0, 101, Double.nan, Double.infinity])
    func invalidHandoutMargins(margin: Double) async throws {
        let source = try RenderingFixtures.pdf()
        await #expect(throws: PDFComposer.CompositionError.invalidMargins) {
            _ = try await PDFComposer().compose(
                source, layout: .a4Handout3, options: PrintOptions(marginsInMillimeters: margin))
        }
    }

    @Test("横長2アップは上から順に配置し最後の下半分は白紙になる")
    func stackedTwoUp() async throws {
        let source = try RenderingFixtures.pdf(count: 3, size: CGSize(width: 800, height: 450))
        let output = try await PDFComposer().compose(
            source, layout: PrintLayout.a3TwoUp.oriented(true), options: PrintOptions())
        #expect(output.pageCount == 2)
        let first = try #require(output.page(at: 0))
        let last = try #require(output.page(at: 1))
        let top = CGRect(x: 0, y: 596, width: 842, height: 595)
        let bottom = CGRect(x: 0, y: 0, width: 842, height: 595)
        #expect(first.selection(for: top)?.string?.contains("PAGE-1") == true)
        #expect(first.selection(for: bottom)?.string?.contains("PAGE-2") == true)
        #expect(last.selection(for: top)?.string?.contains("PAGE-3") == true)
        let blank = (last.selection(for: bottom)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(blank.isEmpty)
    }

    @Test("5ページのA3冊子は4面になり白紙とページ順が左右のスロットに反映される")
    func booklet() async throws {
        let output = try await PDFComposer().compose(
            RenderingFixtures.pdf(count: 5), layout: .a3BookletA4, options: PrintOptions())
        #expect(output.pageCount == 4)
        let expected: [[String?]] = [[nil, "PAGE-1"], ["PAGE-2", nil], [nil, "PAGE-3"], ["PAGE-4", "PAGE-5"]]
        for index in 0..<4 {
            let page = try #require(output.page(at: index))
            let box = page.bounds(for: .mediaBox)
            #expect(abs(box.width - 1190.55) < 0.1)
            #expect(abs(box.height - 841.89) < 0.1)
            for slot in 0..<2 {
                let rect = CGRect(x: CGFloat(slot) * box.width / 2, y: 0, width: box.width / 2, height: box.height)
                let text = page.selection(for: rect)?.string ?? ""
                if let marker = expected[index][slot] {
                    #expect(text.contains(marker))
                } else {
                    #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    @Test("Letterのページ全体がA4に収まり中央に置かれる")
    func fitsLetter() async throws {
        let output = try await PDFComposer().compose(
            RenderingFixtures.pdf(), layout: .a4Single, options: PrintOptions())
        let page = try #require(output.page(at: 0))
        let box = page.bounds(for: .mediaBox)
        #expect(abs(box.width - 595.28) < 0.1)
        #expect(abs(box.height - 841.89) < 0.1)
        let selection = try #require(output.findString("PAGE-1", withOptions: []).first)
        #expect(box.contains(selection.bounds(for: page)))
        #expect(try RenderingFixtures.pixel(page, x: 5, y: 41)[0] < 30)
        #expect(try RenderingFixtures.pixel(page, x: 5, y: 5)[0] > 240)
    }

    @Test("論理ページは用紙の中の場所と同じ大きさになり、縦横比を保って中央に収まる")
    func fittedPages() async throws {
        let source = try RenderingFixtures.pdf(count: 3, size: CGSize(width: 800, height: 450))
        let size = CGSize(width: 420, height: 595)
        let output = try await PDFComposer().fitted(source, pageSize: size)
        #expect(output.pageCount == 3)
        for index in 0..<3 {
            let page = try #require(output.page(at: index))
            #expect(page.bounds(for: .mediaBox).size == size)
            #expect(try RenderingFixtures.pixel(page, x: 210, y: 40)[0] > 240)
            #expect(page.string?.contains("PAGE-\(index + 1)") == true)
        }
    }

    @Test("用紙の中の場所と同じ大きさのページは描き直さない")
    func fittedPagesKeepsMatchingPages() async throws {
        let size = CGSize(width: 420, height: 595)
        let source = try RenderingFixtures.pdf(count: 2, size: size)
        let output = try await PDFComposer().fitted(source, pageSize: size)
        #expect(output !== source)
        #expect(output.pageCount == 2)
        #expect(output.page(at: 0)?.bounds(for: .mediaBox).size == size)
    }

    @Test("ページ番号は下余白に置かれ白紙には描かれない")
    func pageNumbers() async throws {
        let source = try RenderingFixtures.pdf(count: 1, size: PaperSize.a4.size)
        let output = try await PDFComposer().compose(
            source, layout: .a3BookletA4, options: PrintOptions(showsPageNumbers: true))
        let page = try #require(output.page(at: 0))
        let number = try #require(page.selection(for: CGRect(x: 595, y: 0, width: 596, height: 42))?.string)
        #expect(number.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
        let blank = (output.page(at: 1)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(blank.isEmpty)
        #expect(source.page(at: 0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) == "PAGE-1")
    }

    @Test("向きの確定後に選んだ補正は面付けとキャッシュだけを変える")
    func resolvedBackRotation() async throws {
        let document = try RenderingFixtures.pdf(count: 2, size: CGSize(width: 841.89, height: 595.28))
        let source = DocumentSource(data: try #require(document.dataRepresentation()), format: .pdf)
        let renderer = DocumentRenderer()
        let settings = RenderSettings(
            layout: .a4Duplex, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        let prepared = try await renderer.prepare(source, settings: settings)
        #expect(prepared.layout.sentDuplex == .shortEdge)
        let rotated = try await renderer.composeSheet(for: prepared, rotatesBackSides: true)
        let front = try #require(rotated.sheetDocument.page(at: 0))
        let back = try #require(rotated.sheetDocument.page(at: 1))
        #expect(try RenderingFixtures.pixel(front, x: 5, y: 5)[0] < 30)
        #expect(try RenderingFixtures.pixel(back, x: 5, y: 5)[0] > 240)
        #expect(try RenderingFixtures.pixel(back, x: 836, y: 590)[0] < 30)
        let plain = try await renderer.composeSheet(for: prepared, rotatesBackSides: false)
        #expect(try RenderingFixtures.pixel(#require(plain.sheetDocument.page(at: 1)), x: 5, y: 5)[0] < 30)
        let cached = try await renderer.composeSheet(for: prepared, rotatesBackSides: true)
        #expect(cached.sheetDocument === rotated.sheetDocument)
        #expect(renderer.logicalRenderCount == 1)
        #expect(renderer.sheetCompositionCount == 2)
    }

    @Test("裏面回転は裏面の内容だけを用紙中心の周りに180度回す")
    func backRotation() async throws {
        let source = try RenderingFixtures.pdf(count: 2, size: PaperSize.a4.size)
        let output = try await PDFComposer().compose(
            source, layout: .a4Duplex, options: PrintOptions(rotatesBackSides: true))
        let front = try #require(output.page(at: 0))
        let back = try #require(output.page(at: 1))
        #expect(try RenderingFixtures.pixel(front, x: 5, y: 5)[0] < 30)
        #expect(try RenderingFixtures.pixel(back, x: 5, y: 5)[0] > 240)
        #expect(try RenderingFixtures.pixel(back, x: 590, y: 836)[0] < 30)
    }

    @Test("PDFのRotateを反映して縦横比を保つ", arguments: [90, 180, 270])
    func pageRotation(angle: Int) async throws {
        let source = try RenderingFixtures.pdf(size: CGSize(width: 200, height: 400))
        source.page(at: 0)?.rotation = angle
        let output = try await PDFComposer().compose(source, layout: .a4Single, options: PrintOptions())
        let page = try #require(output.page(at: 0))
        let bounds = try #require(output.findString("PAGE-1", withOptions: []).first?.bounds(for: page))
        #expect(page.bounds(for: .mediaBox).contains(bounds))
        if angle == 180 {
            #expect(bounds.midY < 421)
        } else {
            #expect(bounds.height > bounds.width)
            #expect(angle == 90 ? bounds.midX > 297 : bounds.midX < 297)
        }
    }

    @Test("空のPDFと不正な余白を拒否する")
    func invalidInput() async throws {
        await #expect(throws: PDFComposer.CompositionError.emptyDocument) {
            _ = try await PDFComposer().compose(PDFDocument(), layout: .a4Single, options: PrintOptions())
        }
        let source = try RenderingFixtures.pdf()
        await #expect(throws: PDFComposer.CompositionError.invalidMargins) {
            _ = try await PDFComposer().compose(
                source, layout: .a4Single, options: PrintOptions(marginsInMillimeters: .nan))
        }
    }

    @Test("2アップは左から順に置き最後の空きスロットに番号を描かない")
    func twoUp() async throws {
        let output = try await PDFComposer().compose(
            RenderingFixtures.pdf(count: 3), layout: .a3TwoUp,
            options: PrintOptions(showsPageNumbers: true, rotatesBackSides: true))
        #expect(output.pageCount == 2)
        let first = try #require(output.page(at: 0))
        let last = try #require(output.page(at: 1))
        #expect(first.selection(for: CGRect(x: 0, y: 0, width: 595, height: 842))?.string?.contains("PAGE-1") == true)
        #expect(first.selection(for: CGRect(x: 596, y: 0, width: 595, height: 842))?.string?.contains("PAGE-2") == true)
        #expect(last.selection(for: CGRect(x: 0, y: 0, width: 595, height: 842))?.string?.contains("PAGE-3") == true)
        let blank = last.selection(for: CGRect(x: 596, y: 0, width: 595, height: 842))?.string ?? ""
        #expect(blank.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("原点がずれたCropBoxの外を描かず中央に配置する")
    func cropBox() async throws {
        let source = try RenderingFixtures.pdf(size: CGSize(width: 200, height: 400))
        source.page(at: 0)?.setBounds(CGRect(x: 20, y: 20, width: 160, height: 360), for: .cropBox)
        let output = try await PDFComposer().compose(source, layout: .a4Single, options: PrintOptions())
        let page = try #require(output.page(at: 0))
        #expect(page.string?.contains("PAGE-1") == true)
        #expect(try RenderingFixtures.pixel(page, x: 115, y: 5)[0] > 240)
        let bounds = try #require(output.findString("PAGE-1", withOptions: []).first?.bounds(for: page))
        #expect(bounds.minX > 110 && bounds.minX < 140, "bounds: \(bounds)")
    }

    @Test("合成途中のキャンセルはCancellationErrorになる")
    func cancellation() async throws {
        let source = try RenderingFixtures.pdf(count: 100)
        let task = Task {
            _ = try await PDFComposer().compose(source, layout: .a3BookletA4, options: PrintOptions())
        }
        await Task.yield()
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test("3枚＋メモの段のあいだでは、上のページのフッターと下のページのヘッダーが重ならない")
    func handoutFurnitureKeepsApart() async throws {
        let source = try RenderingFixtures.pdf(count: 3, size: CGSize(width: 800, height: 450))
        var options = PrintOptions()
        options.furniture.topCenter = "HHHHHH"
        options.furniture.bottomCenter = "FFFFFF"
        let output = try await PDFComposer().compose(source, layout: .a4Handout3, options: options)
        let page = try #require(output.page(at: 0))
        let size = page.bounds(for: .mediaBox).size
        let layout = PrintLayout.a4Handout3
        let upper = layout.slotRect(at: 0, options: options)
        let lower = layout.slotRect(at: 1, options: options)
        let top = Int(upper.maxY * size.height) + 1
        let bottom = Int(lower.minY * size.height) - 1
        let columns = Int(upper.midX * size.width) - 30...Int(upper.midX * size.width) + 30
        var runs = 0
        var inInk = false
        for y in top...bottom {
            let hasInk = try columns.contains { try RenderingFixtures.pixel(page, x: $0, y: y)[0] < 160 }
            if hasInk, !inInk { runs += 1 }
            inInk = hasInk
        }
        #expect(runs == 2)
    }

    @Test("欄に入らない文字は全文に戻さず、隣の欄と重ねない")
    func furnitureNeverOverflows() async throws {
        let source = try RenderingFixtures.pdf(count: 1, size: CGSize(width: 595, height: 842))
        var options = PrintOptions()
        options.furniture.bottomLeft = String(repeating: "左", count: 80)
        options.furniture.bottomCenter = String(repeating: "中", count: 80)
        options.furniture.bottomRight = String(repeating: "右", count: 80)
        let output = try await PDFComposer().compose(source, layout: .a4Single, options: options)
        let text = try #require(output.page(at: 0)?.string)
        #expect(text.filter { $0 == "左" }.count < 80)
        #expect(text.filter { $0 == "中" }.count < 80)
    }
}
