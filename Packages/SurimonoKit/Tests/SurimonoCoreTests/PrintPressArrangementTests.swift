import CoreGraphics
import Testing

@testable import SurimonoCore

struct PrintPressArrangementTests {
    /// Menus of 260 over six cards of 80 × 86, a result whose first line is 180 wide and whose notes wrap under 200,
    /// a printer menu of 205 for a typical model name, a PDF button of 130 (36 without its label) and Print of 62.
    private func parts(
        menus: CGFloat = 260, summaryLead: CGFloat = 180, printer: CGFloat = 205, pdf: CGFloat = 130
    ) -> PrintPressArrangement.Parts {
        PrintPressArrangement.Parts(
            menus: CGSize(width: menus, height: 28), card: CGSize(width: 80, height: 86), summaryWidth: 300,
            summaryLeadWidth: summaryLead, summaryHeight: { $0 >= 200 ? 50 : 66 },
            printer: CGSize(width: printer, height: 28), pdf: CGSize(width: pdf, height: 28), pdfCompactWidth: 36,
            button: CGSize(width: 62, height: 62))
    }

    @Test("左右に並べられる幅では、メニューとカードを左、結果とプリンター・PDF・印刷を右に置く")
    func beside() {
        let layout = PrintPressArrangement(width: 792, parts: parts())
        #expect(layout.form == .beside)
        #expect(layout.menus == CGRect(x: 0, y: 0, width: 260, height: 28))
        #expect(layout.cards == CGRect(x: 0, y: 34, width: 500, height: 86))
        #expect(layout.cardColumns == 6)
        #expect(layout.summary == CGRect(x: 517, y: 0, width: 275, height: 50))
        #expect(layout.printer == CGRect(x: 517, y: 58, width: 205, height: 28))
        #expect(layout.pdf == CGRect(x: 517, y: 92, width: 205, height: 28))
        #expect(layout.button == CGRect(x: 730, y: 58, width: 62, height: 62))
        #expect(layout.rule == CGRect(x: 508, y: 0, width: 1, height: 120))
        #expect(layout.size == CGSize(width: 792, height: 120))
        #expect(!layout.pdfIsCompact)
    }

    @Test("判と向きのメニューは、どの幅でもカードの上に横に並ぶ")
    func menusStayOverTheCards() {
        for width in [300, 499, 600, 791, 792, 1000, 1400] as [CGFloat] {
            let layout = PrintPressArrangement(width: width, parts: parts())
            #expect(layout.menus.origin == .zero, "\(width)")
            #expect(layout.cards.minY == layout.menus.maxY + PrintPressArrangement.rowGap, "\(width)")
            #expect(layout.cards.minX == 0, "\(width)")
        }
    }

    @Test("広い窓でも結果の列は必要以上に広げず、印刷ボタンは右端に置く")
    func besideWhenWide() {
        let layout = PrintPressArrangement(width: 1000, parts: parts())
        #expect(layout.form == .beside)
        #expect(layout.summary == CGRect(x: 700, y: 0, width: 300, height: 50))
        #expect(layout.printer == CGRect(x: 725, y: 58, width: 205, height: 28))
        #expect(layout.button.maxX == 1000)
        #expect(layout.size.height == 120)
    }

    @Test("左右に並べる最小の幅は、カードの列と線と、プリンター名を切らないボタンの列の和で、1ポイント狭ければ二段になる")
    func boundary() {
        // 500 for the cards, 8 + 1 + 8 around the rule, and 205 + 8 + 62 for the printer, PDF and Print.
        #expect(PrintPressArrangement(width: 792, parts: parts()).form == .beside)
        #expect(PrintPressArrangement(width: 791, parts: parts()).form == .stacked)
    }

    @Test("二段では結果とボタンが選ぶ側の下の1行になり、線を出さない")
    func stacked() {
        let layout = PrintPressArrangement(width: 791, parts: parts())
        #expect(layout.form == .stacked)
        #expect(layout.rule == .zero)
        #expect(layout.cards == CGRect(x: 0, y: 34, width: 500, height: 86))
        #expect(layout.summary == CGRect(x: 0, y: 134, width: 504, height: 50))
        #expect(layout.printer == CGRect(x: 516, y: 128, width: 205, height: 28))
        #expect(layout.pdf == CGRect(x: 516, y: 162, width: 205, height: 28))
        #expect(layout.button == CGRect(x: 729, y: 128, width: 62, height: 62))
        #expect(layout.size == CGSize(width: 791, height: 190))
        #expect(!layout.pdfIsCompact)
    }

    @Test("プリンター名を切る前に、右の群を下の段へ移す")
    func stacksBeforeCuttingThePrinter() {
        for width in [791, 700, 620, 560, 500] as [CGFloat] {
            let layout = PrintPressArrangement(width: width, parts: parts())
            #expect(layout.form == .stacked, "\(width)")
            #expect(layout.printer.width == 205, "\(width)")
            #expect(!layout.pdfIsCompact, "\(width)")
        }
    }

    @Test("下の段でも入らなければ、カードを折り返す前に、PDF のボタンの文字を外して絵だけにする")
    func compactPDF() {
        // A short printer name and a long PDF label, so that the labeled PDF button sets the column's width.
        let short = parts(summaryLead: 260, printer: 80, pdf: 200)
        // 260 for the result's first line, 12 + 8 + 62 around the buttons, and the PDF button's 200.
        #expect(!PrintPressArrangement(width: 542, parts: short).pdfIsCompact)
        let layout = PrintPressArrangement(width: 541, parts: short)
        #expect(layout.pdfIsCompact)
        #expect(layout.cardColumns == 6)
        #expect(layout.pdf.width == 36)
        #expect(layout.printer.width == 80)
    }

    @Test("カードが1段に入らなければ、縮めずに3列×2段に折り返す")
    func cardsFoldIntoThreeColumns() {
        let layout = PrintPressArrangement(width: 499, parts: parts())
        #expect(layout.cardColumns == 3)
        // Three cards of 80 with two gaps of 4, two rows of 86 with a gap of 4: the cards keep their size.
        #expect(layout.cards == CGRect(x: 0, y: 34, width: 248, height: 176))
        #expect(layout.printer.minY == 218)
        #expect(layout.pdfIsCompact)
        #expect(layout.printer.width == 205)
    }

    @Test("最後にプリンター名を省略して結果の1行目を保ち、120ポイントより狭くはしない")
    func cutsThePrinterLast() {
        // 180 for the result's first line, 12 + 8 + 62 around the buttons: the name keeps 400 - 262 = 138.
        let cut = PrintPressArrangement(width: 400, parts: parts())
        #expect(cut.printer.width == 138)
        #expect(cut.summary.width == 180)
        let narrowest = PrintPressArrangement(width: 300, parts: parts())
        #expect(narrowest.printer.width == 120)
        #expect(narrowest.summary.width == 98)
    }

    @Test("どの幅でも、プリンター名が切れていればPDFの文字は外れ、PDFの文字が外れていれば二段になっている")
    func foldOrder() {
        for width in stride(from: 240, through: 1400, by: 1) {
            for printer in [80, 205, 280, 400] as [CGFloat] {
                let layout = PrintPressArrangement(width: CGFloat(width), parts: parts(printer: printer))
                let ideal = min(printer, PrintPressArrangement.printerLimit)
                if layout.printer.width < ideal { #expect(layout.pdfIsCompact, "\(width) \(printer)") }
                if layout.cardColumns == 3 { #expect(layout.pdfIsCompact, "\(width) \(printer)") }
                if layout.pdfIsCompact { #expect(layout.form == .stacked, "\(width) \(printer)") }
            }
        }
    }

    @Test("長いプリンター名は広い窓でも280ポイントで省略し、全部を出すために帯を広げない")
    func longPrinterName() {
        let layout = PrintPressArrangement(width: 1400, parts: parts(printer: 420))
        #expect(layout.form == .beside)
        #expect(layout.printer.width == 280)
    }

    @Test("8言語の長さを想定した幅で、どの部品も帯の内に収まり、印刷ボタンはいつも右端にある")
    func languagesStayInside() {
        // The menus and the result's first line as measured in the longest and shortest of the eight languages.
        let cases: [(menus: CGFloat, lead: CGFloat, pdf: CGFloat)] = [
            (230, 150, 120),  // ja, zh-Hans, zh-Hant, ko
            (270, 210, 128),  // en
            (330, 250, 150),  // de, fr, es
        ]
        for item in cases {
            for width in [500, 620, 760, 880, 1000, 1280] as [CGFloat] {
                let layout = PrintPressArrangement(
                    width: width, parts: parts(menus: item.menus, summaryLead: item.lead, pdf: item.pdf))
                #expect(layout.button.maxX == width)
                #expect(layout.printer.maxX <= layout.button.minX - PrintPressArrangement.clusterGap)
                for frame in [layout.menus, layout.cards, layout.summary, layout.printer, layout.pdf, layout.button] {
                    #expect(frame.minX >= 0 && frame.maxX <= width, "\(item) \(width)")
                }
                // The result's first line keeps its own width; only the narrowest bar cuts the printer for it.
                #expect(layout.summary.width >= item.lead, "\(item) \(width)")
                #expect(layout.printer.width >= (width >= 560 ? 205 : PrintPressArrangement.printerMinimum))
            }
        }
    }

    @Test("帯は渡された幅で測るが、カードの1段より狭くは測らず、幅を渡されなければ左右に並ぶ幅で測る")
    func fittingWidth() {
        #expect(PrintPressArrangement.fittingWidth(for: 732, parts: parts()) == 732)
        // At zero width the cards' one row: the window's smallest height keeps one row of cards.
        #expect(PrintPressArrangement.fittingWidth(for: 0, parts: parts()) == 500)
        #expect(PrintPressArrangement.fittingWidth(for: 0, parts: parts(menus: 560)) == 560)
        // 500 for the cards, 17 around the rule, and the result's 300, wider than the buttons' 275.
        #expect(PrintPressArrangement.fittingWidth(for: nil, parts: parts()) == 817)
        #expect(PrintPressArrangement.fittingWidth(for: .infinity, parts: parts()) == 817)
    }
}
