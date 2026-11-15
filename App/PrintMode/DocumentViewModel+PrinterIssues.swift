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

    /// What VoiceOver reads for a layout card: its name, then the badge's words.
    static func cardLabel(_ layout: PrintLayout, issue: PrinterIssue?, language: String) -> String {
        let name = layout.displayName(language: language)
        return issue.map { "\(name), \(issueBadge($0, language: language))" } ?? name
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
            "%@, so Print opens the system print dialog (⌘P)", language: language,
            issueSentence(issue, language: language))
    }
}

/// Marks a layout card the chosen printer cannot do. The card stays a choice: the reader may know better, export a
/// PDF, or print through the system dialog to another printer. It is laid over the card rather than built into it, so
/// that the card can change without it.
private struct PrinterIssueBadge: ViewModifier {
    let issue: PrinterIssue?
    /// The card's name with the badge's words after it, for VoiceOver.
    let label: String
    let language: String

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if let issue {
                    Text(verbatim: PrintModeText.issueBadge(issue, language: language))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(PrintPalette.ink)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(PrintPalette.raised, in: Capsule())
                        .overlay { Capsule().strokeBorder(PrintPalette.line3, lineWidth: 1) }
                        .offset(x: 1, y: -1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(Text(verbatim: label))
    }
}

extension View {
    /// Lays the badge of what the chosen printer cannot do over a layout card.
    func printerIssueBadge(for layout: PrintLayout, model: DocumentViewModel) -> some View {
        let issue = model.printerIssue(for: layout)
        return modifier(
            PrinterIssueBadge(
                issue: issue, label: PrintModeText.cardLabel(layout, issue: issue, language: model.language),
                language: model.language))
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
