import CoreGraphics
import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@MainActor
struct NotePageDrawingTests {
    @Test("ノートPDFは指定した枚数と論理ページ寸法を持つ", arguments: [PaperSize.a4, .a5])
    func document(paper: PaperSize) async throws {
        let document = try await NotePageDrawing.document(
            style: NotePaperStyle(), pageSize: paper.size, pageNumbers: [2, 4, 6])
        #expect(document.pageCount == 3)
        for index in 0..<3 {
            let page = try #require(document.page(at: index))
            #expect(abs(page.bounds(for: .mediaBox).width - paper.size.width) < 0.01)
            #expect(abs(page.bounds(for: .mediaBox).height - paper.size.height) < 0.01)
            #expect(try inkPixels(page: page) > 100)
        }
    }

    @Test("各線種をビットマップへ描くと無地以外は白紙にならない", arguments: NotePaperStyle.Kind.allCases)
    func kinds(kind: NotePaperStyle.Kind) throws {
        let style = NotePaperStyle(kind: kind, header: .init(pageNumber: false))
        let pixels = try bitmap { context in
            try NotePageDrawing.draw(style: style, pageSize: PaperSize.a5.size, pageNumber: 1, in: context)
        }
        #expect(kind == .plain ? pixels == 0 : pixels > 100)
    }

    @Test("各柄は罫線と番号を消しても独立して描かれる", arguments: NotePaperStyle.Decoration.allCases)
    func decorations(decoration: NotePaperStyle.Decoration) throws {
        let style = NotePaperStyle(kind: .plain, header: .init(pageNumber: false), decoration: decoration)
        let pixels = try bitmap { context in
            try NotePageDrawing.draw(style: style, pageSize: PaperSize.a5.size, pageNumber: 1, in: context)
        }
        #expect(decoration == .none ? pixels == 0 : pixels > 100)
    }

    @Test("全プリセットのPDFを再描画しても白紙にならない", arguments: NotePaperPreset.all)
    func presets(preset: NotePaperPreset) async throws {
        let document = try await NotePageDrawing.document(style: preset.style, pageSize: PaperSize.a5.size)
        #expect(try inkPixels(page: #require(document.page(at: 0))) > 100)
    }

    @Test("ヘッダーの番号は呼び出し側の論理ページ番号を使いオフなら描かない")
    func pageNumbers() async throws {
        var style = NotePaperStyle(kind: .plain, header: .init(pageNumber: true))
        let numbered = try await NotePageDrawing.document(style: style, pageSize: PaperSize.a5.size, pageNumbers: [42])
        #expect(numbered.string?.trimmingCharacters(in: .whitespacesAndNewlines) == "42")
        #expect(try inkPixels(page: #require(numbered.page(at: 0))) > 0)
        style.header.pageNumber = false
        let blank = try await NotePageDrawing.document(style: style, pageSize: PaperSize.a5.size, pageNumbers: [42])
        #expect((blank.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(try inkPixels(page: #require(blank.page(at: 0))) == 0)
    }

    @Test("日付欄とタイトル欄はそれぞれ独立して描ける", arguments: [true, false])
    func headers(date: Bool) async throws {
        let style = NotePaperStyle(kind: .plain, header: .init(date: date, title: !date, pageNumber: false))
        let document = try await NotePageDrawing.document(style: style, pageSize: PaperSize.a5.size)
        #expect(document.string?.contains(date ? "年" : "タイトル") == true)
        #expect(try inkPixels(page: #require(document.page(at: 0))) > 100)
    }

    @Test("ノートPDFを既存の冊子合成へ渡せる")
    func composition() async throws {
        let document = try await NotePageDrawing.document(
            style: NotePaperStyle(), pageSize: PaperSize.a5.size,
            pageNumbers: Array(1...8))
        let sheets = try await PDFComposer().compose(document, layout: .a4BookletA5, options: PrintOptions())
        #expect(sheets.pageCount == 4)
        #expect(sheets.page(at: 0)?.string?.contains("8") == true)
        #expect(sheets.page(at: 0)?.string?.contains("1") == true)
    }

    @Test("不正な数値は描画ループに入る前に拒否する", arguments: [0.0, -1, Double.nan, Double.infinity, 0.000001])
    func invalidSpacing(spacing: Double) async {
        await #expect(throws: NotePageDrawing.DrawingError.invalidStyle) {
            _ = try await NotePageDrawing.document(
                style: NotePaperStyle(spacingInMillimeters: spacing), pageSize: PaperSize.a5.size)
        }
    }

    @Test("ページがないPDFと描画領域のないPDFは拒否する")
    func invalidDocument() async {
        await #expect(throws: NotePageDrawing.DrawingError.emptyDocument) {
            _ = try await NotePageDrawing.document(
                style: NotePaperStyle(), pageSize: PaperSize.a5.size, pageNumbers: [])
        }
        await #expect(throws: NotePageDrawing.DrawingError.invalidGeometry) {
            _ = try await NotePageDrawing.document(style: NotePaperStyle(), pageSize: .zero)
        }
        await #expect(throws: NotePageDrawing.DrawingError.invalidGeometry) {
            _ = try await NotePageDrawing.document(
                style: NotePaperStyle(marginInMillimeters: 100), pageSize: PaperSize.a5.size)
        }
        await #expect(throws: NotePageDrawing.DrawingError.invalidStyle) {
            _ = try await NotePageDrawing.document(
                style: NotePaperStyle(colorHex: "not-a-color"), pageSize: PaperSize.a5.size)
        }
    }

    @Test("A5横の余白12mmに間隔100mmの五線譜は先頭の空きまで収まらない")
    func staffDoesNotFitLandscapeA5() async {
        let style = NotePaperStyle(
            kind: .staff, spacingInMillimeters: 100, marginInMillimeters: 12,
            header: .init(pageNumber: false))
        await #expect(throws: NotePageDrawing.DrawingError.invalidGeometry) {
            _ = try await NotePageDrawing.document(
                style: style,
                pageSize: CGSize(width: PaperSize.a5.size.height, height: PaperSize.a5.size.width))
        }
    }

    @Test("五線譜は先頭40mmと五線100mmがちょうど収まる境界で描ける", arguments: [false, true])
    func staffMinimumHeight(pageNumber: Bool) async throws {
        let style = NotePaperStyle(
            kind: .staff, spacingInMillimeters: 100, marginInMillimeters: 12,
            header: .init(pageNumber: pageNumber))
        let height = pageNumber ? 170.0 : 164.0
        let document = try await NotePageDrawing.document(
            style: style,
            pageSize: CGSize(width: 148 * 72 / 25.4, height: height * 72 / 25.4))
        #expect(document.pageCount == 1)
        #expect(try inkPixels(page: #require(document.page(at: 0))) > 100)
        await #expect(throws: NotePageDrawing.DrawingError.invalidGeometry) {
            _ = try await NotePageDrawing.document(
                style: style,
                pageSize: CGSize(width: 148 * 72 / 25.4, height: (height - 0.01) * 72 / 25.4))
        }
    }

    @Test("原稿用紙は100mmの列と行が一つずつ収まる境界で描ける")
    func manuscriptMinimumSize() async throws {
        let style = NotePaperStyle(
            kind: .genko, spacingInMillimeters: 100, marginInMillimeters: 12,
            header: .init(pageNumber: false))
        let document = try await NotePageDrawing.document(
            style: style,
            pageSize: CGSize(width: 124 * 72 / 25.4, height: 124 * 72 / 25.4))
        #expect(document.pageCount == 1)
        #expect(try inkPixels(page: #require(document.page(at: 0))) > 100)
        for size in [CGSize(width: 123.99, height: 124), CGSize(width: 124, height: 123.99)] {
            await #expect(throws: NotePageDrawing.DrawingError.invalidGeometry) {
                _ = try await NotePageDrawing.document(
                    style: style,
                    pageSize: CGSize(width: size.width * 72 / 25.4, height: size.height * 72 / 25.4))
            }
        }
    }

    @Test("A5横の余白12mmと間隔100mmで原稿用紙は一列描ける")
    func manuscriptFitsLandscapeA5() async throws {
        let style = NotePaperStyle(
            kind: .genko, spacingInMillimeters: 100, marginInMillimeters: 12,
            header: .init(pageNumber: false))
        let document = try await NotePageDrawing.document(
            style: style,
            pageSize: CGSize(width: PaperSize.a5.size.height, height: PaperSize.a5.size.width))
        #expect(try inkPixels(page: #require(document.page(at: 0))) > 100)
    }

    @Test(
        "ギンガムの余白で残り幅や高さがゼロ以下なら矩形の標準化に関係なく拒否する",
        arguments: [
            CGSize(width: 20, height: 30), CGSize(width: 20, height: 100),
            CGSize(width: 100, height: 30), CGSize(width: 38, height: 40),
        ])
    func decorationConsumesPage(size: CGSize) async {
        let style = NotePaperStyle(marginInMillimeters: 0, header: .init(pageNumber: false), decoration: .gingham)
        await #expect(throws: NotePageDrawing.DrawingError.invalidGeometry) {
            _ = try await NotePageDrawing.document(
                style: style,
                pageSize: CGSize(width: size.width * 72 / 25.4, height: size.height * 72 / 25.4))
        }
    }

    @Test("横罫はmmの余白と間隔を守り指定したsRGB色で描く")
    func physicalRuling() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil, width: 114, height: 142, bitsPerComponent: 8,
                bytesPerRow: 456, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let style = NotePaperStyle(
            weightInMillimeters: 0.5, spacingInMillimeters: 5,
            marginInMillimeters: 10, colorHex: "#204060", header: .init(pageNumber: false))
        try NotePageDrawing.draw(
            style: style, pageSize: CGSize(width: 40 * 72 / 25.4, height: 50 * 72 / 25.4), in: context)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let onLine = 99 * 456 + 60 * 4
        #expect(abs(Int(bytes[onLine]) - 32) <= 2)
        #expect(abs(Int(bytes[onLine + 1]) - 64) <= 2)
        #expect(abs(Int(bytes[onLine + 2]) - 96) <= 2)
        #expect(bytes[90 * 456 + 60 * 4] == 255)
        #expect(bytes[99 * 456 + 20 * 4] == 255)
    }

    private func inkPixels(page: PDFPage) throws -> Int {
        try bitmap { context in page.draw(with: .mediaBox, to: context) }
    }

    private func bitmap(draw: (CGContext) throws -> Void) throws -> Int {
        let width = 600
        let height = 850
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        try draw(context)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return stride(from: 0, to: width * height * 4, by: 4).filter {
            bytes[$0] < 245 || bytes[$0 + 1] < 245 || bytes[$0 + 2] < 245
        }.count
    }
}
