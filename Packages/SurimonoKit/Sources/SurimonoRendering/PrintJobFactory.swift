import AppKit
import ApplicationServices
import PDFKit
import SurimonoCore

@MainActor
public struct PrintJobFactory {
    public init() {}

    public static let copiesRange = 1...99

    /// Print settings for the sheets of `layout`, sent to `printer` when given.
    public func printInfo(
        for layout: PrintLayout, base: NSPrintInfo = .shared, printer: NSPrinter? = nil,
        pageOrder: PrintPageOrder = .lastSheetFirst, copies: Int = 1
    ) -> NSPrintInfo {
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
            case .b6: "B6"
            case .letter: "Letter"
            case .tabloid: "Tabloid"
            case .halfLetter: "Statement"
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
        let settings = OpaquePointer(info.pmPrintSettings())
        PMSetDuplex(settings, Self.duplexMode(for: layout))
        // kPMOutputOrderKey is a CFSTR macro Swift does not import. Always naming the order keeps the printer's
        // own default from deciding it; the print system keeps the fronts and backs of duplex sheets together.
        let order = pageOrder == .lastSheetFirst ? "Reverse" : "Normal"
        PMPrintSettingsSetValue(settings, "OutputOrder" as CFString, order as CFString, false)
        // The shared settings keep the copies of the last job, so the number is always named. Copies come out as
        // whole sets: a booklet printed three times is three booklets, not three of each sheet.
        let copies = min(max(copies, Self.copiesRange.lowerBound), Self.copiesRange.upperBound)
        PMSetCopies(settings, UInt32(copies), false)
        PMSetCollate(settings, true)
        info.updateFromPMPrintSettings()
        return info
    }

    public nonisolated static func duplexMode(for layout: PrintLayout) -> PMDuplexMode {
        switch layout.sentDuplex {
        case .none: PMDuplexMode(kPMDuplexNone)
        case .longEdge: PMDuplexMode(kPMDuplexNoTumble)
        case .shortEdge: PMDuplexMode(kPMDuplexTumble)
        }
    }

    public func printOperation(
        for document: PDFDocument, layout: PrintLayout, showsPrintPanel: Bool, printer: NSPrinter? = nil,
        pageOrder: PrintPageOrder = .lastSheetFirst, copies: Int = 1
    ) -> NSPrintOperation? {
        let orientations = (0..<document.pageCount).compactMap { index -> Bool? in
            guard let page = document.page(at: index) else { return nil }
            let size = page.bounds(for: .mediaBox).size
            return size.width > size.height
        }
        let mixed = layout.kind == .normal && layout.duplex == .none && Set(orientations).count > 1
        // Feed one paper size; PDFKit rotates each landscape sheet onto it before scaling down.
        let printLayout =
            layout.kind == .normal && layout.duplex == .none
            ? layout.oriented(!mixed && orientations.first == true) : layout
        guard document.pageCount > 0, !document.isLocked,
            let operation = document.printOperation(
                for: printInfo(for: printLayout, printer: printer, pageOrder: pageOrder, copies: copies),
                scalingMode: .pageScaleDownToFit, autoRotate: mixed)
        else { return nil }
        operation.showsPrintPanel = showsPrintPanel
        operation.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsCopies, .showsPageRange])
        return operation
    }
}
