import SurimonoCore
import SwiftUI

extension DocumentViewModel {
    /// What the chosen printer cannot do with a layout; nil while nothing is known about the printer.
    func printerIssue(for layout: PrintLayout) -> PrinterIssue? {
        issue(sending: layout, to: selectedPrinterName)
    }

    /// What `printer` cannot do with `layout`, as far as it has said.
    func issue(sending layout: PrintLayout, to printer: String?) -> PrinterIssue? {
        printer.flatMap { printerCapabilities[$0] }?.issue(for: layout)
    }

    /// Automatic calibration still needs a genuine duplex job, so every known issue keeps its dialog fallback.
    /// Document printing uses PrintRoute instead, where missing duplex alone can be handled manually.
    func printRequest(quick: Bool, shown: String?, layout: PrintLayout) -> PrintRequest {
        var request = printers.request(quick: quick, shown: shown, remembered: preferences.printerName)
        if issue(sending: layout, to: request.printerName) != nil { request.showsPanel = true }
        return request
    }

    /// The issue of the layout on the tray.
    var printerIssue: PrinterIssue? { printerIssue(for: printerLayout) }

    /// Asks what the chosen printer can do, once; the tray never waits for the answer.
    func loadPrinterCapabilities() {
        guard let name = selectedPrinterName, printerCapabilities[name] == nil,
            !printerCapabilityQueries.contains(name)
        else { return }
        printerCapabilityQueries.insert(name)
        let source = printerCapabilitiesSource
        Task { [weak self] in
            let found = await source(name)
            guard let self else { return }
            printerCapabilityQueries.remove(name)
            if let found { printerCapabilities[name] = found }
        }
    }
}

extension PrintModeText {
    /// The few words on a layout card.
    static func issueBadge(_ issue: PrinterIssue, language: String) -> String {
        switch issue {
        case .paperNotAccepted(let paper): format("No %@", language: language, paper.shortName)
        case .duplexNotAvailable: string("Manual Duplex", language: language)
        }
    }

    static func issueSentence(_ issue: PrinterIssue, language: String) -> String {
        switch issue {
        case .paperNotAccepted(let paper):
            format("This printer cannot print on %@", language: language, paper.shortName)
        case .duplexNotAvailable: string("This printer cannot print on both sides", language: language)
        }
    }

    /// Under the summary: what is wrong, and what Print does about it.
    static func issueLine(_ issue: PrinterIssue, language: String) -> String {
        // The full sentence does not fit the two lines under the summary at the tray's narrowest; it is the help.
        if issue == .duplexNotAvailable {
            return string("No automatic 2-sided printing. Print sends the fronts, then the backs.", language: language)
        }
        return format(
            "%@. Print opens the system print dialog.", language: language, issueSentence(issue, language: language))
    }

    /// What VoiceOver reads for a layout card, all in one: what it makes, the paper it takes, and what the chosen
    /// printer cannot do with it. Whether it is chosen is its trait.
    static func cardLabel(_ layout: PrintLayout, issue: PrinterIssue?, language: String) -> String {
        let parts = [
            cardTitleLine(layout, language: language), cardPaper(layout, language: language),
            issue.map { issueBadge($0, language: language) },
        ].compactMap { $0 }
        return parts.dropFirst().reduce(parts[0]) { format("%1$@, %2$@", language: language, $0, $1) }
    }

    /// A card's hint, with what the printer cannot do under it.
    static func cardHelp(_ help: String, issue: PrinterIssue?, language: String) -> String {
        issue.map { "\(help)\n\(issueSentence($0, language: language))" } ?? help
    }

    static func issuePrintHelp(_ issue: PrinterIssue, language: String) -> String {
        if issue == .duplexNotAvailable {
            return string(
                "This printer cannot print both sides automatically. Print sends the fronts first, then the backs after you reload the paper.",
                language: language)
        }
        return format(
            "%@, so Print opens the system print dialog", language: language,
            issueSentence(issue, language: language))
    }
}

/// The line under the summary while the layout on the tray is one the chosen printer cannot do.
struct PrinterIssueLine: View {
    let model: DocumentViewModel

    var body: some View {
        if let issue = model.printerIssue {
            let line = PrintModeText.issueLine(issue, language: model.language)
            Text(verbatim: line)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PrintPalette.ai)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(
                    Text(
                        verbatim: issue == .duplexNotAvailable
                            ? PrintModeText.issuePrintHelp(issue, language: model.language) : line))
        }
    }
}
