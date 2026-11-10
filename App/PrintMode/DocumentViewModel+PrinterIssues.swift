import SurimonoCore
import SwiftUI

extension DocumentViewModel {
    /// What the chosen printer cannot do with a layout; nil while nothing is known about the printer.
    func printerIssue(for layout: PrintLayout) -> PrinterIssue? {
        selectedPrinterName.flatMap { printerCapabilities[$0] }?.issue(for: layout)
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
        case .duplexNotAvailable: string("No 2-Sided", language: language)
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
        format(
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
        format(
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
                .help(Text(verbatim: line))
        }
    }
}
