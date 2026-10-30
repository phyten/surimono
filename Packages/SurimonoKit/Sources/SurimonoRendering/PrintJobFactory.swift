import AppKit
import ApplicationServices
import PDFKit
import SurimonoCore

@MainActor
public struct PrintJobFactory {
    public init() {}

    /// Print settings for the sheets of `layout`, sent to `printer` when given.
    public func printInfo(for layout: PrintLayout, base: NSPrintInfo = .shared, printer: NSPrinter? = nil)
        -> NSPrintInfo
    {
        let info = (base.copy() as? NSPrintInfo) ?? NSPrintInfo()
        // Choose the printer first: changing it afterwards can reset the paper to that printer's default.
        if let printer { info.printer = printer }
        info.orientation = .portrait
        // Paper names are driver-dependent; explicit dimensions remain authoritative.
        let name =
            switch layout.sheet {
            case .a3: "A3"
            case .a4: "A4"
            case .a5: "A5"
            case .b4: "B4"
            case .b5: "B5"
            case .letter: "Letter"
            case .tabloid: "Tabloid"
            }
        info.paperName = NSPrinter.PaperName(name)
        info.paperSize = layout.sheet.size
        info.orientation = layout.sheetSize.width > layout.sheetSize.height ? .landscape : .portrait
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.scalingFactor = 1
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        let duplex =
            switch layout.duplex {
            case .none: kPMDuplexNone
            case .longEdge: kPMDuplexNoTumble
            case .shortEdge: kPMDuplexTumble
            }
        PMSetDuplex(OpaquePointer(info.pmPrintSettings()), PMDuplexMode(duplex))
        info.updateFromPMPrintSettings()
        return info
    }

    public func printOperation(
        for document: PDFDocument, layout: PrintLayout, showsPrintPanel: Bool, printer: NSPrinter? = nil
    ) -> NSPrintOperation? {
        guard document.pageCount > 0, !document.isLocked,
            let operation = document.printOperation(
                for: printInfo(for: layout, printer: printer), scalingMode: .pageScaleDownToFit, autoRotate: false)
        else { return nil }
        operation.showsPrintPanel = showsPrintPanel
        operation.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsCopies, .showsPageRange])
        return operation
    }
}
