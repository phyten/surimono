import Testing

@testable import Surimono

@MainActor
struct PrinterListTests {
    private let printers = PrinterList(
        names: ["Home Inkjet", "Office Laser", "Label Printer"], defaultName: "Home Inkjet")

    @Test("覚えているプリンターがあれば、それに送る")
    func remembered() {
        #expect(printers.resolve("Office Laser") == "Office Laser")
    }

    @Test("覚えていないか、覚えたプリンターが外されていれば、システムの既定に送る")
    func fallsBackToTheDefault() {
        #expect(printers.resolve(nil) == "Home Inkjet")
        #expect(printers.resolve("Old Printer") == "Home Inkjet")
    }

    @Test("既定のプリンターも見つからなければ、最初のプリンターに送る")
    func fallsBackToTheFirst() {
        let list = PrinterList(names: ["Office Laser", "Label Printer"], defaultName: "Home Inkjet")
        #expect(list.resolve(nil) == "Office Laser")
    }

    @Test("プリンターが 1 台もなければ、送り先はない")
    func noPrinters() {
        #expect(PrinterList.empty.resolve("Office Laser") == nil)
    }

    @Test("画面に出ていたプリンターがそのまま使えるなら、ダイアログなしで送る")
    func sendsToTheShownPrinter() {
        #expect(
            printers.request(quick: true, shown: "Office Laser", remembered: "Office Laser")
                == PrintRequest(printerName: "Office Laser", showsPanel: false))
    }

    @Test("画面に出ていたプリンターが印刷の直前に外されていたら、別のプリンターに送らずシステムの印刷画面で確かめる")
    func asksWhenTheShownPrinterIsGone() {
        let after = PrinterList(names: ["Home Inkjet"], defaultName: "Home Inkjet")
        #expect(
            after.request(quick: true, shown: "Office Laser", remembered: "Office Laser")
                == PrintRequest(printerName: "Home Inkjet", showsPanel: true))
    }

    @Test("画面にプリンターがなかったのに印刷の直前に見つかったときも、システムの印刷画面で確かめる")
    func asksWhenAPrinterAppearsAtTheLastMoment() {
        #expect(
            printers.request(quick: true, shown: nil, remembered: nil)
                == PrintRequest(printerName: "Home Inkjet", showsPanel: true))
    }

    @Test("プリンターが 1 台もなければ、システムの印刷画面を開く")
    func opensTheDialogWithoutPrinters() {
        #expect(
            PrinterList.empty.request(quick: true, shown: nil, remembered: nil)
                == PrintRequest(printerName: nil, showsPanel: true))
    }

    @Test("システムの印刷画面を頼んだときは、選んだプリンターから始める")
    func dialogStartsOnTheChosenPrinter() {
        #expect(
            printers.request(quick: false, shown: "Office Laser", remembered: "Office Laser")
                == PrintRequest(printerName: "Office Laser", showsPanel: true))
    }
}
