import AppKit

/// The printers the tray offers, and which of them Print sends to.
struct PrinterList: Equatable {
    var names: [String]
    var defaultName: String?

    static let empty = PrinterList(names: [], defaultName: nil)

    static func current() -> PrinterList {
        PrinterList(names: NSPrinter.printerNames, defaultName: NSPrintInfo.defaultPrinter?.name)
    }

    /// The remembered printer while it is still set up, otherwise the system's default, otherwise the first one.
    func resolve(_ remembered: String?) -> String? {
        if let remembered, names.contains(remembered) { return remembered }
        if let defaultName, names.contains(defaultName) { return defaultName }
        return names.first
    }
}

/// How one print goes out: straight to a printer, or through the system dialog, which starts on that printer.
struct PrintRequest: Equatable {
    var printerName: String?
    var showsPanel: Bool
}

extension PrinterList {
    /// Print sends straight to the printer the tray showed. If that printer is gone by the time Print is pressed, or
    /// there is none, the system dialog opens instead, so that nothing is sent to a printer the reader did not see.
    func request(quick: Bool, shown: String?, remembered: String?) -> PrintRequest {
        let current = resolve(remembered)
        return PrintRequest(printerName: current, showsPanel: !(quick && current != nil && current == shown))
    }
}
