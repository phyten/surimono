import ApplicationServices
import SurimonoCore

/// Reads what a printer can do from the system's record of it: the papers of its paper list and its PPD, which the
/// system keeps for driverless (IPP / AirPrint) queues too. No job is made and nothing goes to the queue, but the
/// system may ask a network printer for its description, so this is called off the main thread.
nonisolated enum SystemPrinterCapabilities {
    static func read(printerNamed name: String) -> PrinterCapabilities? {
        var list: Unmanaged<CFArray>?
        guard PMServerCreatePrinterList(nil, &list) == noErr, let printers = list?.takeRetainedValue() else {
            return nil
        }
        // `NSPrinter` names a printer by its display name, where `PMPrinterCreateFromPrinterID` wants the queue's ID.
        for index in 0..<CFArrayGetCount(printers) {
            guard let value = CFArrayGetValueAtIndex(printers, index) else { continue }
            let printer = PMPrinter(value)
            guard Self.string(PMPrinterGetName(printer)) == name else { continue }
            return PrinterCapabilities(paperSizes: paperSizes(of: printer), ppd: ppd(of: printer))
        }
        return nil
    }

    // The SDK of Xcode 26.6 gives the name as an unmanaged reference and later SDKs as a string reference; one of
    // the two is chosen by the type, so the same source builds with both. A Get function: nothing to release.
    private static func string(_ value: Unmanaged<CFString>?) -> String? { value?.takeUnretainedValue() as String? }
    private static func string(_ value: CFString?) -> String? { value as String? }

    private static func paperSizes(of printer: PMPrinter) -> [CGSize] {
        var list: Unmanaged<CFArray>?
        // The list belongs to the printer (a Get function), so it is not released here.
        guard PMPrinterGetPaperList(printer, &list) == noErr, let papers = list?.takeUnretainedValue() else {
            return []
        }
        return (0..<CFArrayGetCount(papers)).compactMap { index in
            guard let value = CFArrayGetValueAtIndex(papers, index) else { return nil }
            let paper = PMPaper(value)
            var width = 0.0
            var height = 0.0
            guard PMPaperGetWidth(paper, &width) == noErr, PMPaperGetHeight(paper, &height) == noErr else {
                return nil
            }
            return CGSize(width: width, height: height)
        }
    }

    private static func ppd(of printer: PMPrinter) -> String? {
        var location: Unmanaged<CFURL>?
        guard PMPrinterCopyDescriptionURL(printer, kPMPPDDescriptionType as CFString, &location) == noErr,
            let url = location?.takeRetainedValue() as URL?, let data = try? Data(contentsOf: url)
        else { return nil }
        // The keywords are ASCII; only the translations of old descriptions are in another encoding.
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}

/// What the printers said, kept for the session: asking again would only wake a sleeping printer for the same answer.
/// A printer that did not answer is asked again the next time.
actor PrinterCapabilityCache {
    static let shared = PrinterCapabilityCache()

    private var known: [String: PrinterCapabilities] = [:]

    func capabilities(for name: String) async -> PrinterCapabilities? {
        if let hit = known[name] { return hit }
        // Detached, so that a printer that is slow to answer does not hold up the answers already known.
        let read = await Task.detached(priority: .utility) {
            SystemPrinterCapabilities.read(printerNamed: name)
        }.value
        if let read { known[name] = read }
        return read
    }
}
