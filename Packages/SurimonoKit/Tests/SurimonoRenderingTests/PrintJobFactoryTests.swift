import AppKit
import ApplicationServices
import SurimonoCore
import SurimonoRendering
import Testing

@MainActor
struct PrintJobFactoryTests {
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
