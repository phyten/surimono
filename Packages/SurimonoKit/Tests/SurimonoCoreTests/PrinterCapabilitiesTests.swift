import CoreGraphics
import Testing

@testable import SurimonoCore

struct PrinterCapabilitiesTests {
    private let a4 = CGSize(width: 595, height: 842)
    private let a3 = CGSize(width: 842, height: 1191)

    @Test("A4 までのプリンターでは、A3 の冊子は用紙の問題になり、A4 両面は問題にならない")
    func a4OnlyPrinter() {
        let printer = PrinterCapabilities(paperSizes: [a4, CGSize(width: 420, height: 595)], duplex: true)
        #expect(printer.issue(for: .a3BookletA4) == .paperNotAccepted(.a3))
        #expect(printer.issue(for: .a4Duplex) == nil)
        #expect(printer.issue(for: .a4BookletA5) == nil)
    }

    @Test("両面に刷れないプリンターでは、両面と冊子が両面の問題になり、片面は問題にならない")
    func simplexPrinter() {
        let printer = PrinterCapabilities(paperSizes: [a4, a3], duplex: false)
        #expect(printer.issue(for: .a4Duplex) == .duplexNotAvailable)
        #expect(printer.issue(for: .a3BookletA4) == .duplexNotAvailable)
        #expect(printer.issue(for: .a4BookletA5) == .duplexNotAvailable)
        #expect(printer.issue(for: .a4Single) == nil)
        #expect(printer.issue(for: .a3TwoUp) == nil)
    }

    @Test("用紙も両面も刷れないときは、用紙の問題を先に伝える")
    func paperComesFirst() {
        let printer = PrinterCapabilities(paperSizes: [a4], duplex: false)
        #expect(printer.issue(for: .a3BookletA4) == .paperNotAccepted(.a3))
    }

    @Test("何も分からないプリンターでは、どのレイアウトも問題にしない", arguments: PrintLayout.presets)
    func unknownCapabilities(layout: PrintLayout) {
        #expect(PrinterCapabilities().issue(for: layout) == nil)
    }

    @Test("用紙の一覧が空なら用紙は分からないままで、両面だけを判断する")
    func unknownPapers() {
        let printer = PrinterCapabilities(duplex: false)
        #expect(printer.accepts(a3) == nil)
        #expect(printer.issue(for: .a3TwoUp) == nil)
        #expect(printer.issue(for: .a3BookletA4) == .duplexNotAvailable)
    }

    @Test("両面が分からないプリンターでは、両面のレイアウトを問題にしない")
    func unknownDuplex() {
        #expect(PrinterCapabilities(paperSizes: [a4]).issue(for: .a4Duplex) == nil)
    }

    @Test("用紙は横向きに載っていても同じ用紙として受け付ける")
    func eitherOrientation() {
        let printer = PrinterCapabilities(paperSizes: [CGSize(width: 1191, height: 842)])
        #expect(printer.accepts(CGSize(width: 841.89, height: 1190.55)) == true)
        #expect(printer.issue(for: .a3TwoUp) == nil)
    }

    @Test("横向きの用紙に刷るレイアウトも、縦の用紙の一覧で受け付ける")
    func landscapeSheet() {
        let printer = PrinterCapabilities(paperSizes: [a4], duplex: true)
        let landscape = PrintLayout.a4Single.oriented(true)
        #expect(landscape.sheetSize.width > landscape.sheetSize.height)
        #expect(printer.issue(for: landscape) == nil)
    }

    @Test("用紙の大きさは 2pt までの違いを同じとみなし、それを超えると別の用紙になる")
    func tolerance() {
        #expect(PrinterCapabilities(paperSizes: [CGSize(width: 597, height: 840)]).accepts(PaperSize.a4.size) == true)
        #expect(PrinterCapabilities(paperSizes: [CGSize(width: 598, height: 842)]).accepts(PaperSize.a4.size) == false)
        // Letter is close to A4 but is another paper.
        #expect(PrinterCapabilities(paperSizes: [CGSize(width: 612, height: 792)]).accepts(PaperSize.a4.size) == false)
    }

    @Test("カスタム用紙に対応するプリンターは、範囲に収まる用紙を一覧になくても受け付ける")
    func customRange() {
        let printer = PrinterCapabilities(
            paperSizes: [a4], customRange: .init(width: 252...842, height: 360...3402))
        #expect(printer.issue(for: .a3BookletA4) == nil)
        #expect(printer.issue(for: .b4TwoUp) == nil)
        let narrow = PrinterCapabilities(paperSizes: [a4], customRange: .init(width: 252...612, height: 360...1008))
        #expect(narrow.issue(for: .a3TwoUp) == .paperNotAccepted(.a3))
    }

    // What the system writes for a driverless queue, cut down to the lines that matter.
    private let duplexPPD = """
        *PPD-Adobe: "4.3"
        *% A comment that says duplex must not count.
        *OpenUI *Duplex/2-Sided Printing: PickOne
        *DefaultDuplex: DuplexNoTumble
        *Duplex None/Off (1-Sided): "<</Duplex false>>setpagedevice"
        *Duplex DuplexNoTumble/Long-Edge (Portrait): "<</Duplex true/Tumble false>>setpagedevice"
        *Duplex DuplexTumble/Short-Edge (Landscape): "<</Duplex true/Tumble true>>setpagedevice"
        *CloseUI: *Duplex
        *OpenUI *PageSize/Media Size: PickOne
        *PageSize A4/A4: "<</PageSize[595 842]>>setpagedevice"
        *CloseUI: *PageSize
        *PaperDimension A4/A4: "595 842"
        *PaperDimension Letter/US Letter: "612 792"
        *PaperDimension A5: "419.5 595"
        """

    private let simplexPPD = """
        *PPD-Adobe: "4.3"
        *% No duplex unit here.
        *OpenUI *PageSize/Media Size: PickOne
        *CloseUI: *PageSize
        *PaperDimension A4/A4: "595 842"
        *PaperDimension A3/A3: "842 1191"
        *ParamCustomPageSize Width: 1 points 252 842
        *ParamCustomPageSize Height: 2 points 360 3402
        *ParamCustomPageSize Orientation: 5 int 0 3
        *CustomPageSize True: ""
        """

    @Test("PPD から用紙の大きさと両面の有無を読む")
    func readsPPD() throws {
        let printer = try #require(PrinterCapabilities(paperSizes: [], ppd: duplexPPD))
        #expect(
            printer.paperSizes == [
                CGSize(width: 595, height: 842), CGSize(width: 612, height: 792), CGSize(width: 419.5, height: 595),
            ])
        #expect(printer.duplex == true)
        #expect(printer.customRange == nil)
        #expect(printer.issue(for: .a3BookletA4) == .paperNotAccepted(.a3))
        #expect(printer.issue(for: .a4Duplex) == nil)
    }

    @Test("両面の項目がどこにもない PPD は両面に刷れず、カスタム用紙の範囲も読む")
    func readsSimplexPPD() throws {
        let printer = try #require(PrinterCapabilities(paperSizes: [], ppd: simplexPPD))
        #expect(printer.duplex == false)
        #expect(printer.customRange == .init(width: 252...842, height: 360...3402))
        #expect(printer.issue(for: .a4Duplex) == .duplexNotAvailable)
        #expect(printer.issue(for: .a3TwoUp) == nil)
    }

    @Test("両面の選択肢が「なし」だけの PPD は両面に刷れない")
    func duplexOnlyNone() throws {
        let ppd = """
            *PPD-Adobe: "4.3"
            *OpenUI *Duplex/2-Sided Printing: PickOne
            *Duplex None/Off: ""
            *CloseUI: *Duplex
            """
        #expect(try #require(PrinterCapabilities(paperSizes: [], ppd: ppd)).duplex == false)
    }

    @Test("標準の Duplex がなくメーカー独自の両面の項目がある PPD では、両面は分からないままにする")
    func vendorDuplexKeyword() throws {
        let ppd = """
            *PPD-Adobe: "4.3"
            *OpenUI *KMDuplex/Print Type: PickOne
            *KMDuplex 1Sided/1-Sided: ""
            *KMDuplex 2Sided/2-Sided: ""
            *CloseUI: *KMDuplex
            *PaperDimension A4/A4: "595 842"
            """
        let printer = try #require(PrinterCapabilities(paperSizes: [], ppd: ppd))
        #expect(printer.duplex == nil)
        #expect(printer.issue(for: .a4Duplex) == nil)
    }

    @Test("システムの用紙の一覧と PPD の用紙を合わせて使う")
    func mergesPaperList() throws {
        let printer = try #require(PrinterCapabilities(paperSizes: [a3], ppd: duplexPPD))
        #expect(printer.accepts(PaperSize.a3.size) == true)
        #expect(printer.accepts(PaperSize.a4.size) == true)
        #expect(printer.accepts(PaperSize.b4.size) == false)
    }

    @Test("PPD がなければ、用紙の一覧だけを使い、両面は分からないままにする")
    func paperListOnly() throws {
        let printer = try #require(PrinterCapabilities(paperSizes: [a4], ppd: nil))
        #expect(printer.duplex == nil)
        #expect(printer.issue(for: .a3BookletA4) == .paperNotAccepted(.a3))
        #expect(printer.issue(for: .a4Duplex) == nil)
    }

    @Test("用紙の一覧も PPD もなければ、何も分からない", arguments: [nil, "", "not a printer description"])
    func nothingKnown(ppd: String?) {
        #expect(PrinterCapabilities(paperSizes: [], ppd: ppd) == nil)
    }
}
