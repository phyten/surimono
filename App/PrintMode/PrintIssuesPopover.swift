import SurimonoCore
import SwiftUI

struct PrintIssuesPopover: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Before Printing").font(.headline)
            ScrollView {
                // Content that will not print comes first: an unreadable image is not a table that only runs wide.
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(PrintIssue.grouped(model.printIssues), id: \.group) { section in
                        group(section.group, issues: section.issues)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
        }
        .padding(16)
        .frame(width: 440)
        .foregroundStyle(PrintPalette.ink)
        .tint(PrintPalette.ai)
    }

    private func group(_ group: PrintIssue.Group, issues: [PrintIssue]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: PrintIssueText.groupTitle(group, language: model.language))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(group == .content ? PrintPalette.warn : PrintPalette.ink2)
                Text(verbatim: "\(issues.count)").font(.system(size: 11)).foregroundStyle(PrintPalette.ink3)
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(issues) { issue in
                    row(issue)
                    if issue.id != issues.last?.id { Divider() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ issue: PrintIssue) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: PrintIssueText.title(issue, language: model.language))
                .font(.system(size: 13, weight: .semibold))
                .textSelection(.enabled)
            if let page = issue.pageNumber {
                Text("Page \(page)").font(.system(size: 11)).foregroundStyle(PrintPalette.ink2)
            }
            Text(verbatim: PrintIssueText.advice(issue, language: model.language))
                .font(.system(size: 12)).foregroundStyle(PrintPalette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            PrintFlowLayout(spacing: 8, lineSpacing: 6) { actions(issue) }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func actions(_ issue: PrintIssue) -> some View {
        if issue.pageNumber != nil {
            Button("Check Location") { model.showPrintIssue(issue) }
        }
        switch issue.kind {
        case .image:
            if issue.imageFailure == .missing, model.fileURL != nil {
                Button("Show in Finder") { model.revealPrintIssueFolder() }
            } else if issue.imageFailure == .folderAccess, model.fileURL != nil {
                Button("Allow Access to Folder…") { model.allowFolderAccess() }
            }
        case .overflow:
            Button("Use Landscape") { model.useLandscapeForPrintIssue() }
                .disabled(PaperOrientationControl(model: model).isFixed)
                .help(
                    PaperOrientationControl(model: model).isFixed
                        ? Text("This layout uses a fixed paper orientation.") : Text("Paper Orientation"))
            if model.usesPrintTheme {
                Button("Make Text Smaller") { model.decreaseTextSize() }
                    .disabled(TextScale.smaller(than: model.textScale) == model.textScale)
            }
        case .math, .latex, .mermaid: EmptyView()
        }
    }
}

enum PrintIssueText {
    /// The two groups of the list: what will not come out on paper, and what is worth a look before it does.
    static func groupTitle(_ group: PrintIssue.Group, language: String) -> String {
        PrintModeText.string(
            group == .content ? "Content That Will Not Print" : "Placement to Check", language: language)
    }

    static func title(_ issue: PrintIssue, language: String) -> String {
        let key: String
        switch issue.kind {
        case .image: key = "Could Not Load Image: %@"
        case .math: key = "Could Not Render Formula: %@"
        case .mermaid: key = "Could Not Render Diagram: %@"
        case .latex: key = "Unsupported LaTeX: %@"
        case .overflow:
            switch issue.element {
            case .table: key = "Table Exceeds the Text Width"
            case .image: key = "Image Exceeds the Text Width"
            case .code: key = "Code Exceeds the Text Width"
            case .math: key = "Formula Exceeds the Text Width"
            case .figure, nil: key = "Figure Exceeds the Text Width"
            }
            return PrintModeText.string(key, language: language)
        }
        return PrintModeText.format(key, language: language, issue.detail)
    }

    static func advice(_ issue: PrintIssue, language: String) -> String {
        let key: String
        switch issue.kind {
        case .image:
            switch issue.imageFailure {
            case .missing: key = "Image file not found: check its name and location in the source document."
            case .folderAccess:
                key = "Folder access is not allowed: allow access to the folder containing the document and its images."
            case .other, nil: key = "Check that the image is readable and in a supported format."
            }
        case .overflow: key = "Try landscape paper or smaller text, or adjust this element in the source document."
        case .math: key = "Check the formula's syntax and use supported commands in the source document."
        case .mermaid: key = "Check the Mermaid syntax and simplify the diagram in the source document."
        case .latex: key = "Replace this part with an image or supported LaTeX in the source document."
        }
        return PrintModeText.string(key, language: language)
    }
}
