import AppKit
import ApplicationServices
import ImageIO
import PDFKit
import SurimonoCore
import SurimonoRendering
import Synchronization
import Testing

@MainActor
struct PrintJobFactoryTests {
    @Test("寸法判定後に横画像が読み飛ばされた束は残った縦用紙で印刷する")
    func skippedLandscapeImages() async throws {
        _ = NSApplication.shared
        var bmp = Data(repeating: 0, count: 58)
        func put(_ value: UInt32, at offset: Int, bytes: Int = 4) {
            for index in 0..<bytes { bmp[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
        }
        bmp[0] = 0x42
        bmp[1] = 0x4D
        put(58, at: 2)
        put(54, at: 10)
        put(40, at: 14)
        put(400, at: 18)
        put(200, at: 22)
        put(1, at: 26, bytes: 2)
        put(24, at: 28, bytes: 2)
        let bytes = bmp
        let imageSource = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 400)
        #expect((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 200)
        let badURLs = [URL(fileURLWithPath: "/fixture/bad1.bmp"), URL(fileURLWithPath: "/fixture/bad2.bmp")]
        let badImages = badURLs.map { url in
            let reads = Mutex(0)
            return DocumentSource.Image(fileURL: url, contentHash: .of(bytes)) {
                // Fail after metadata inspection without depending on ImageIO's recovery of damaged pixels.
                let count = reads.withLock { count in
                    count += 1
                    return count
                }
                guard count == 1 else { throw ImagePageRenderer.RenderingError.invalidImage }
                return bytes
            }
        }
        let good = DocumentSource.Image(
            data: try RenderingFixtures.image(orientation: 6), fileURL: URL(fileURLWithPath: "/fixture/good.tiff"))
        let result = try await DocumentRenderer().render(
            .images([good] + badImages),
            settings: RenderSettings(
                layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
                preset: HTMLCleanupPreset(id: "none", name: "None")))
        #expect(result.resolvedOrientation == .landscape)
        #expect(result.unreadableImageURLs == badURLs)
        #expect(result.sheetOrientations == [.portrait])
        let document = CapturingPrintDocument()
        document.insert(try #require(result.sheetDocument.page(at: 0)), at: 0)
        let operation = try #require(
            PrintJobFactory().printOperation(
                for: document, layout: result.layout, showsPrintPanel: false))
        #expect(operation.printInfo.orientation == .portrait)
        #expect(document.capturedAutoRotate == false)
        #expect(document.capturedScaling == .pageScaleDownToFit)
    }

    @Test("通常片面の印刷設定は多数決レイアウトより実際の用紙の向きを優先する", arguments: [false, true])
    func uniformSheetOperation(landscape: Bool) throws {
        _ = NSApplication.shared
        let document = CapturingPrintDocument()
        let pdf = try RenderingFixtures.pdf(
            size: landscape ? CGSize(width: 841.89, height: 595.28) : CGSize(width: 595.28, height: 841.89))
        document.insert(try #require(pdf.page(at: 0)), at: 0)
        let operation = try #require(
            PrintJobFactory().printOperation(
                for: document, layout: PrintLayout.a4Single.oriented(!landscape), showsPrintPanel: false))
        #expect(operation.printInfo.orientation == (landscape ? .landscape : .portrait))
        #expect(document.capturedAutoRotate == false)
    }

    @Test("混在用紙は縦の選択用紙と自動回転で縮小のみの印刷操作を作る")
    func mixedOperation() throws {
        _ = NSApplication.shared
        let document = CapturingPrintDocument()
        let portrait = try RenderingFixtures.pdf(size: CGSize(width: 595.28, height: 841.89))
        let landscape = try RenderingFixtures.pdf(size: CGSize(width: 841.89, height: 595.28))
        document.insert(try #require(portrait.page(at: 0)), at: 0)
        document.insert(try #require(landscape.page(at: 0)), at: 1)
        let operation = try #require(
            PrintJobFactory().printOperation(
                for: document, layout: .a4Single.oriented(true), showsPrintPanel: false))
        #expect(document.capturedAutoRotate == true)
        #expect(document.capturedScaling == .pageScaleDownToFit)
        #expect(operation.printInfo.orientation == .portrait)
        #expect(abs(operation.printInfo.paperSize.width - 595.28) < 1)
        #expect(abs(operation.printInfo.paperSize.height - 841.89) < 1)
        #expect(!operation.showsPrintPanel)
        _ = PrintJobFactory().printOperation(for: document, layout: .a4Duplex.oriented(true), showsPrintPanel: true)
        #expect(document.capturedAutoRotate == false)
    }

    @Test("通常横は横向きで上下2アップは縦向きの印刷設定になる")
    func orientedSheets() {
        let normal = PrintJobFactory().printInfo(for: PrintLayout.a4Single.oriented(true))
        #expect(normal.orientation == .landscape)
        #expect(abs(normal.paperSize.width - 841.89) < 1)
        #expect(abs(normal.paperSize.height - 595.28) < 1)
        let stacked = PrintJobFactory().printInfo(for: PrintLayout.a3TwoUp.oriented(true))
        #expect(stacked.orientation == .portrait)
        #expect(abs(stacked.paperSize.width - 841.89) < 1)
        #expect(abs(stacked.paperSize.height - 1190.55) < 1)
    }

    @Test(
        "レイアウトに対応した用紙寸法と両面設定を構築する",
        arguments: [PrintLayout.a3BookletA4, .a4Duplex, .a4Single, .a4Handout3, .a4Handout3.oriented(true)])
    func settings(layout: PrintLayout) throws {
        let base = NSPrintInfo()
        base.scalingFactor = 0.5
        base.leftMargin = 99
        let info = PrintJobFactory().printInfo(for: layout, base: base)
        #expect(info !== base)
        #expect(base.scalingFactor == 0.5)
        #expect(base.leftMargin == 99)
        #expect(info.orientation == (layout == .a3BookletA4 ? .landscape : .portrait))
        #expect(abs(info.paperSize.width - (layout == .a3BookletA4 ? 1190.55 : 595.28)) < 1)
        #expect(abs(info.paperSize.height - 841.89) < 1)
        #expect(info.topMargin == 0 && info.bottomMargin == 0 && info.leftMargin == 0 && info.rightMargin == 0)
        #expect(info.scalingFactor == 1)
        #expect(info.isHorizontallyCentered && info.isVerticallyCentered)
        var duplex = PMDuplexMode(kPMDuplexNone)
        #expect(PMGetDuplex(OpaquePointer(info.pmPrintSettings()), &duplex) == noErr)
        let expected =
            layout == .a3BookletA4 ? kPMDuplexTumble : layout == .a4Duplex ? kPMDuplexNoTumble : kPMDuplexNone
        #expect(duplex == PMDuplexMode(expected))
    }

    @Test("プリンターを指定しなければ、もとの設定のプリンターに送る")
    func keepsTheBasePrinter() {
        let base = NSPrintInfo()
        let info = PrintJobFactory().printInfo(for: .a4Single, base: base)
        #expect(info.printer.name == base.printer.name)
    }

    @Test(
        "指定したプリンターに送り、用紙はレイアウトのまま", .enabled(if: !NSPrinter.printerNames.isEmpty, "プリンターがある環境だけ"))
    func usesTheChosenPrinter() throws {
        let name = try #require(NSPrinter.printerNames.last)
        let printer = try #require(NSPrinter(name: name))
        let info = PrintJobFactory().printInfo(for: .a3BookletA4, base: NSPrintInfo(), printer: printer)
        #expect(info.printer.name == name)
        #expect(info.orientation == .landscape)
        #expect(abs(info.paperSize.width - 1190.55) < 1)
    }

    @Test("印刷パネルで用紙と向きと部数と範囲を変更できる")
    func panel() throws {
        _ = NSApplication.shared
        let operation = try #require(
            PrintJobFactory().printOperation(for: RenderingFixtures.pdf(), layout: .a4Single, showsPrintPanel: true))
        #expect(operation.showsPrintPanel)
        #expect(
            operation.printPanel.options.contains([.showsPaperSize, .showsOrientation, .showsCopies, .showsPageRange]))
    }
}

// Capture the public PDFKit boundary without sending a job to a physical printer.
private final class CapturingPrintDocument: PDFDocument {
    var capturedAutoRotate: Bool?
    var capturedScaling: PDFPrintScalingMode?

    override func printOperation(
        for printInfo: NSPrintInfo?, scalingMode scaleMode: PDFPrintScalingMode, autoRotate doRotate: Bool
    ) -> NSPrintOperation? {
        capturedAutoRotate = doRotate
        capturedScaling = scaleMode
        return super.printOperation(for: printInfo, scalingMode: scaleMode, autoRotate: doRotate)
    }
}
